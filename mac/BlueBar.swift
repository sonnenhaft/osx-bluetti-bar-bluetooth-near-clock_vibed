// BluettiBar — a read-only BLUETTI AC50P menu-bar monitor.
// Build with Swift 5 language mode; minimum deployment target: macOS 12.
import AppKit
import Foundation
import CoreFoundation
import Darwin

private struct CLIResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var error: String?
}

// Read both pipes concurrently so a child cannot deadlock on a full stderr pipe.
private final class PipeCapture {
    private let lock = NSLock()
    private var bytes = Data()

    func drain(_ handle: FileHandle) {
        var collected = Data()
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            // Keep bounded diagnostics, but always drain the remainder of the pipe.
            if collected.count < 262_144 {
                collected.append(chunk.prefix(262_144 - collected.count))
            }
        }
        lock.lock()
        bytes = collected
        lock.unlock()
        try? handle.close()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

private final class CLIJob {
    private let lock = NSLock()
    private var process: Process?
    private var stopReason: String?
    private var finished = false

    func run(executable: URL, arguments: [String], completion: @escaping (CLIResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.executableURL = executable
            task.arguments = ["--bluetti-helper"] + arguments
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = outPipe
            task.standardError = errPipe
            let outCapture = PipeCapture()
            let errCapture = PipeCapture()

            self.lock.lock()
            if let reason = self.stopReason {
                self.finished = true
                self.lock.unlock()
                completion(CLIResult(exitCode: -1, stdout: Data(), stderr: Data(), error: reason))
                return
            }
            self.process = task
            do {
                try task.run()
            } catch {
                self.finished = true
                self.process = nil
                self.lock.unlock()
                completion(CLIResult(exitCode: -1, stdout: Data(), stderr: Data(),
                                     error: "Cannot launch Bluetooth reader: \(error.localizedDescription)"))
                return
            }
            self.lock.unlock()

            let drains = DispatchGroup()
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                outCapture.drain(outPipe.fileHandleForReading)
                drains.leave()
            }
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                errCapture.drain(errPipe.fileHandleForReading)
                drains.leave()
            }

            let deadline = DispatchWorkItem { [weak self] in
                self?.cancel(reason: "Bluetooth read timed out. Check the station and close the BLUETTI phone app.")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 36, execute: deadline)
            task.waitUntilExit()
            deadline.cancel()
            drains.wait()

            self.lock.lock()
            self.finished = true
            let reason = self.stopReason
            self.process = nil
            self.lock.unlock()
            completion(CLIResult(exitCode: task.terminationStatus,
                                 stdout: outCapture.data(), stderr: errCapture.data(), error: reason))
        }
    }

    func cancel(reason: String = "Bluetooth read cancelled.") {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if stopReason == nil { stopReason = reason }
        let running = process
        lock.unlock()
        guard let task = running, task.isRunning else { return }
        task.terminate()
        // A process stuck in the Bluetooth stack still must not survive the app.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceStop()
        }
    }

    func forceStop() {
        lock.lock()
        defer { lock.unlock() }
        if !finished, let task = process, task.isRunning {
            _ = Darwin.kill(task.processIdentifier, SIGKILL)
        }
    }
}

private enum RuntimeState: String {
    case estimating, discharging, charging, steady, unavailable, empty
}

private enum RuntimeSource: String {
    case station, power
    case socHistory = "soc_history"
}

private struct RuntimeEstimate {
    var state: RuntimeState
    var source: RuntimeSource?
    var backup: Bool
    var remainingSeconds: Int?
    var windowSeconds: Int?
    var dropPercent: Int?

    static let unavailable = RuntimeEstimate(state: .unavailable, source: nil, backup: false,
                                              remainingSeconds: nil, windowSeconds: nil, dropPercent: nil)

    var json: [String: Any] {
        var value: [String: Any] = ["state": state.rawValue]
        if let source = source { value["source"] = source.rawValue }
        if backup { value["backup"] = true }
        if let seconds = remainingSeconds { value["remaining_seconds"] = seconds }
        if let seconds = windowSeconds { value["window_seconds"] = seconds }
        if let drop = dropPercent { value["drop_percent"] = drop }
        return value
    }

    static func parse(_ value: Any?, percent: Int) -> RuntimeEstimate? {
        guard let object = value as? [String: Any],
              let name = object["state"] as? String,
              let state = RuntimeState(rawValue: name) else { return nil }
        let backup: Bool
        if let raw = object["backup"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            backup = flag.boolValue
        } else { backup = false }
        func integer(_ key: String, maximum: Int) -> Int? {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0,
                  number.doubleValue <= Double(maximum) else { return nil }
            return number.intValue
        }
        // Accept the station's own hours estimate as well as calculated values;
        // keep a finite bound so malformed JSON is always safe to format.
        let remaining = integer("remaining_seconds", maximum: 7 * 24 * 60 * 60)
        if state == .discharging && remaining == nil { return nil }
        if state == .empty && (remaining != 0 || percent != 0) { return nil }
        let source = (object["source"] as? String).flatMap(RuntimeSource.init(rawValue:))
        return RuntimeEstimate(state: state, source: source, backup: backup, remainingSeconds: remaining,
                               windowSeconds: integer("window_seconds", maximum: 900),
                               dropPercent: integer("drop_percent", maximum: 100))
    }
}

private struct Reading {
    var percent: Int
    var device: String
    var deviceID: String?
    var measuredAt: Date
    var acInput: Double?
    var dcInput: Double?
    var acOutput: Double?
    var dcOutput: Double?
    var inputPowerRetainedAt: Date?
    var outputPowerRetainedAt: Date?
    var runtime: RuntimeEstimate
    var runtimeMeasuredAt: Date
    var runtimePercent: Int
    var runtimeCarriedForward: Bool
}

private struct LoadChartPoint {
    let timestamp: Date
    let watts: Double
    let startsSegment: Bool
}

private struct LoadChartHistory {
    static let window: TimeInterval = 30 * 60
    private(set) var points: [LoadChartPoint] = []
    private var pendingGap = true

    // Supply watts only when BOTH AC and DC outputs were actually measured.
    // A genuine zero is valid; nil, negative and non-finite totals break the line.
    mutating func append(timestamp: Date, watts: Double?, maximumGap: TimeInterval) {
        guard timestamp.timeIntervalSince1970.isFinite,
              let watts = watts, watts.isFinite, watts >= 0 else {
            markGap()
            return
        }
        if let last = points.last {
            if timestamp == last.timestamp { return } // Do not repeat cached samples.
            if timestamp < last.timestamp { clear() } // Clock/station reset.
        }
        let gap = points.last.map {
            timestamp.timeIntervalSince($0.timestamp) > maximumGap
        } ?? true
        points.append(LoadChartPoint(timestamp: timestamp, watts: watts,
                                     startsSegment: pendingGap || gap))
        pendingGap = false
        points.removeAll { $0.timestamp < timestamp.addingTimeInterval(-Self.window) }
        // 361 points cover 30 minutes at the fastest supported 5-second poll.
        if points.count > 400 { points.removeFirst(points.count - 400) }
    }

    mutating func markGap() { pendingGap = true }

    mutating func clear() {
        points.removeAll()
        pendingGap = true
    }

    mutating func visiblePoints(at now: Date) -> [LoadChartPoint] {
        let cutoff = now.addingTimeInterval(-Self.window)
        points.removeAll { $0.timestamp < cutoff }
        return points.filter { $0.timestamp <= now }
    }
}

private final class LoadGraphView: NSView {
    private var points: [LoadChartPoint] = []
    private var now = Date()
    private(set) var hasLine = false
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 106))
        autoresizingMask = [.width]
        toolTip = "Выходная мощность AC + DC. Ватты и время; до 30 минут истории."
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("График нагрузки BLUETTI: мощность в ваттах и время")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(points: [LoadChartPoint], now: Date) {
        self.now = now
        let cutoff = now.addingTimeInterval(-LoadChartHistory.window)
        self.points = points.filter {
            $0.timestamp >= cutoff && $0.timestamp <= now
                && $0.watts.isFinite && $0.watts >= 0
        }
        hasLine = zip(self.points, self.points.dropFirst()).contains { pair in
            !pair.1.startsSegment && pair.1.timestamp > pair.0.timestamp
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func scaleMaximum() -> Double {
        let peak = max(1.0, points.map { $0.watts }.max() ?? 0)
        let magnitude = pow(10.0, floor(log10(peak)))
        for step in [1.0, 2.0, 5.0, 10.0] {
            let candidate = step * magnitude
            if candidate.isFinite && candidate >= peak { return candidate }
        }
        return peak
    }

    private func wattsLabel(_ watts: Double) -> String {
        if watts >= 1_000_000 { return String(format: "%.1e W", watts) }
        return String(format: watts.rounded() == watts ? "%.0f W" : "%.1f W", watts)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: bounds.minX + 44, y: bounds.minY + 24,
                          width: bounds.width - 56, height: bounds.height - 36)
        guard plot.width > 0, plot.height > 0 else { return }
        let available = points.first.map { now.timeIntervalSince($0.timestamp) } ?? 60
        let span = min(LoadChartHistory.window, max(60, available))
        let start = now.addingTimeInterval(-span)
        let maximum = scaleMaximum()
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + CGFloat(fraction) * plot.height
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        grid.stroke()

        let axis = NSBezierPath()
        axis.lineWidth = 0.7
        axis.move(to: NSPoint(x: plot.minX, y: plot.maxY))
        axis.line(to: NSPoint(x: plot.minX, y: plot.minY))
        axis.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        for fraction in [0.0, 0.5, 1.0] {
            let x = plot.minX + CGFloat(fraction) * plot.width
            axis.move(to: NSPoint(x: x, y: plot.minY))
            axis.line(to: NSPoint(x: x, y: plot.minY - 3))
        }
        NSColor.tertiaryLabelColor.setStroke()
        axis.stroke()

        for fraction in [0.0, 0.5, 1.0] {
            let label = wattsLabel(maximum * fraction) as NSString
            let size = label.size(withAttributes: labelAttributes)
            label.draw(at: NSPoint(x: max(bounds.minX + 2, plot.minX - 6 - size.width),
                                   y: plot.minY + CGFloat(fraction) * plot.height - size.height / 2),
                       withAttributes: labelAttributes)
        }
        timeFormatter.timeZone = .current
        for fraction in [0.0, 0.5, 1.0] {
            let time = start.addingTimeInterval(span * fraction)
            let label = timeFormatter.string(from: time) as NSString
            let size = label.size(withAttributes: labelAttributes)
            let center = plot.minX + CGFloat(fraction) * plot.width
            let x = min(bounds.maxX - size.width - 2,
                        max(bounds.minX + 2, center - size.width / 2))
            label.draw(at: NSPoint(x: x, y: plot.minY - 17), withAttributes: labelAttributes)
        }

        // Axes remain visible before two genuine contiguous samples exist.
        // No dots, interpolated missing samples, or extension to the current time.
        guard hasLine else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let x = plot.minX + CGFloat(point.timestamp.timeIntervalSince(start) / span) * plot.width
            let y = plot.minY + CGFloat(point.watts / maximum) * plot.height
            let position = NSPoint(x: x, y: y)
            if index == 0 || point.startsSegment { path.move(to: position) }
            else { path.line(to: position) }
        }
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}

