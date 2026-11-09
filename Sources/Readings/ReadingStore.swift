import Foundation
import CoreFoundation

/// Retained display data only. Nothing in this store is a fresh API success:
/// callers must keep the original timestamps and their connecting/stale state.
/// Use on the menu's main thread. Pass nil defaults for demo memory-only state.
final class BlueBarReadingStore {
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