/// Persist independently from BlueBar's normal preferences. Removing the main
/// app preferences does not remove this suite or the user's station aliases.
struct BlueBarKnownStation: Codable, Equatable {
    let key: String
    var deviceID: String?
    var bluetoothName: String
    var model: String
    var alias: String?
    var seenNames: [String]
    var lastSeen: Date

    var displayName: String { alias ?? bluetoothName }
    /// Pass this to `bluetti --device`; aliases are display text, not selectors.
    var selector: String { deviceID ?? bluetoothName }
}

/// Use from the main thread, where the menu owns its station state.
final class BlueBarStationDirectory {
    static let suiteName = "com.local.bluebar.aliases"
    private static let storageKey = "stationDirectory.v1"

    private struct Saved: Codable {
        var version = 1
        var stations: [BlueBarKnownStation]
    }

    private let defaults: UserDefaults?
    private var records: [String: BlueBarKnownStation] = [:]

    init(defaults: UserDefaults? = UserDefaults(suiteName: BlueBarStationDirectory.suiteName)) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1 {
            for station in saved.stations {
                guard !station.bluetoothName.isEmpty else { continue }
                records[station.key] = station
            }
        }
    }

    /// Stable saved choices, including stations currently outside Bluetooth range.
    var stations: [BlueBarKnownStation] {
        let values = Array(records.values)
        return values.filter { value in
            // Keep an unresolved alias on disk, but do not offer an ambiguous
            // name-only selector after distinct UUIDs have advertised that name.
            value.deviceID != nil || !values.contains { other in
                other.deviceID != nil && value.seenNames.contains { other.seenNames.contains($0) }
            }
        }.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }
    }

    /// Returns nil for an ambiguous name when an authoritative ID is unavailable.
    func station(deviceID: String?, bluetoothName: String) -> BlueBarKnownStation? {
        if let id = Self.normalizedID(deviceID) {
            return records["id:" + id]
        }
        let name = Self.normalizedName(bluetoothName)
        let matches = records.values.filter { $0.seenNames.contains(name) }
        return matches.count == 1 ? matches[0] : nil
    }

    func displayName(deviceID: String?, bluetoothName: String) -> String {
        station(deviceID: deviceID, bluetoothName: bluetoothName)?.displayName ?? bluetoothName
    }

    /// Observe a station from a successful CLI status or scan. UUID/ID takes
    /// precedence. A name-only record is promoted once, only if that name has
    /// no existing authoritative binding to another station.
    @discardableResult
    func observe(deviceID: String?, bluetoothName: String, model: String = "AC50P",
                 allowNamePromotion: Bool = true) -> BlueBarKnownStation? {
        let name = bluetoothName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !Self.hasControls(name) else { return nil }
        let nameKey = Self.normalizedName(name)
        let id = Self.normalizedID(deviceID)
        let matches = records.values.filter { $0.seenNames.contains(nameKey) }
        let key: String
        var record: BlueBarKnownStation

        if let id = id {
            key = "id:" + id
            if let existing = records[key] {
                record = existing
            } else if allowNamePromotion, matches.count == 1,
                      let provisional = matches.first, provisional.deviceID == nil {
                records.removeValue(forKey: provisional.key)
                record = BlueBarKnownStation(key: key, deviceID: id, bluetoothName: name,
                    model: model, alias: provisional.alias, seenNames: provisional.seenNames,
                    lastSeen: Date())
            } else {
                // Another UUID with the same BLE name never inherits its alias.
                record = BlueBarKnownStation(key: key, deviceID: id, bluetoothName: name,
                    model: model, alias: nil, seenNames: [], lastSeen: Date())
            }
        } else if matches.count == 1, let existing = matches.first {
            key = existing.key
            record = existing
        } else if matches.isEmpty {
            key = "name:" + nameKey
            record = BlueBarKnownStation(key: key, deviceID: nil, bluetoothName: name,
                model: model, alias: nil, seenNames: [], lastSeen: Date())
        } else {
            // Two known UUIDs sharing a name cannot be resolved by that name.
            return nil
        }

        record.bluetoothName = name
        record.model = model
        record.lastSeen = Date()
        if !record.seenNames.contains(nameKey) { record.seenNames.append(nameKey) }
        records[key] = record
        save()
        return record
    }

    @discardableResult
    func ingestStatus(_ json: [String: Any]) -> BlueBarKnownStation? {
        guard json["ok"] as? Bool == true, let name = json["device"] as? String else { return nil }
        return observe(deviceID: json["device_id"] as? String, bluetoothName: name,
            model: json["model"] as? String ?? "AC50P")
    }

    @discardableResult
    func ingestScan(_ json: [String: Any]) -> [BlueBarKnownStation] {
        guard json["ok"] as? Bool == true, let devices = json["devices"] as? [[String: Any]] else { return [] }
        // Inspect the entire scan before promoting a name-only alias. Otherwise
        // the first of two same-name UUIDs could receive it arbitrarily.
        var idsByName: [String: Set<String>] = [:]
        for device in devices {
            if let name = device["name"] as? String, let id = Self.normalizedID(device["id"] as? String) {
                idsByName[Self.normalizedName(name), default: []].insert(id)
            }
        }
        return devices.compactMap { device in
            guard let name = device["name"] as? String else { return nil }
            return observe(deviceID: device["id"] as? String, bluetoothName: name,
                model: device["model"] as? String ?? "AC50P",
                allowNamePromotion: (idsByName[Self.normalizedName(name)]?.count ?? 0) <= 1)
        }
    }

    /// Empty text removes the alias without forgetting the station. A nil result
    /// means a name-only identity was ambiguous; no station's alias was changed.
    @discardableResult
    func setAlias(_ text: String, deviceID: String?, bluetoothName: String,
                  model: String = "AC50P") -> BlueBarKnownStation? {
        guard var record = observe(deviceID: deviceID, bluetoothName: bluetoothName, model: model) else { return nil }
        let alias = Self.sanitizedAlias(text)
        record.alias = alias.isEmpty ? nil : alias
        records[record.key] = record
        save()
        return record
    }

    static func sanitizedAlias(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(48))
    }

    private static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !hasControls(clean) else { return nil }
        // CoreBluetooth's UUID is authoritative; preserve other backend IDs too.
        return (UUID(uuidString: clean)?.uuidString ?? clean).lowercased()
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(stations: Array(records.values))) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }
}

/// Retained display data only. Nothing in this store is a fresh API success:
/// callers must keep the original timestamps and their connecting/stale state.
/// Use on the menu's main thread. Pass nil defaults for demo memory-only state.
private final class BlueBarReadingStore {
    private typealias Snapshot = [String: Any]
    private typealias Snapshots = [String: Snapshot]
    private static let storageKey = "retainedReadings.v1"
    private let defaults: UserDefaults?
    private var readings: Snapshots = [:]
    private(set) var lastAutomaticStationKey: String?
    private var lastStationKey: String?
    private var legacySnapshot: Snapshot?

    /// Construct before startup overwrites status.json with a connecting error.
    /// The legacy file is captured but imported only after target identity checks.
    init(defaults: UserDefaults? = .standard, fallbackStatusURL: URL? = nil) {
        self.defaults = defaults
        let now = Date()
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? Snapshot,
           Self.integer(saved["version"], maximum: 1) == 1,
           let stored = saved["readings"] as? Snapshots {
            for (key, value) in stored {
                if let valid = Self.validated(value, now: now), Self.key(for: valid) == key {
                    readings[key] = valid
                }
            }
            lastAutomaticStationKey = saved["last_automatic_station_key"] as? String
            lastStationKey = saved["last_station_key"] as? String
            if lastAutomaticStationKey.map({ readings[$0] == nil }) == true { lastAutomaticStationKey = nil }
            if lastStationKey.map({ readings[$0] == nil }) == true { lastStationKey = nil }
        }
        if defaults != nil, let url = fallbackStatusURL,
           let data = try? Data(contentsOf: url),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? Snapshot {
            legacySnapshot = Self.validated(object, now: now)
        }
    }

    /// Save the successful helper payload plus optional `_bluebar_display`
    /// metadata. `automatic` records which actual station Auto last resolved to.
    /// The original measured timestamps are never replaced by the save time.
    @discardableResult
    func save(_ snapshot: [String: Any], automatic: Bool = false) -> Bool {
        guard let valid = Self.validated(snapshot, now: Date()), let key = Self.key(for: valid) else { return false }
        if let existing = readings[key],
           let validExisting = Self.validated(existing, now: Date()),
           Self.measuredAt(validExisting) > Self.measuredAt(valid) {
            readings[key] = validExisting
        } else {
            readings[key] = valid
        }
        lastStationKey = key
        if automatic { lastAutomaticStationKey = key }
        persist()
        return true
    }

    /// UUID selectors match that UUID. Full BLE names must be unambiguous across
    /// both saved readings and the known-station directory. Empty means Auto's
    /// previous station, then the latest station if Auto has never resolved one.
    func reading(for selector: String, knownStations: [BlueBarKnownStation] = []) -> [String: Any]? {
        let now = Date()
        let valid = readings.reduce(into: Snapshots()) { result, entry in
            if let checked = Self.validated(entry.value, now: now) { result[entry.key] = checked }
        }
        if let key = resolve(selector: selector, in: valid, known: knownStations) { return valid[key] }

        guard let legacy = legacySnapshot.flatMap({ Self.validated($0, now: now) }),
              let legacyKey = Self.key(for: legacy) else { return nil }
        let automatic = selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // With Auto there is no explicit target identity to compare. A v1.5
        // cache is importable only if it belongs to a station already known.
        if automatic && !Self.isKnown(legacy, stations: knownStations) { return nil }
        var candidates = valid
        candidates[legacyKey] = legacy
        guard resolve(selector: selector, in: candidates, known: knownStations) == legacyKey else { return nil }
        guard save(legacy, automatic: automatic) else { return nil }
        legacySnapshot = nil
        return legacy
    }

    private func resolve(selector: String, in values: Snapshots, known: [BlueBarKnownStation]) -> String? {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if selector.isEmpty {
            for key in [lastAutomaticStationKey, lastStationKey].compactMap({ $0 }) {
                if key.hasPrefix("id:"), values[key] != nil { return key }
                if key.hasPrefix("name:"), let found = nameKey(String(key.dropFirst(5)), in: values, known: known) { return found }
            }
            for (key, value) in values.sorted(by: { Self.measuredAt($0.value) > Self.measuredAt($1.value) }) {
                if key.hasPrefix("id:") { return key }
                if let name = value["device"] as? String, let found = nameKey(name, in: values, known: known) { return found }
            }
            return nil
        }
        guard let normalizedID = Self.identifier(selector) else { return nil }
        let matchingKnown = known.filter { Self.identifier($0.deviceID) == normalizedID }
        let idKey = "id:" + normalizedID
        if values[idKey] != nil || UUID(uuidString: selector) != nil || !matchingKnown.isEmpty {
            if values[idKey] != nil { return idKey }
            // A provisional name-only record can be restored for a UUID only
            // through an unambiguous binding in the known-station directory.
            let names = Set(matchingKnown.flatMap { $0.seenNames + [$0.bluetoothName] })
            return names.compactMap { name -> String? in
                guard let key = nameKey(name, in: values, known: known), let candidate = values[key] else { return nil }
                let candidateID = Self.identifier(candidate["device_id"] as? String)
                return candidateID == nil || candidateID == normalizedID ? key : nil
            }.max { Self.measuredAt(values[$0]!) < Self.measuredAt(values[$1]!) }
        }
        return nameKey(selector, in: values, known: known)
    }

    private func nameKey(_ value: String, in values: Snapshots, known: [BlueBarKnownStation]) -> String? {
        let name = Self.name(value)
        let matches = known.filter { Self.name($0.bluetoothName) == name || $0.seenNames.contains { Self.name($0) == name } }
        var ids = Set(matches.compactMap { Self.identifier($0.deviceID) })
        for snapshot in values.values where Self.name(snapshot["device"] as? String ?? "") == name {
            if let id = Self.identifier(snapshot["device_id"] as? String) { ids.insert(id) }
        }
        guard ids.count <= 1 else { return nil }
        if let id = ids.first, values["id:" + id] != nil { return "id:" + id }
        let fallback = "name:" + name
        return values[fallback] != nil ? fallback : nil
    }

    private static func isKnown(_ snapshot: Snapshot, stations: [BlueBarKnownStation]) -> Bool {
        let id = identifier(snapshot["device_id"] as? String)
        if let id = id, stations.contains(where: { identifier($0.deviceID) == id }) { return true }
        let currentName = name(snapshot["device"] as? String ?? "")
        let matches = stations.filter {
            name($0.bluetoothName) == currentName || $0.seenNames.contains { name($0) == currentName }
        }
        guard matches.count == 1 else { return false }
        let knownID = identifier(matches[0].deviceID)
        return id == nil || knownID == nil || id == knownID
    }

    private static func key(for snapshot: Snapshot) -> String? {
        if let id = identifier(snapshot["device_id"] as? String) { return "id:" + id }
        guard let device = snapshot["device"] as? String, !name(device).isEmpty else { return nil }
        return "name:" + name(device)
    }

    private static func identifier(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return (UUID(uuidString: clean)?.uuidString ?? clean).lowercased()
    }

    private static func name(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = number(value), number >= 0, number <= Double(maximum), number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func measuredAt(_ value: Snapshot) -> Double { number(value["observed_at"]) ?? 0 }

    private static func validRuntime(_ value: Any?, percent: Int) -> Bool {
        guard let runtime = value as? Snapshot, let state = runtime["state"] as? String,
              ["estimating", "discharging", "charging", "steady", "unavailable", "empty"].contains(state) else { return false }
        if let raw = runtime["backup"], boolean(raw) == nil { return false }
        if let raw = runtime["source"] {
            guard let source = raw as? String, ["station", "power", "soc_history"].contains(source) else { return false }
        }
        for (key, maximum) in [("remaining_seconds", 604800), ("window_seconds", 900), ("drop_percent", 100)] {
            if let raw = runtime[key], integer(raw, maximum: maximum) == nil { return false }
        }
        let remaining = integer(runtime["remaining_seconds"], maximum: 604800)
        if state == "discharging" && remaining == nil { return false }
        if state == "empty" && (remaining != 0 || percent != 0) { return false }
        return true
    }

    private static func validWatts(_ value: Snapshot) -> Bool {
        for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w"] {
            if let raw = value[key] {
                guard let watts = number(raw), watts >= 0 else { return false }
            }
        }
        return true
    }

    private static func validated(_ value: Snapshot, now: Date) -> Snapshot? {
        var result = value
        for key in ["device_id", "ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w"] {
            if result[key] is NSNull { result.removeValue(forKey: key) }
        }
        guard JSONSerialization.isValidJSONObject(result), boolean(result["ok"]) == true,
              result["model"] as? String == "AC50P",
              let percent = integer(result["battery_percent"], maximum: 100),
              let device = result["device"] as? String, identifier(device) != nil,
              let observed = number(result["observed_at"]), observed >= 0,
              observed <= now.timeIntervalSince1970, validWatts(result) else { return nil }
        if let raw = result["device_id"] {
            guard let id = raw as? String, identifier(id) != nil else { return nil }
        }
        // Keep a valid percentage/power snapshot even if its optional ETA or
        // private display metadata was damaged. The UI revalidates on restore.
        if let raw = result["runtime"], !validRuntime(raw, percent: percent) { result.removeValue(forKey: "runtime") }
        if let raw = result["_bluebar_display"] {
            guard var display = raw as? Snapshot else {
                result.removeValue(forKey: "_bluebar_display")
                return result
            }
            for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w",
                        "input_retained_at", "output_retained_at", "runtime_frozen_at", "runtime_battery_percent"] {
                if display[key] is NSNull { display.removeValue(forKey: key) }
            }
            guard integer(display["version"], maximum: 1) == 1,
                  validWatts(display),
                  (display["runtime_battery_percent"] == nil || integer(display["runtime_battery_percent"], maximum: 100) != nil),
                  validRuntime(display["runtime"], percent: integer(display["runtime_battery_percent"], maximum: 100) ?? percent),
                  let runtimeAt = number(display["runtime_observed_at"]), runtimeAt >= 0,
                  runtimeAt <= observed + 30, runtimeAt <= now.timeIntervalSince1970 else {
                result.removeValue(forKey: "_bluebar_display")
                return result
            }
            for key in ["input_retained_at", "output_retained_at", "runtime_frozen_at"] {
                if let rawDate = display[key] {
                    guard let date = number(rawDate), date >= 0, date <= now.timeIntervalSince1970,
                          (key == "runtime_frozen_at" ? date >= runtimeAt : date <= observed + 30) else {
                        result.removeValue(forKey: "_bluebar_display")
                        return result
                    }
                }
            }
            if let rawFlag = display["runtime_carried_forward"], boolean(rawFlag) == nil {
                result.removeValue(forKey: "_bluebar_display")
            } else {
                result["_bluebar_display"] = display
            }
        }
        return result
    }

    private func persist() {
        var saved: Snapshot = ["version": 1, "readings": readings]
        if let key = lastAutomaticStationKey { saved["last_automatic_station_key"] = key }
        if let key = lastStationKey { saved["last_station_key"] = key }
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }
}

/// Compact, icon-free alias editor. All editable/button text is explicitly 12 pt.
/// Empty string means "clear the alias"; nil means Cancel, Escape, or window close.
/// Call on the main thread after ending menu tracking.
private final class BlueBarAliasEditor: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let field: NSTextField
    private var result: String?
    private var finished = false

    static func edit(alias: String, placeholder: String) -> String? {
        guard NSApp.modalWindow == nil else { return nil }
        let editor = BlueBarAliasEditor(alias: alias, placeholder: placeholder)
        // Keep the target/delegate alive throughout AppKit's nested modal loop.
        return withExtendedLifetime(editor) { editor.runModal() }
    }

    private init(alias: String, placeholder: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        field = NSTextField(frame: NSRect(x: 16, y: 56, width: 288, height: 24))
        super.init()

        panel.title = "Название станции"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let font = NSFont.systemFont(ofSize: 12)
        field.font = font
        field.stringValue = alias
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(save(_:))
        field.setAccessibilityLabel("Название станции")

        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel(_:)))
        cancelButton.frame = NSRect(x: 126, y: 12, width: 84, height: 26)
        cancelButton.bezelStyle = .rounded
        cancelButton.font = font
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save(_:)))
        saveButton.frame = NSRect(x: 218, y: 12, width: 86, height: 26)
        saveButton.bezelStyle = .rounded
        saveButton.font = font
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = []

        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(cancelButton)
        panel.contentView?.addSubview(saveButton)
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
        panel.initialFirstResponder = field
        field.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = field
    }

    private func runModal() -> String? {
        defer {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.selectText(nil)
        _ = NSApp.runModal(for: panel)
        // External abort/termination never commits the draft.
        return finished ? result : nil
    }

    @objc private func save(_ sender: Any?) {
        guard panel.makeFirstResponder(nil) else { return }
        finish(field.stringValue)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        result = value
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return true
    }
}

private final class BlueBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults: UserDefaults
    private let uiSelfTest: Bool
    private let refreshChoices = [(5, "5s"), (20, "20s"), (30, "30s"), (60, "1m"), (120, "2m")]
    private let demo = CommandLine.arguments.contains("--demo")
    private var showMenuAfterLaunch = CommandLine.arguments.contains("--show-menu")
    private var menuPopupScheduled = false
    private var statusItem: NSStatusItem!
    private var statusAutosaveName: String {
        uiSelfTest ? "BluettiBar.UISelfTest" : "BluettiBar.Status"
    }
    private lazy var brandBadge: NSImage? = {
        guard let url = Bundle.main.url(forResource: "bluetti-icon", withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()
    private var pollTimer: Timer?
    private var ageTimer: Timer?
    private var job: CLIJob?
    private var generation = 0
    private var pendingRefresh = false
    private let maximumReadRetries = 3
    private var consecutiveReadFailures = 0
    private var readPollingPaused = false
    private var nextReadRetryAt: Date?
    private var pendingScan = false
    private var isScanning = false
    private var scanError: String?
    private lazy var stationDirectory: BlueBarStationDirectory = {
        return self.demo || self.uiSelfTest ? BlueBarStationDirectory(defaults: nil) : BlueBarStationDirectory()
    }()
    private lazy var readingStore = BlueBarReadingStore(defaults: self.demo || self.uiSelfTest ? nil : self.defaults,
                                                       fallbackStatusURL: self.demo || self.uiSelfTest ? nil : self.cacheURL)
    private let stationMenu = NSMenu(title: "Станция")
    private let stationPopup = NSButton(frame: .zero)
    private var stationMenuIsOpen = false
    private var stationMenuNeedsRebuild = false
    private let renameButton = NSButton(frame: .zero)
    private var sleeping = false
    private var quitting = false
    private var awaitingFirstRead = true
    private var lastGood: Reading?
    private var lastGoodSnapshot: [String: Any]?
    private var lastError: String? = "Connecting…"
    private var hasConnectionFailure = false
    private var runtimeFrozenAt: Date?
    private var loadHistory = LoadChartHistory()
    private let loadGraph = LoadGraphView()
    private let loadGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loadGraphSeparator = NSMenuItem.separator()

    private let menu = NSMenu()
    private let fixedMenuFont = NSFont.systemFont(ofSize: 12)
    private let iconVisibilityItem = NSMenuItem(title: "Скрыть иконку", action: nil, keyEquivalent: "")
    private let runtimeItem = NSMenuItem(title: "Загрузка…", action: nil, keyEquivalent: "r")
    private let runtimeButton = NSButton(frame: .zero)
    private let runtimeRefreshButton = NSButton(frame: .zero)
    private let runtimeSpinner = NSProgressIndicator(frame: .zero)
    private let powerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let timeItem = NSMenuItem(title: "last read: …", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
    private let fontSlider = NSSlider(frame: .zero)
    private let fontSizeValue = NSTextField(labelWithString: "11")
    private let textColorButton = NSButton(frame: .zero)
    private let refreshSlider = NSSlider(frame: .zero)
    private let refreshValue = NSTextField(labelWithString: "Обновление: 30s")

    init(defaults: UserDefaults = .standard, uiSelfTest: Bool = false) {
        self.defaults = defaults
        self.uiSelfTest = uiSelfTest
        super.init()
    }

    private var refreshInterval: TimeInterval {
        let saved = defaults.integer(forKey: "refreshIntervalSeconds")
        return TimeInterval(refreshChoices.contains { $0.0 == saved } ? saved : 30)
    }

    private var maximumAge: TimeInterval { return max(90, refreshInterval + 35) }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss d/M/yy"
        return formatter.string(from: date)
    }

    private var statusFontSize: CGFloat {
        let saved = defaults.integer(forKey: "statusFontSize")
        return CGFloat((9...18).contains(saved) ? saved : 11)
    }

    private var customStatusTextColor: NSColor? {
        guard let rgb = defaults.array(forKey: "statusTextColorRGB") as? [Double],
              rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return nil
        }
        return NSColor(srgbRed: CGFloat(rgb[0]), green: CGFloat(rgb[1]),
                       blue: CGFloat(rgb[2]), alpha: 1)
    }

    private var statusTextColor: NSColor { return customStatusTextColor ?? .labelColor }

    private var showBrandIcon: Bool {
        return defaults.object(forKey: "showBrandIcon") == nil || defaults.bool(forKey: "showBrandIcon")
    }

    private var isLoadingReading: Bool {
        return !sleeping && !quitting && !readPollingPaused
            && (awaitingFirstRead || pendingRefresh || (job != nil && !isScanning))
    }

    private var identifier: String {
        return defaults.string(forKey: "stationIdentifier") ?? ""
    }

    private var cacheURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
        return directory.appendingPathComponent(demo ? "demo-status.json" : "status.json")
    }

    private var helperURL: URL {
        return Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BluettiBar")
    }

    private func buildMenu(restoringReading: Bool) {
        // AppKit also persists automatically named items. Never let the hidden
        // installer test reuse the real item's visibility or saved position.
        if !uiSelfTest {
            // AppKit's position hint requests the right edge of the status area.
            // Seed it before creating/naming the item; no other app is changed.
            let positionKey = "NSStatusItem Preferred Position " + statusAutosaveName
            if defaults.object(forKey: positionKey) == nil { defaults.set(0, forKey: positionKey) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = statusAutosaveName
        statusItem.behavior = []
        statusItem.isVisible = !uiSelfTest
        if let button = statusItem.button {
            button.setAccessibilityIdentifier(statusAutosaveName)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: statusFontSize, weight: .regular)
            button.image = nil
            button.imagePosition = .noImage
        }
        // Read the separate per-station store before status.json is replaced by
        // a pending/error response. A restored sample never becomes fresh API data.
        if restoringReading { restoreSelectedReading() }
        makeMenu()
        statusItem.menu = menu
        menu.delegate = self
        render()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu(restoringReading: true)
        do {
            BluettiInstallation.publishReady(features: try verifiedMenuFeatures())
        } catch {
            NSLog("BluettiBar UI readiness: %@", error.localizedDescription)
        }
        writeFailure("Waiting for a fresh Bluetooth reading.")

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        restartPollTimer()
        restartAgeTimer()
        refresh()
        if showMenuAfterLaunch { scheduleMenuPopup() }
    }

    // Validate the live AppKit object tree, not source text or a parallel test menu.
    // The same gate also identifies what the newly launched GUI really built.
    private func verifiedMenuFeatures() throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "BluettiBar.UI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func visibleRow(containing control: NSView, named name: String) throws -> NSView {
            for item in menu.items {
                guard let row = item.view, control === row || control.isDescendant(of: row) else { continue }
                try require(item.menu === menu && !item.isHidden && item.isEnabled,
                            name + " is not in an enabled, visible main-menu row.")
                var current: NSView? = control
                while let view = current {
                    try require(!view.isHidden, name + " has a hidden view.")
                    if view === row { break }
                    current = view.superview
                }
                let frame = row.convert(control.bounds, from: control)
                try require(frame.width > 0 && frame.height > 0 && row.bounds.contains(frame),
                            name + " is outside its menu row.")
                return row
            }
            throw NSError(domain: "BluettiBar.UI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: name + " is detached from the main menu."])
        }
        func validImage(_ image: NSImage?) -> Bool {
            guard let image = image else { return false }
            return image.isValid && image.size.width > 0 && image.size.height > 0
        }
        try require(statusItem != nil && statusItem.button != nil && statusItem.menu === menu,
                    "The status button is not attached to the actual menu.")
        try require(statusItem.autosaveName == statusAutosaveName,
                    "The status item does not have its own saved identity.")
        try require(statusItem.isVisible == !uiSelfTest,
                    "The running status item is hidden, or the UI test is not isolated.")
        try require(menu.font == fixedMenuFont && stationMenu.font == fixedMenuFont,
                    "The fixed menu fonts are missing.")
        let fontRow = try visibleRow(containing: fontSlider, named: "Font slider")
        try require(fontSlider.isEnabled && fontSlider.minValue == 9 && fontSlider.maxValue == 18
                    && fontSlider.target === self && fontSlider.action == #selector(changeFontSize(_:)),
                    "The font slider range or action is invalid.")
        let intervalRow = try visibleRow(containing: refreshSlider, named: "Refresh slider")
        try require(intervalRow !== fontRow && refreshSlider.isEnabled
                    && refreshSlider.minValue == 0 && refreshSlider.maxValue == 4
                    && refreshSlider.numberOfTickMarks == 5 && refreshSlider.allowsTickMarkValuesOnly
                    && refreshSlider.target === self && refreshSlider.action == #selector(changeRefreshInterval(_:)),
                    "The refresh slider range or action is invalid.")
        let colorRow = try visibleRow(containing: textColorButton, named: "Color button")
        try require(colorRow === fontRow && textColorButton.isEnabled && validImage(textColorButton.image)
                    && textColorButton.target === self && textColorButton.action == #selector(chooseTextColor),
                    "The color button is missing from the font row.")
        let stationRow = try visibleRow(containing: stationPopup, named: "Station picker")
        let pencilRow = try visibleRow(containing: renameButton, named: "Station pencil")
        try require(stationRow === pencilRow && stationPopup.font == fixedMenuFont
                    && validImage(stationPopup.image) && validImage(renameButton.image)
                    && stationPopup.target === self && stationPopup.action == #selector(showStationMenu)
                    && renameButton.target === self && renameButton.action == #selector(renameStation)
                    && stationMenu.items.contains(where: { $0.action == #selector(selectStation(_:)) })
                    && stationMenu.items.contains(where: { $0.action == #selector(requestStationScan) }),
                    "The station dropdown or pencil action is incomplete.")
        _ = try visibleRow(containing: runtimeButton, named: "Runtime refresh")
        try require(menu.items.first === runtimeItem && runtimeButton.font == fixedMenuFont
                    && runtimeButton.target === self && runtimeButton.action == #selector(refreshClicked)
                    && runtimeRefreshButton.superview === runtimeButton.superview
                    && runtimeRefreshButton.target === self && runtimeRefreshButton.action == #selector(refreshClicked)
                    && validImage(runtimeRefreshButton.image) && runtimeSpinner.superview != nil,
                    "The first-row refresh controls are incomplete.")
        try require(iconVisibilityItem.menu === menu && iconVisibilityItem.target === self
                    && iconVisibilityItem.action == #selector(toggleBrandIcon)
                    && validImage(iconVisibilityItem.image), "The icon toggle is missing.")
        try require(validImage(brandBadge) && brandBadge?.tiffRepresentation != nil,
                    "The bundled BLUETTI image cannot be decoded.")
        if showBrandIcon || lastGood == nil {
            try require(validImage(statusItem.button?.image), "The rendered status image is missing.")
        }
        try require(menu.items.last === loadGraphItem && loadGraphItem.view === loadGraph
                    && menu.numberOfItems >= 2 && menu.item(at: menu.numberOfItems - 2) === loadGraphSeparator
                    && loadGraph.frame.width > 0 && loadGraph.frame.height > 0
                    && loadGraphItem.isHidden == (lastGood == nil)
                    && loadGraphSeparator.isHidden == loadGraphItem.isHidden,
                    "The load graph is not in its expected final position.")
        let features = ["font_slider", "interval_slider", "icon_toggle", "color_control",
                        "station_menu", "runtime_refresh", "load_graph", "brand_asset"]
        // This proves that AppKit has enabled the item, not that a crowded menu
        // bar or display notch cannot cover it. Only the normal UI reports it.
        return uiSelfTest ? features : features + ["status_item_visible"]
    }

    static func runUISelfTest() -> Int32 {
        // A private, volatile defaults domain and memory-only station stores keep
        // this pre-installation check independent of the user's preferences/data.
        guard let testDefaults = UserDefaults(suiteName: "com.local.bluebar.ui-test." + UUID().uuidString) else {
            return 1
        }
        testDefaults.setVolatileDomain(["statusFontSize": 11, "refreshIntervalSeconds": 30,
                                       "showBrandIcon": true, "stationIdentifier": "",
                                       "statusTextColorRGB": [Double]()], forName: UserDefaults.argumentDomain)
        let delegate = BlueBarDelegate(defaults: testDefaults, uiSelfTest: true)
        delegate.buildMenu(restoringReading: false)
        defer {
            delegate.runtimeSpinner.stopAnimation(nil)
            if let item = delegate.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        do {
            _ = try delegate.verifiedMenuFeatures()
            let now = Date()
            delegate.awaitingFirstRead = false
            delegate.lastError = nil
            delegate.lastGood = Reading(percent: 73, device: "AC50P UI test", deviceID: nil, measuredAt: now,
                acInput: 0, dcInput: 0, acOutput: 120, dcOutput: 0,
                inputPowerRetainedAt: nil, outputPowerRetainedAt: nil,
                runtime: RuntimeEstimate(state: .discharging, source: .station, backup: false,
                                         remainingSeconds: 7200, windowSeconds: nil, dropPercent: nil),
                runtimeMeasuredAt: now, runtimePercent: 73, runtimeCarriedForward: false)
            delegate.render()
            let features = try delegate.verifiedMenuFeatures()
            guard delegate.statusItem.button?.title == "73%", !delegate.timeItem.isHidden,
                  delegate.statusItem.button?.image?.tiffRepresentation != nil else {
                throw NSError(domain: "BluettiBar.UI", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The actual reading did not render into the status item."])
            }
            let data = try JSONSerialization.data(withJSONObject:
                ["ok": true, "ui_self_test": "passed", "features": features.sorted()], options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([0x0a]))
            return 0
        } catch {
            let value: [String: Any] = ["ok": false, "ui_self_test": "failed", "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([0x0a]))
            }
            return 1
        }
    }

    // A second `open BluettiBar.app` is delivered to this running instance. The
    // popup stays reachable even when macOS hides its status item under a notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItem == nil { showMenuAfterLaunch = true }
        else { scheduleMenuPopup() }
        return false
    }

    private func scheduleMenuPopup() {
        guard !quitting, !menuPopupScheduled else { return }
        menuPopupScheduled = true
        // Let launch/reopen finish first; never wait for Bluetooth or an ETA.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.menuPopupScheduled = false
            guard !self.quitting, self.statusItem != nil else { return }
            self.render()
            NSApp.activate(ignoringOtherApps: true)
            self.menu.cancelTracking()
            _ = self.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func makeMenu() {
        menu.autoenablesItems = false
        menu.font = fixedMenuFont
        addRuntimeControl()
        for item in [powerItem, timeItem, connectionItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addStationControl()
        addRefreshControl()
        addTextControls()
        iconVisibilityItem.target = self
        iconVisibilityItem.action = #selector(toggleBrandIcon)
        if let icon = brandBadge?.copy() as? NSImage {
            icon.size = NSSize(width: 12, height: 12)
            icon.isTemplate = false
            iconVisibilityItem.image = icon
        }
        menu.addItem(iconVisibilityItem)
        menu.addItem(.separator())
        action("Quit BluettiBar", #selector(quit), key: "q")
        menu.addItem(loadGraphSeparator)
        loadGraphItem.view = loadGraph
        loadGraphItem.isEnabled = false
        // Axes remain visible before the first two real measurements arrive.
        menu.addItem(loadGraphItem)
    }

    @discardableResult
    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addRuntimeControl() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        row.autoresizingMask = [.width]
        runtimeButton.frame = NSRect(x: 10, y: 3, width: 198, height: 24)
        runtimeButton.autoresizingMask = [.width]
        runtimeButton.isBordered = false
        runtimeButton.alignment = .left
        runtimeButton.font = fixedMenuFont
        runtimeButton.target = self
        runtimeButton.action = #selector(refreshClicked)
        row.addSubview(runtimeButton)
        runtimeRefreshButton.frame = NSRect(x: 212, y: 3, width: 22, height: 24)
        runtimeRefreshButton.autoresizingMask = [.minXMargin]
        runtimeRefreshButton.isBordered = false
        runtimeRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Обновить")?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        runtimeRefreshButton.imagePosition = .imageOnly
        runtimeRefreshButton.imageScaling = .scaleNone
        runtimeRefreshButton.target = self
        runtimeRefreshButton.action = #selector(refreshClicked)
        runtimeRefreshButton.toolTip = "Обновить"
        row.addSubview(runtimeRefreshButton)
        // Keep native spinner drawing, with a compact but readable 12-point size.
        let spinnerBox = NSView(frame: NSRect(x: 217, y: 9, width: 12, height: 12))
        spinnerBox.bounds = NSRect(x: 0, y: 0, width: 16, height: 16)
        spinnerBox.autoresizingMask = [.minXMargin]
        runtimeSpinner.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        runtimeSpinner.style = .spinning
        runtimeSpinner.controlSize = .small
        runtimeSpinner.isIndeterminate = true
        runtimeSpinner.isDisplayedWhenStopped = false
        runtimeSpinner.setAccessibilityLabel("Получение показаний")
        spinnerBox.addSubview(runtimeSpinner)
        row.addSubview(spinnerBox)
        runtimeItem.target = self
        runtimeItem.action = #selector(refreshClicked)
        runtimeItem.view = row
        runtimeItem.isEnabled = true
        menu.addItem(runtimeItem)
    }

    private var selectedKnownStation: BlueBarKnownStation? {
        if !identifier.isEmpty {
            let stations = stationDirectory.stations
            if let exact = stations.first(where: {
                $0.deviceID?.caseInsensitiveCompare(identifier) == .orderedSame
            }) { return exact }
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping.lowercased()
            let matches = stations.filter { $0.seenNames.contains(name) }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let sample = lastGood else { return nil }
        return stationDirectory.station(deviceID: sample.deviceID, bluetoothName: sample.device)
    }

    private var stationDisplayName: String {
        if let sample = lastGood {
            return stationDirectory.displayName(deviceID: sample.deviceID, bluetoothName: sample.device)
        }
        return selectedKnownStation?.displayName ?? (identifier.isEmpty ? "Авто" : identifier)
    }

    private func addStationControl() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 31))
        row.autoresizingMask = [.width]
        stationMenu.autoenablesItems = false
        stationMenu.font = fixedMenuFont
        stationMenu.delegate = self
        stationPopup.frame = NSRect(x: 7, y: 3, width: 197, height: 25)
        stationPopup.autoresizingMask = [.width]
        stationPopup.controlSize = .small
        stationPopup.font = fixedMenuFont
        stationPopup.bezelStyle = .rounded
        stationPopup.alignment = .left
        stationPopup.cell?.lineBreakMode = .byTruncatingTail
        stationPopup.image = NSImage(systemSymbolName: "chevron.down",
            accessibilityDescription: "Выбрать станцию")?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        stationPopup.imagePosition = .imageRight
        stationPopup.imageScaling = .scaleNone
        stationPopup.target = self
        stationPopup.action = #selector(showStationMenu)
        stationPopup.setAccessibilityLabel("Станция")
        row.addSubview(stationPopup)
        renameButton.frame = NSRect(x: 207, y: 4, width: 26, height: 24)
        renameButton.autoresizingMask = [.minXMargin]
        renameButton.isBordered = false
        renameButton.image = NSImage(systemSymbolName: "pencil",
            accessibilityDescription: "Название станции")?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        renameButton.imagePosition = .imageOnly
        renameButton.imageScaling = .scaleNone
        renameButton.target = self
        renameButton.action = #selector(renameStation)
        renameButton.toolTip = "Название станции"
        renameButton.setAccessibilityLabel("Название станции")
        row.addSubview(renameButton)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = true
        menu.addItem(item)
        rebuildStationMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === stationMenu { stationMenuIsOpen = true; return }
        render()
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === stationMenu {
            stationMenuIsOpen = false
            if stationMenuNeedsRebuild { rebuildStationMenu() }
        }
    }

    @objc private func showStationMenu() {
        guard !demo, !quitting else { return }
        let anchor = NSEvent.mouseLocation
        // End the parent menu's tracking before starting another native menu.
        // Nested pop-up controls can otherwise swallow the click when offline.
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.quitting else { return }
            self.rebuildStationMenu()
            NSApp.activate(ignoringOtherApps: true)
            let selected = self.stationMenu.items.first { $0.state == .on }
            _ = self.stationMenu.popUp(positioning: selected, at: anchor, in: nil)
        }
    }

    private func addTextControls() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        row.autoresizingMask = [.width]
        fontSizeValue.frame = NSRect(x: 6, y: 9, width: 34, height: 16)
        fontSizeValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontSizeValue.textColor = .secondaryLabelColor
        fontSizeValue.alignment = .right
        fontSizeValue.toolTip = nil
        row.addSubview(fontSizeValue)
        fontSlider.frame = NSRect(x: 46, y: 6, width: 112, height: 22)
        fontSlider.autoresizingMask = [.width]
        fontSlider.minValue = 9
        fontSlider.maxValue = 18
        fontSlider.isContinuous = true
        fontSlider.controlSize = .small
        fontSlider.target = self
        fontSlider.action = #selector(changeFontSize(_:))
        fontSlider.toolTip = nil
        fontSlider.setAccessibilityLabel("Размер текста")
        row.addSubview(fontSlider)
        textColorButton.frame = NSRect(x: 166, y: 5, width: 28, height: 24)
        textColorButton.autoresizingMask = [.minXMargin]
        textColorButton.title = ""
        textColorButton.bezelStyle = .rounded
        textColorButton.imagePosition = .imageOnly
        textColorButton.target = self
        textColorButton.action = #selector(chooseTextColor)
        textColorButton.toolTip = "Цвет текста"
        textColorButton.setAccessibilityLabel("Цвет текста")
        row.addSubview(textColorButton)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = true
        menu.addItem(item)
        updateTextControls()
    }

    private func updateTextControls() {
        fontSlider.doubleValue = Double(statusFontSize)
        fontSizeValue.stringValue = String(Int(statusFontSize)) + "px"
        let color = statusTextColor
        textColorButton.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let swatch = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            color.setFill()
            swatch.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            swatch.lineWidth = 0.5
            swatch.stroke()
            return true
        }
        render()
    }

    @objc private func changeFontSize(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let size = Int(min(18, max(9, sender.doubleValue)).rounded())
        defaults.set(size, forKey: "statusFontSize")
        updateTextControls()
    }

    @objc private func chooseTextColor() {
        // End menu tracking first so the system color panel receives its events.
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.quitting else { return }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSColorPanel.shared
            panel.title = "Цвет текста"
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = self.statusTextColor
            panel.setTarget(self)
            panel.setAction(#selector(self.changeTextColor(_:)))
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func changeTextColor(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        let rgb = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        guard rgb.allSatisfy({ $0.isFinite }) else { return }
        defaults.set(rgb.map { min(1, max(0, $0)) }, forKey: "statusTextColorRGB")
        updateTextControls()
    }

    @objc private func toggleBrandIcon() {
        defaults.set(!showBrandIcon, forKey: "showBrandIcon")
        render()
    }

    private func statusSymbol(_ name: String, description: String,
                              color: NSColor, alpha: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description),
              symbol.size.width > 0, symbol.size.height > 0 else { return nil }
        let edge: CGFloat = 6 * statusFontSize / 11
        let scale: CGFloat = edge / max(symbol.size.width, symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let icon = NSImage(size: size)
        let drawIcon = {
            icon.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.withAlphaComponent(alpha).setFill()
            rect.fill(using: .sourceIn)
            icon.unlockFocus()
        }
        if let appearance = statusItem?.button?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance(drawIcon)
        } else { drawIcon() }
        // With the default color, let the menu bar resolve its own appearance.
        // Explicit RGB colors keep their pre-tinted pixels.
        icon.isTemplate = customStatusTextColor == nil
        return icon
    }

    private func statusBarImage(color: NSColor, hasReading: Bool, loading: Bool, offline: Bool) -> NSImage? {
        let indicator: NSImage?
        if hasReading && loading {
            indicator = statusSymbol("arrow.clockwise", description: "Получение показаний",
                                     color: color, alpha: 0.65)
        } else if hasReading && offline {
            indicator = statusSymbol("wifi.slash", description: "Нет связи",
                                     color: color, alpha: 0.45)
        } else { indicator = nil }
        // With no known percentage, keep just the brand as the menu's handle,
        // even when the user normally hides it beside a known percentage.
        guard showBrandIcon || !hasReading, let badge = brandBadge else { return indicator }
        let scale = statusFontSize / 11
        let side: CGFloat = (hasReading ? 7 * scale : min(22, 18 * scale)).rounded()
        let gap: CGFloat = indicator == nil ? 0 : scale
        let size = NSSize(width: side + gap + (indicator?.size.width ?? 0), height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        badge.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
        if let indicator = indicator {
            // The indicator was already tinted in the status button's current
            // appearance. The brand's blue and white pixels stay unchanged.
            indicator.isTemplate = false
            indicator.draw(in: NSRect(x: side + gap, y: (side - indicator.size.height) / 2,
                                      width: indicator.size.width, height: indicator.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func restartPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard !readPollingPaused, !quitting else { return }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func restartAgeTimer() {
        ageTimer?.invalidate()
        ageTimer = nil
        guard !readPollingPaused, !quitting else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkAge() }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    private func resetReadRetryBudget() {
        consecutiveReadFailures = 0
        readPollingPaused = false
        nextReadRetryAt = nil
        restartPollTimer()
        restartAgeTimer()
    }

    // Only a failed station-read attempt reaches this method. Scan, restore,
    // staleness, sleep and cancelled/obsolete generations do not spend retries.
    private func readFailed(_ error: String) {
        pendingRefresh = false
        consecutiveReadFailures += 1
        if consecutiveReadFailures > maximumReadRetries {
            readPollingPaused = true
            nextReadRetryAt = nil
            pollTimer?.invalidate()
            pollTimer = nil
            ageTimer?.invalidate()
            ageTimer = nil
            fail(error + "\nАвтообновление остановлено после 3 повторов. Нажмите обновить.")
        } else {
            // Start the next retry no sooner than one selected interval after
            // this failure, including calls queued behind a station scan.
            nextReadRetryAt = Date().addingTimeInterval(refreshInterval)
            restartPollTimer()
            fail(error)
        }
    }

    private func addRefreshControl() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 42))
        row.autoresizingMask = [.width]
        refreshValue.frame = NSRect(x: 12, y: 25, width: 180, height: 15)
        refreshValue.autoresizingMask = [.width]
        refreshValue.font = .systemFont(ofSize: 11)
        refreshValue.textColor = .secondaryLabelColor
        row.addSubview(refreshValue)
        refreshSlider.frame = NSRect(x: 10, y: 1, width: 180, height: 24)
        refreshSlider.autoresizingMask = [.width]
        refreshSlider.controlSize = .small
        refreshSlider.minValue = 0
        refreshSlider.maxValue = Double(refreshChoices.count - 1)
        refreshSlider.numberOfTickMarks = refreshChoices.count
        refreshSlider.allowsTickMarkValuesOnly = true
        refreshSlider.isContinuous = true
        refreshSlider.target = self
        refreshSlider.action = #selector(changeRefreshInterval(_:))
        refreshSlider.toolTip = "5s / 20s / 30s / 1m / 2m"
        refreshSlider.setAccessibilityLabel("Интервал обновления")
        row.addSubview(refreshSlider)
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = true
        menu.addItem(item)
        updateRefreshControl()
    }

    private func updateRefreshControl() {
        let index = refreshChoices.firstIndex { $0.0 == Int(refreshInterval) } ?? 2
        refreshSlider.doubleValue = Double(index)
        refreshValue.stringValue = "Обновление: " + refreshChoices[index].1
        refreshSlider.setAccessibilityValue(refreshChoices[index].1)
    }

    @objc private func changeRefreshInterval(_ sender: NSSlider) {
        guard sender.doubleValue.isFinite else { return }
        let index = Int(min(Double(refreshChoices.count - 1), max(0, sender.doubleValue)).rounded())
        let seconds = refreshChoices[index].0
        guard seconds != Int(refreshInterval) else { updateRefreshControl(); return }
        defaults.set(seconds, forKey: "refreshIntervalSeconds")
        updateRefreshControl()
        if consecutiveReadFailures > 0 && !readPollingPaused {
            nextReadRetryAt = Date().addingTimeInterval(refreshInterval)
        }
        restartPollTimer()
        refresh()
    }

    @objc private func refreshClicked() {
        guard !sleeping, !quitting else { return }
        resetReadRetryBudget()
        pendingRefresh = true
        refresh()
    }

    private func refresh() {
        guard !sleeping, !quitting, !readPollingPaused, job == nil else { return }
        if let retryAt = nextReadRetryAt, Date() < retryAt { return }
        pendingRefresh = false
        if demo {
            let snapshot: [String: Any] = [
                "ok": true, "model": "AC50P", "device": "DEMO — no station connected",
                "battery_percent": 73, "observed_at": Date().timeIntervalSince1970,
                "ac_input_w": 0, "dc_input_w": 0, "ac_output_w": 120, "dc_output_w": 15,
                "runtime": ["state": "discharging", "source": "soc_history", "remaining_seconds": 14_600,
                            "window_seconds": 600, "drop_percent": 3] as [String: Any],
                "demo": true
            ]
            accept(snapshot)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            readFailed("Bluetooth reader is missing. Reinstall BluettiBar to restore the app executable.")
            return
        }
        let read = CLIJob()
        let thisGeneration = generation
        job = read
        var arguments = ["status", "--timeout", "28"]
        if !identifier.isEmpty { arguments += ["--device", identifier] }
        render()
        read.run(executable: helperURL, arguments: arguments) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                if thisGeneration != self.generation || self.sleeping {
                    self.render()
                } else {
                    self.handle(result)
                }
                self.runQueuedWork()
            }
        }
    }

    private func handle(_ result: CLIResult) {
        if let error = result.error { readFailed(error); return }
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        if result.exitCode != 0 || object?["ok"] as? Bool != true {
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (object?["error"] as? String)
                ?? (stderr?.isEmpty == false ? stderr! : "Reader returned no valid status (exit \(result.exitCode)).")
            readFailed(detail)
            return
        }
        guard let snapshot = object else { readFailed("Reader returned invalid JSON."); return }
        accept(snapshot)
    }

    @discardableResult
    private func accept(_ snapshot: [String: Any], restoring: Bool = false) -> Bool {
        func reject(_ message: String) -> Bool {
            if !restoring { readFailed(message) }
            return false
        }
        guard snapshot["ok"] as? Bool == true,
              let number = snapshot["battery_percent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              (0.0...100.0).contains(number.doubleValue),
              snapshot["model"] as? String == "AC50P",
              let device = snapshot["device"] as? String, !device.isEmpty,
              let timestamp = snapshot["observed_at"] as? NSNumber,
              CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              timestamp.doubleValue.isFinite, timestamp.doubleValue >= 0 else {
            return reject("Reader returned an invalid battery percentage, station identity or timestamp.")
        }
        let measuredAt = Date(timeIntervalSince1970: timestamp.doubleValue)
        let age = Date().timeIntervalSince(measuredAt)
        guard age >= -30, restoring || age <= maximumAge else {
            return reject("Reader returned an old or invalid timestamp; waiting for a fresh sample.")
        }
        func watts(_ key: String) -> Double? {
            guard let value = snapshot[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        let deviceID = (snapshot["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let previous: Reading?
        if !restoring, let saved = lastGood {
            let sameStation: Bool
            if let oldID = saved.deviceID, let newID = deviceID {
                sameStation = oldID.caseInsensitiveCompare(newID) == .orderedSame
            } else if saved.deviceID == nil && deviceID == nil {
                sameStation = saved.device == device
            } else {
                sameStation = false
            }
            previous = sameStation ? saved : nil
            if !sameStation {
                loadHistory.clear()
                runtimeFrozenAt = nil
            }
        } else { previous = nil }
        let acInput = watts("ac_input_w"), dcInput = watts("dc_input_w")
        let acOutput = watts("ac_output_w"), dcOutput = watts("dc_output_w")
        let inputRetained = (acInput == nil && previous?.acInput != nil)
            || (dcInput == nil && previous?.dcInput != nil)
        let outputRetained = (acOutput == nil && previous?.acOutput != nil)
            || (dcOutput == nil && previous?.dcOutput != nil)
        let parsedRuntime = RuntimeEstimate.parse(snapshot["runtime"], percent: number.intValue)
        // No new numeric ETA: retain its original meaning and observation time.
        // A valid zero is a new value and must replace an earlier estimate.
        let carryRuntime = parsedRuntime?.remainingSeconds == nil
            && previous?.runtime.remainingSeconds != nil
        if carryRuntime { freezeRuntime() }
        else { runtimeFrozenAt = nil }
        let runtime = carryRuntime ? previous!.runtime : (parsedRuntime ?? .unavailable)
        var reading = Reading(percent: number.intValue,
                           device: device, deviceID: deviceID,
                           measuredAt: measuredAt,
                           acInput: acInput ?? previous?.acInput, dcInput: dcInput ?? previous?.dcInput,
                           acOutput: acOutput ?? previous?.acOutput, dcOutput: dcOutput ?? previous?.dcOutput,
                           inputPowerRetainedAt: inputRetained ? (previous?.inputPowerRetainedAt ?? previous?.measuredAt) : nil,
                           outputPowerRetainedAt: outputRetained ? (previous?.outputPowerRetainedAt ?? previous?.measuredAt) : nil,
                           runtime: runtime,
                           runtimeMeasuredAt: carryRuntime ? previous!.runtimeMeasuredAt : measuredAt,
                           runtimePercent: carryRuntime ? previous!.runtimePercent : number.intValue,
                           runtimeCarriedForward: carryRuntime)
        if restoring {
            let frozen = restoreDisplayMetadata(snapshot["_bluebar_display"], into: &reading)
            // Offline elapsed time is not a new measurement. Freeze the saved
            // estimate at its saved display moment, or at its observation.
            runtimeFrozenAt = frozen ?? reading.runtimeMeasuredAt
        }
        lastGood = reading
        lastGoodSnapshot = snapshot
        stationDirectory.ingestStatus(snapshot)
        if restoring {
            loadHistory.markGap()
            lastError = "Waiting for a fresh Bluetooth reading."
            hasConnectionFailure = false
            return true
        }
        // Older versions allowed a partial CLI selector. Once a real reading
        // identifies it, persist the exact target so restart can restore it.
        if !demo && !identifier.isEmpty {
            defaults.set(deviceID ?? device, forKey: "stationIdentifier")
        }
        consecutiveReadFailures = 0
        readPollingPaused = false
        nextReadRetryAt = nil
        awaitingFirstRead = false
        rebuildStationMenu()
        let totalOutput: Double?
        if let ac = acOutput, let dc = dcOutput { totalOutput = ac + dc }
        else { totalOutput = nil }
        loadHistory.append(timestamp: measuredAt, watts: totalOutput, maximumGap: maximumAge)
        lastError = nil
        hasConnectionFailure = false
        saveReadingState()
        // Keep the actual helper payload in the API cache. Retained display
        // fields are never relabelled with the new sample's timestamp.
        writeCache(snapshot)
        render()
        return true
    }

    private func restoreSelectedReading() {
        lastGood = nil
        lastGoodSnapshot = nil
        runtimeFrozenAt = nil
        guard !demo,
              let snapshot = readingStore.reading(for: identifier, knownStations: stationDirectory.stations) else { return }
        accept(snapshot, restoring: true)
    }

    private func restoreDisplayMetadata(_ value: Any?, into reading: inout Reading) -> Date? {
        guard let display = value as? [String: Any] else { return nil }
        func number(_ value: Any?) -> Double? {
            guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  raw.doubleValue.isFinite else { return nil }
            return raw.doubleValue
        }
        func date(_ key: String) -> Date? {
            return number(display[key]).map { Date(timeIntervalSince1970: $0) }
        }
        guard number(display["version"]) == 1 else { return nil }
        for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w"] {
            if let raw = display[key] {
                guard let watts = number(raw), watts >= 0 else { return nil }
            }
        }
        if let raw = display["runtime_battery_percent"], number(raw) == nil { return nil }
        let percent = number(display["runtime_battery_percent"]) ?? Double(reading.percent)
        guard percent.rounded() == percent, (0...100).contains(percent),
              let runtime = RuntimeEstimate.parse(display["runtime"], percent: Int(percent)),
              let observed = number(display["runtime_observed_at"]), observed >= 0,
              observed <= reading.measuredAt.timeIntervalSince1970 + 30,
              observed <= Date().timeIntervalSince1970 + 30 else { return nil }
        for key in ["input_retained_at", "output_retained_at", "runtime_frozen_at"] {
            if let raw = display[key] {
                guard let seconds = number(raw), seconds >= 0,
                      seconds <= Date().timeIntervalSince1970 + 30,
                      (key == "runtime_frozen_at" ? seconds >= observed
                       : seconds <= reading.measuredAt.timeIntervalSince1970 + 30) else { return nil }
            }
        }
        var carried = false
        if let raw = display["runtime_carried_forward"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            carried = flag.boolValue
        }
        // A current valid raw value, especially zero, wins over retained data.
        reading.acInput = reading.acInput ?? number(display["ac_input_w"])
        reading.dcInput = reading.dcInput ?? number(display["dc_input_w"])
        reading.acOutput = reading.acOutput ?? number(display["ac_output_w"])
        reading.dcOutput = reading.dcOutput ?? number(display["dc_output_w"])
        reading.inputPowerRetainedAt = date("input_retained_at")
        reading.outputPowerRetainedAt = date("output_retained_at")
        reading.runtime = runtime
        reading.runtimeMeasuredAt = Date(timeIntervalSince1970: observed)
        reading.runtimePercent = Int(percent)
        reading.runtimeCarriedForward = carried
        return date("runtime_frozen_at")
    }

    private func saveReadingState() {
        guard let reading = lastGood, var snapshot = lastGoodSnapshot else { return }
        var display: [String: Any] = [
            "version": 1,
            "runtime": reading.runtime.json,
            "runtime_observed_at": reading.runtimeMeasuredAt.timeIntervalSince1970,
            "runtime_battery_percent": reading.runtimePercent,
            "runtime_carried_forward": reading.runtimeCarriedForward
        ]
        if let watts = reading.acInput { display["ac_input_w"] = watts }
        if let watts = reading.dcInput { display["dc_input_w"] = watts }
        if let watts = reading.acOutput { display["ac_output_w"] = watts }
        if let watts = reading.dcOutput { display["dc_output_w"] = watts }
        if let date = reading.inputPowerRetainedAt { display["input_retained_at"] = date.timeIntervalSince1970 }
        if let date = reading.outputPowerRetainedAt { display["output_retained_at"] = date.timeIntervalSince1970 }
        if let date = runtimeFrozenAt { display["runtime_frozen_at"] = date.timeIntervalSince1970 }
        snapshot["_bluebar_display"] = display
        readingStore.save(snapshot, automatic: identifier.isEmpty)
    }

    private func freezeRuntime() {
        guard runtimeFrozenAt == nil, let sample = lastGood else { return }
        runtimeFrozenAt = min(Date(), sample.runtimeMeasuredAt.addingTimeInterval(maximumAge))
    }

    private func fail(_ error: String, offline: Bool = true) {
        awaitingFirstRead = false
        lastError = error
        hasConnectionFailure = offline
        freezeRuntime()
        saveReadingState()
        loadHistory.markGap()
        writeFailure(error)
        render()
    }

    private func checkAge() {
        guard !quitting, let reading = lastGood, lastError == nil else { return }
        if Date().timeIntervalSince(reading.measuredAt) > maximumAge {
            fail("Reading is stale; waiting for a fresh Bluetooth sample.")
        }
    }

    private func writeFailure(_ error: String) {
        var snapshot: [String: Any] = [
            "ok": false, "model": "AC50P", "error": error,
            "checked_at": Date().timeIntervalSince1970
        ]
        if let reading = lastGood {
            snapshot["last_success_at"] = reading.measuredAt.timeIntervalSince1970
        }
        if demo { snapshot["demo"] = true }
        writeCache(snapshot)
    }

    private func writeCache(_ snapshot: [String: Any]) {
        var cached = snapshot
        cached["refresh_interval_seconds"] = Int(refreshInterval)
        guard var data = try? JSONSerialization.data(withJSONObject: cached, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: nil)
            try data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            NSLog("BluettiBar: cannot write status cache: %@", error.localizedDescription)
        }
    }

    private func render() {
        guard statusItem != nil else { return }
        if !uiSelfTest && !quitting && !statusItem.isVisible { statusItem.isVisible = true }
        let reading = lastGood
        let now = Date()
        let stale = reading.map { now.timeIntervalSince($0.measuredAt) > maximumAge } ?? false
        let offline = sleeping || hasConnectionFailure || stale
        if offline || reading?.runtimeCarriedForward == true { freezeRuntime() }
        renderRuntime(reading)
        // Never spend menu-bar width on words or placeholder dashes.
        // The menu and tooltip explain states; an existing percentage stays.
        let title = reading.map { "\($0.percent)%" } ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: statusFontSize, weight: .regular)
        let color = statusTextColor
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let custom = customStatusTextColor { attributes[.foregroundColor] = custom }
        let styledTitle = NSAttributedString(string: title, attributes: attributes)
        statusItem.button?.title = title
        statusItem.button?.font = font
        statusItem.button?.attributedTitle = styledTitle
        let showInitialLoading = awaitingFirstRead && isLoadingReading
        let image = statusBarImage(color: color, hasReading: reading != nil,
                                   loading: showInitialLoading, offline: offline)
        statusItem.button?.image = image
        statusItem.button?.imagePosition = image == nil ? .noImage : .imageLeft
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.setAccessibilityLabel((demo ? "DEMO, " : "") + "BLUETTI, " + title
            + (showInitialLoading ? ", получение показаний" : (offline ? ", нет связи" : "")))
        func powerText(_ direction: String, _ dc: Double?, _ ac: Double?) -> String? {
            var names: [String] = []
            var values: [String] = []
            for (name, value) in [("DC", dc), ("AC", ac)] {
                if let value = value, value.isFinite, value > 0 {
                    names.append(name)
                    values.append(String(format: "%g", value) + "w")
                }
            }
            guard !names.isEmpty else { return nil }
            return direction + " " + names.joined(separator: "|") + ": " + values.joined(separator: "|")
        }
        let powers = [powerText("in", reading?.dcInput, reading?.acInput),
                      powerText("out", reading?.dcOutput, reading?.acOutput)].compactMap { $0 }
        powerItem.title = powers.joined(separator: " · ")
        powerItem.isHidden = powers.isEmpty
        var powerDetails: [String] = []
        if let date = reading?.inputPowerRetainedAt { powerDetails.append("in · last read: " + shortDate(date)) }
        if let date = reading?.outputPowerRetainedAt { powerDetails.append("out · last read: " + shortDate(date)) }
        powerItem.toolTip = powerDetails.isEmpty ? nil : powerDetails.joined(separator: "\n")
        loadGraph.update(points: loadHistory.visiblePoints(at: now), now: now)
        loadGraphItem.isHidden = reading == nil
        loadGraphSeparator.isHidden = reading == nil
        stationPopup.title = stationDisplayName
        stationPopup.toolTip = reading?.device ?? selectedKnownStation?.bluetoothName
        stationPopup.isEnabled = !demo && !quitting
        renameButton.isEnabled = selectedKnownStation != nil && !quitting
        if let sample = reading {
            timeItem.title = "last read: " + shortDate(sample.measuredAt)
        }
        timeItem.isHidden = reading == nil
        // Without a prior reading, the first row itself reports loading/error.
        connectionItem.isHidden = reading == nil || !offline
        if sleeping { connectionItem.title = "Сон" }
        else if stale { connectionItem.title = "Нет обновлений" }
        else if hasConnectionFailure { connectionItem.title = "Нет связи" }
        else { connectionItem.title = "Подключение…" }
        let detail = lastError ?? (stale ? "Waiting for a fresh Bluetooth reading." : "")
        let lastRead = reading.map { "last read: " + shortDate($0.measuredAt) }
        connectionItem.toolTip = detail + (lastRead.map { "\n" + $0 } ?? "")
        statusItem.button?.toolTip = (demo ? "DEMO\n" : "") + stationDisplayName
            + (lastRead.map { "\n" + $0 } ?? "")
            + (detail.isEmpty ? "" : "\n" + detail)
        runtimeButton.title = (demo ? "DEMO · " : "") + runtimeItem.title
        iconVisibilityItem.title = showBrandIcon ? "Скрыть иконку" : "Показать иконку"
        iconVisibilityItem.isHidden = reading == nil || offline || awaitingFirstRead || lastError != nil
        let runtimeTip = (runtimeItem.toolTip.map { $0 + "\n" } ?? "") + "Нажмите, чтобы обновить."
        runtimeButton.toolTip = runtimeTip
        runtimeItem.toolTip = runtimeTip
        let canRefresh = job == nil && !sleeping && !quitting
        runtimeButton.isEnabled = canRefresh
        runtimeRefreshButton.isEnabled = canRefresh
        runtimeRefreshButton.isHidden = isLoadingReading
        if isLoadingReading { runtimeSpinner.startAnimation(nil) }
        else { runtimeSpinner.stopAnimation(nil) }
    }

    private func renderRuntime(_ reading: Reading?) {
        runtimeItem.toolTip = nil
        guard let sample = reading else {
            runtimeItem.title = isLoadingReading ? "Загрузка…" : (sleeping ? "Сон" : "Нет связи")
            runtimeItem.toolTip = lastError
            return
        }
        var explanations: [String] = []
        switch sample.runtime.source {
        case .station?:
            explanations.append("Время от BLUETTI.")
        case .power?:
            explanations.append("Расчёт по мощности.")
        case .socHistory?:
            explanations.append("По изменению заряда.")
            if let window = sample.runtime.windowSeconds, window >= 120,
               let drop = sample.runtime.dropPercent, drop > 0 {
                explanations.append("Снижение на \(drop)% за \(window / 60) мин.")
            }
        case nil:
            break
        }
        func duration(_ seconds: Int, countDown: Bool = true) -> String {
            // Keep the last received estimate. Its clock stops on a failed
            // poll, sleep, stale data, or an observation without a new ETA.
            let asOf = runtimeFrozenAt
                ?? min(Date(), sample.runtimeMeasuredAt.addingTimeInterval(maximumAge))
            let elapsed = countDown ? max(0, asOf.timeIntervalSince(sample.runtimeMeasuredAt)) : 0
            let minutes = Int(ceil(max(0, Double(seconds) - elapsed) / 60))
            let hours = minutes / 60
            let rest = minutes % 60
            return hours == 0 ? "\(minutes) мин"
                : (rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин")
        }
        if sample.runtime.backup,
           sample.runtime.state == .discharging || sample.runtime.state == .empty,
           let seconds = sample.runtime.remainingSeconds {
            // This describes unplugged autonomy, not an active countdown while
            // the load is powered externally. The next fresh sample updates it.
            runtimeItem.title = seconds == 0 ? "0 мин" : "≈ " + duration(seconds, countDown: false)
            explanations.append("Автономность при текущей нагрузке, без внешнего питания.")
        } else {
            switch sample.runtime.state {
            case .estimating:
                runtimeItem.title = "Считаю…"
                if sample.runtime.source == .socHistory {
                    explanations.append("Нужны минимум 2 минуты наблюдений и снижение хотя бы на 1%.")
                }
            case .charging:
                if let seconds = sample.runtime.remainingSeconds {
                    runtimeItem.title = seconds == 0 ? "0 мин" : "≈ " + duration(seconds)
                } else {
                    runtimeItem.title = "Заряжается"
                }
                explanations.append("До полного заряда.")
            case .steady:
                runtimeItem.title = sample.runtime.source == .power ? "Нет нагрузки" : "Считаю…"
                explanations.append(sample.runtime.source == .power
                    ? "Без нагрузки время работы не оценивается." : "Заряд не меняется.")
            case .unavailable:
                runtimeItem.title = "Нет оценки"
            case .empty:
                runtimeItem.title = "0 мин"
            case .discharging:
                if let seconds = sample.runtime.remainingSeconds {
                    runtimeItem.title = seconds == 0 ? "0 мин" : "≈ " + duration(seconds)
                } else {
                    runtimeItem.title = "Нет оценки"
                }
                explanations.append("Оставшееся время работы.")
            }
        }
        if runtimeFrozenAt != nil || sample.runtimeCarriedForward {
            explanations.append("Последняя полученная оценка; отсчёт приостановлен.")
        }
        explanations.append("last read: " + shortDate(sample.runtimeMeasuredAt))
        runtimeItem.toolTip = explanations.joined(separator: "\n")
    }

    private func rebuildStationMenu() {
        guard !stationMenuIsOpen else { stationMenuNeedsRebuild = true; return }
        stationMenuNeedsRebuild = false
        stationMenu.removeAllItems()
        let automatic = NSMenuItem(title: "Авто", action: #selector(selectStation(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = ""
        automatic.state = identifier.isEmpty ? .on : .off
        stationMenu.addItem(automatic)
        for station in stationDirectory.stations {
            let item = NSMenuItem(title: station.displayName + " (" + station.model + ")",
                                 action: #selector(selectStation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = station.selector
            item.toolTip = station.bluetoothName
            item.state = identifier.caseInsensitiveCompare(station.selector) == .orderedSame
                || identifier.caseInsensitiveCompare(station.bluetoothName) == .orderedSame ? .on : .off
            stationMenu.addItem(item)
        }
        stationMenu.addItem(.separator())
        let title = pendingScan || isScanning ? "Поиск…" : (scanError == nil ? "Найти станции" : "Повторить поиск")
        let scan = NSMenuItem(title: title, action: #selector(requestStationScan), keyEquivalent: "")
        scan.target = self
        scan.toolTip = scanError
        scan.isEnabled = !demo && !pendingScan && !isScanning && !sleeping && !quitting
        stationMenu.addItem(scan)
        stationPopup.title = stationDisplayName
    }

    private func runQueuedWork(refreshAfterScan: Bool = false) {
        guard !sleeping, !quitting, job == nil else { return }
        if pendingScan { startStationScan() }
        else if pendingRefresh || refreshAfterScan { refresh() }
    }

    @objc private func requestStationScan() {
        guard !demo, !sleeping, !quitting, !pendingScan, !isScanning else { return }
        pendingScan = true
        scanError = nil
        rebuildStationMenu()
        runQueuedWork()
    }

    private func startStationScan() {
        guard !demo, !sleeping, !quitting, job == nil else { return }
        pendingScan = false
        isScanning = true
        let read = CLIJob()
        let thisGeneration = generation
        job = read
        rebuildStationMenu()
        render()
        read.run(executable: helperURL, arguments: ["scan", "--timeout", "12"]) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
                self.isScanning = false
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                if thisGeneration == self.generation, !self.sleeping {
                    let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
                    if result.error == nil, result.exitCode == 0,
                       let object = object, object["ok"] as? Bool == true,
                       object["devices"] is [[String: Any]] {
                        self.stationDirectory.ingestScan(object)
                        self.scanError = nil
                    } else {
                        let stderr = String(data: result.stderr, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.scanError = result.error ?? (object?["error"] as? String)
                            ?? (stderr?.isEmpty == false ? stderr : nil)
                            ?? "Не удалось найти станции."
                    }
                }
                self.rebuildStationMenu()
                self.render()
                self.runQueuedWork(refreshAfterScan: true)
            }
        }
    }

    @objc private func selectStation(_ sender: NSMenuItem) {
        guard !demo, !quitting, let value = sender.representedObject as? String, value != identifier else { return }
        // Save the previous station before changing the selector. Its values
        // never remain on-screen while the next station is connecting.
        freezeRuntime()
        saveReadingState()
        defaults.set(value, forKey: "stationIdentifier")
        generation += 1
        resetReadRetryBudget()
        awaitingFirstRead = true
        restoreSelectedReading()
        loadHistory.clear()
        pendingScan = false
        scanError = nil
        pendingRefresh = true
        lastError = "Waiting for a reading from the selected station."
        hasConnectionFailure = false
        writeFailure(lastError!)
        rebuildStationMenu()
        render()
        if let running = job { running.cancel() }
        else { runQueuedWork() }
    }

    @objc private func renameStation() {
        guard !quitting, let station = selectedKnownStation else { return }
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.quitting else { return }
            let alias = BlueBarAliasEditor.edit(alias: station.alias ?? "",
                                                placeholder: station.bluetoothName)
            guard !self.quitting, let alias = alias else { return }
            self.stationDirectory.setAlias(alias, deviceID: station.deviceID,
                                           bluetoothName: station.bluetoothName, model: station.model)
            self.rebuildStationMenu()
            self.render()
        }
    }

    @objc private func willSleep(_ notification: Notification) {
        sleeping = true
        generation += 1
        pendingRefresh = false
        pendingScan = false
        job?.cancel(reason: "Mac is sleeping.")
        fail("Mac is sleeping; Bluetooth reading paused.")
        rebuildStationMenu()
    }

    @objc private func didWake(_ notification: Notification) {
        sleeping = false
        generation += 1
        resetReadRetryBudget()
        pendingRefresh = true
        fail("Reconnecting after wake…")
        job?.cancel()
        rebuildStationMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        pollTimer?.invalidate()
        ageTimer?.invalidate()
        guard let running = job else { return .terminateNow }
        running.cancel(reason: "BluettiBar is quitting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.quitting, self.job != nil else { return }
            self.job?.forceStop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        job?.forceStop()
        freezeRuntime()
        saveReadingState()
        writeFailure("BluettiBar is not running.")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { return true }
}

@main
private struct BluettiBarApplication {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let code = BluettiInstallation.handle(arguments: arguments) { exit(code) }
        if arguments.first == "--bluetti-helper" {
            exit(BluettiNativeCommand.run(arguments: Array(arguments.dropFirst())))
        }
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "bluetti" {
            exit(BluettiNativeCommand.run(arguments: arguments))
        }
        if arguments.first == "--ui-self-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            exit(BlueBarDelegate.runUISelfTest())
        }
        // The installer captures a previous reading before asking the old app to quit.
        // This mode reads no Bluetooth device, opens no UI and writes no API status file.
        if CommandLine.arguments.contains("--preserve-legacy-reading") {
            // This executable already belongs to com.local.bluebar. Its own domain
            // must use standard preferences, never a suite with the same identifier.
            let migrationDefaults = UserDefaults.standard
            let migrationCacheURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/BlueBar/status.json")
            let migrationDirectory = BlueBarStationDirectory()
            let migrationStore = BlueBarReadingStore(defaults: migrationDefaults,
                                                     fallbackStatusURL: migrationCacheURL)
            let migrationSelector = migrationDefaults.string(forKey: "stationIdentifier") ?? ""
            _ = migrationStore.reading(for: migrationSelector,
                                       knownStations: migrationDirectory.stations)
            // UserDefaults persists changes automatically. An absent legacy sample is
            // normal, and synchronize() is not a reliable installation success gate.
            exit(0)
        }
        guard BluettiInstallation.claimUIInstance() else { exit(0) }
        let application = NSApplication.shared
        let delegate = BlueBarDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
