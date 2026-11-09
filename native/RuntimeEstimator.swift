// Native, dependency-free counterpart of cli/src/runtime.rs.
// Public JSON and runtime-history.json remain compatible with existing BlueBar data.
import Foundation
import CoreFoundation

struct BluettiCommandError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

enum BluettiRuntimeState: String, Codable {
    case estimating, discharging, charging, steady, unavailable, empty
}

enum BluettiRuntimeSource: String, Codable {
    case station, power
    case socHistory = "soc_history"
}

struct BluettiRuntime: Codable, Equatable {
    var state: BluettiRuntimeState
    var source: BluettiRuntimeSource?
    var backup: Bool
    var remainingSeconds: UInt64?
    var windowSeconds: UInt64?
    var dropPercent: UInt16?

    init(state: BluettiRuntimeState, source: BluettiRuntimeSource? = nil, backup: Bool = false,
         remainingSeconds: UInt64? = nil, windowSeconds: UInt64? = nil, dropPercent: UInt16? = nil) {
        self.state = state; self.source = source; self.backup = backup
        self.remainingSeconds = remainingSeconds; self.windowSeconds = windowSeconds; self.dropPercent = dropPercent
    }

    static func empty(source: BluettiRuntimeSource? = nil) -> BluettiRuntime {
        return BluettiRuntime(state: .empty, source: source, remainingSeconds: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case state, source, backup
        case remainingSeconds = "remaining_seconds"
        case windowSeconds = "window_seconds"
        case dropPercent = "drop_percent"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(BluettiRuntimeState.self, forKey: .state)
        source = try values.decodeIfPresent(BluettiRuntimeSource.self, forKey: .source)
        backup = try values.decodeIfPresent(Bool.self, forKey: .backup) ?? false
        remainingSeconds = try values.decodeIfPresent(UInt64.self, forKey: .remainingSeconds)
        windowSeconds = try values.decodeIfPresent(UInt64.self, forKey: .windowSeconds)
        dropPercent = try values.decodeIfPresent(UInt16.self, forKey: .dropPercent)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(source, forKey: .source)
        if backup { try values.encode(true, forKey: .backup) }
        try values.encodeIfPresent(remainingSeconds, forKey: .remainingSeconds)
        try values.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try values.encodeIfPresent(dropPercent, forKey: .dropPercent)
    }

    func isValid(percent: UInt16) -> Bool {
        if let seconds = remainingSeconds, seconds > 604_800 { return false }
        if let window = windowSeconds, window > 900 { return false }
        if let drop = dropPercent, drop > 100 { return false }
        if state == .discharging && remainingSeconds == nil { return false }
        if state == .empty && (remainingSeconds != 0 || percent != 0) { return false }
        return true
    }
}

struct BluettiRuntimePower {
    var inputPresent: Bool? = nil
    var charging = false
    var idle = false
}

struct BluettiStatus: Codable {
    var ok = true
    var model = "AC50P"
    var device = ""
    var deviceID: String? = nil
    var batteryPercent: UInt16 = 0
    var observedAt: UInt64 = 0
    var refreshIntervalSeconds: UInt64? = nil
    var acInputW: UInt16? = nil
    var dcInputW: UInt16? = nil
    var acOutputW: UInt16? = nil
    var dcOutputW: UInt16? = nil
    var gridPresent: Bool? = nil
    var acOn: Bool? = nil
    var dcOn: Bool? = nil
    var runtime: BluettiRuntime? = nil
    // Private flags never enter the public status or cached JSON.
    var power = BluettiRuntimePower()

    private enum CodingKeys: String, CodingKey {
        case ok, model, device, runtime
        case deviceID = "device_id"
        case batteryPercent = "battery_percent"
        case observedAt = "observed_at"
        case refreshIntervalSeconds = "refresh_interval_seconds"
        case acInputW = "ac_input_w", dcInputW = "dc_input_w"
        case acOutputW = "ac_output_w", dcOutputW = "dc_output_w"
        case gridPresent = "grid_present", acOn = "ac_on", dcOn = "dc_on"
    }

    init(at: UInt64, percent: UInt16, device: String = "AC50P123", deviceID: String? = "id1") {
        observedAt = at; batteryPercent = percent; self.device = device; self.deviceID = deviceID
    }

    static func fromNative(_ snapshot: [String: Any]) throws -> BluettiStatus {
        var object = snapshot
        // Unusable native ETA must permit the power/history fallback, just as
        // an absent/idle-sentinel runtime did in the original snapshot decoder.
        let rawRuntime = object.removeValue(forKey: "runtime")
        let encoded: Data
        do { encoded = try JSONSerialization.data(withJSONObject: object) }
        catch { throw BluettiCommandError("invalid_data", "The station returned invalid battery data.") }
        var status: BluettiStatus
        do { status = try JSONDecoder().decode(BluettiStatus.self, from: encoded) }
        catch { throw BluettiCommandError("invalid_data", "The station did not return a valid battery percentage or station identity.") }
        guard status.ok, status.model == "AC50P", !status.device.isEmpty, status.batteryPercent <= 100 else {
            throw BluettiCommandError("invalid_data", "The station did not return a valid battery percentage.")
        }
        if let raw = rawRuntime, JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           var runtime = try? JSONDecoder().decode(BluettiRuntime.self, from: data),
           runtime.isValid(percent: status.batteryPercent) {
            if runtime.state == .discharging {
                runtime.backup = status.gridPresent == true || (status.acInputW ?? 0) > 0 || (status.dcInputW ?? 0) > 0
            }
            status.runtime = runtime
        }
        if let values = snapshot["_bluebar_power"] as? [String: Any],
           let input = values["input_present"] as? NSNumber, CFGetTypeID(input) == CFBooleanGetTypeID() {
            status.power.inputPresent = input.boolValue
        }
        if let acIn = status.acInputW, let dcIn = status.dcInputW,
           let acOut = status.acOutputW, let dcOut = status.dcOutputW {
            status.power.charging = UInt32(acIn) + UInt32(dcIn) >= UInt32(acOut) + UInt32(dcOut) + 20
        }
        status.power.idle = status.acOutputW == 0 && status.dcOutputW == 0
        return status
    }
}

// Shared by the real CoreBluetooth adapter and offline self-tests. Exact IDs
// precede exact names, then partial names; selection is never arbitrary.
func bluettiChooseDevice(_ devices: [BluettiNativeDevice], selector: String?) throws -> BluettiNativeDevice {
    let eligible = devices.filter { ($0.json["model"] as? String) == "AC50P" }
    let matches: [BluettiNativeDevice]
    if let value = selector {
        let ids = eligible.filter { $0.id.caseInsensitiveCompare(value) == .orderedSame }
        if !ids.isEmpty { matches = ids }
        else {
            let names = eligible.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
            matches = names.isEmpty ? eligible.filter { $0.name.lowercased().contains(value.lowercased()) } : names
        }
    } else { matches = eligible }
    guard !matches.isEmpty else {
        throw BluettiNativeFailure.failed(code: "not_found", message: "No matching AC50P found. Enable Bluetooth on the station, stay nearby, and fully close the BLUETTI phone app.")
    }
    guard matches.count == 1 else {
        throw BluettiNativeFailure.failed(code: "ambiguous", message: "Multiple AC50P stations match: \(matches.map { $0.name }.joined(separator: ", ")). Run bluetti scan and pass --device with one full name or ID.")
    }
    let chosen = matches[0]
    // Preserve the previous conservative duplicate-name rule even though the
    // native transport now connects to the selected peripheral's exact UUID.
    guard eligible.filter({ $0.name.contains(chosen.name) }).count == 1 else {
        throw BluettiNativeFailure.failed(code: "ambiguous", message: "Nearby stations have indistinguishable Bluetooth names. Keep only the intended station in range.")
    }
    return chosen
}

struct BluettiRuntimeSample: Codable {
    var at: UInt64
    var percent: UInt16
}

struct BluettiObservedEstimate: Codable {
    var at: UInt64
    var remainingSeconds: UInt64
    var windowSeconds: UInt64
    var dropPercent: UInt16
    private enum CodingKeys: String, CodingKey {
        case at
        case remainingSeconds = "remaining_seconds", windowSeconds = "window_seconds", dropPercent = "drop_percent"
    }

    func runtime(at now: UInt64) -> BluettiRuntime? {
        guard now >= at, dropPercent > 0 else { return nil }
        let age = now - at
        let grace = min(900, max(120, 2 * windowSeconds / UInt64(dropPercent)))
        let remaining = remainingSeconds > age ? remainingSeconds - age : 0
        guard age <= grace, remaining > 0 else { return nil }
        return BluettiRuntime(state: .discharging, source: .socHistory, remainingSeconds: remaining,
                              windowSeconds: windowSeconds, dropPercent: dropPercent)
    }
}

struct BluettiRuntimeHistory: Codable {
    var version: UInt8
    var device: String
    var deviceID: String?
    var inputPresent: Bool?
    var chargingSeen: Bool
    var samples: [BluettiRuntimeSample]
    var estimate: BluettiObservedEstimate?
    private enum CodingKeys: String, CodingKey {
        case version, device, samples, estimate
        case deviceID = "device_id", inputPresent = "input_present", chargingSeen = "charging_seen"
    }

    static func start(_ status: BluettiStatus, charging: Bool) -> BluettiRuntimeHistory {
        return BluettiRuntimeHistory(version: 1, device: status.device, deviceID: status.deviceID,
            inputPresent: status.power.inputPresent, chargingSeen: charging,
            samples: [BluettiRuntimeSample(at: status.observedAt, percent: status.batteryPercent)], estimate: nil)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(device, forKey: .device)
        // The old history schema wrote explicit nulls for these optional fields.
        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(inputPresent, forKey: .inputPresent)
        try values.encode(chargingSeen, forKey: .chargingSeen)
        try values.encode(samples, forKey: .samples)
        try values.encode(estimate, forKey: .estimate)
    }

    func usable(for status: BluettiStatus) -> Bool {
        guard version == 1, device == status.device, deviceID == status.deviceID,
              !samples.isEmpty, samples.count <= 901 else { return false }
        if samples.contains(where: { $0.percent > 100 }) { return false }
        for pair in zip(samples, samples.dropFirst()) {
            if pair.0.at >= pair.1.at || pair.0.percent < pair.1.percent { return false }
        }
        guard let last = samples.last else { return false }
        if let estimate = estimate {
            guard estimate.dropPercent > 0, estimate.dropPercent <= 100,
                  (120...900).contains(estimate.windowSeconds), estimate.remainingSeconds <= 90_000,
                  estimate.at <= last.at else { return false }
        }
        return status.observedAt > last.at && status.observedAt - last.at <= 300
    }
}

enum BluettiRuntimeEstimator {
    static let historyFilename = "runtime-history.json"
    static let windowSeconds: UInt64 = 900

    static func fromStation(hours: Double, charging: Bool, percent: UInt16) -> BluettiRuntime? {
        let zeroValid = charging ? percent == 100 : percent == 0
        guard hours.isFinite, (0.0...99.8).contains(hours), hours != 0 || zeroValid else { return nil }
        if !charging && percent == 0 { return .empty(source: .station) }
        return BluettiRuntime(state: charging ? .charging : .discharging, source: .station,
                              remainingSeconds: UInt64((hours * 3600).rounded()))
    }

    static func fromPower(_ status: BluettiStatus) -> BluettiRuntime? {
        guard let ac = status.acOutputW ?? (status.acOn == false ? UInt16(0) : nil),
              let dc = status.dcOutputW ?? (status.dcOn == false ? UInt16(0) : nil) else { return nil }
        let load = UInt32(ac) + UInt32(dc)
        if load == 0 {
            let state: BluettiRuntimeState = status.power.charging ? .charging : (status.batteryPercent == 0 ? .empty : .steady)
            return state == .empty ? .empty(source: .power) : BluettiRuntime(state: state, source: .power)
        }
        if status.batteryPercent == 0 { return .empty(source: .power) }
        // Official AC50P formula: 504 Wh * 90% DoD * 85% efficiency; 10 W overhead.
        let hours = 504.0 * 0.90 * 0.85 * (Double(status.batteryPercent) / 100.0) / (Double(load) + 10.0)
        let onBattery = status.gridPresent == false && status.acInputW == 0 && status.dcInputW == 0
        return BluettiRuntime(state: .discharging, source: .power, backup: !onBattery,
                              remainingSeconds: UInt64((hours * 3600).rounded()))
    }

    private static func baseline(_ status: BluettiStatus, state: BluettiRuntimeState) -> (BluettiRuntimeHistory, BluettiRuntime) {
        return (.start(status, charging: state == .charging), state == .empty ? .empty() : BluettiRuntime(state: state))
    }

    static func estimate(previous: BluettiRuntimeHistory?, status: BluettiStatus) -> (BluettiRuntimeHistory, BluettiRuntime) {
        let previous = previous.flatMap { $0.usable(for: status) ? $0 : nil }
        if status.power.charging || status.runtime?.state == .charging { return baseline(status, state: .charging) }
        if status.batteryPercent == 0 { return baseline(status, state: .empty) }
        guard var history = previous, let last = history.samples.last else { return baseline(status, state: .estimating) }
        let lastPercent = last.percent
        if status.batteryPercent > lastPercent { return baseline(status, state: .charging) }
        let powerChanged: Bool
        if let before = history.inputPresent, let now = status.power.inputPresent { powerChanged = before != now }
        else { powerChanged = false }
        if powerChanged || history.chargingSeen { return baseline(status, state: .estimating) }
        if status.power.idle || (status.batteryPercent == 100 && lastPercent == 100) { return baseline(status, state: .steady) }
        let now = status.observedAt
        history.samples.removeAll { now >= $0.at && now - $0.at > windowSeconds }
        history.samples.append(BluettiRuntimeSample(at: now, percent: status.batteryPercent))
        history.inputPresent = status.power.inputPresent
        guard let anchor = history.samples.first else { return baseline(status, state: .estimating) }
        let window = now - anchor.at
        let drop = anchor.percent - status.batteryPercent
        if status.batteryPercent < lastPercent && window >= 120 && drop > 0 {
            history.estimate = BluettiObservedEstimate(at: now,
                remainingSeconds: UInt64(status.batteryPercent) * window / UInt64(drop),
                windowSeconds: window, dropPercent: drop)
        }
        if let runtime = history.estimate?.runtime(at: now) { return (history, runtime) }
        history.estimate = nil
        return (history, BluettiRuntime(state: window < 120 || status.batteryPercent < lastPercent ? .estimating : .steady))
    }

    static func persist(directory: URL, status: BluettiStatus) throws -> BluettiRuntime {
        let path = directory.appendingPathComponent(historyFilename)
        let previous: BluettiRuntimeHistory?
        do {
            let data = try Data(contentsOf: path)
            // Malformed/obsolete history is a missing baseline, never a made-up ETA.
            previous = try? JSONDecoder().decode(BluettiRuntimeHistory.self, from: data)
        } catch {
            let problem = error as NSError
            if problem.domain == NSCocoaErrorDomain && problem.code == NSFileReadNoSuchFileError {
                previous = nil
            } else if problem.domain == NSPOSIXErrorDomain && problem.code == 2 {
                previous = nil
            } else { throw error }
        }
        let (history, runtime) = estimate(previous: previous, status: status)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(history)
        data.append(0x0a)
        try BluettiFiles.atomicWrite(data, to: path)
        return runtime
    }

    static func attach(to status: inout BluettiStatus, directory: URL?) {
        // History is still collected when native/power ETA exists, but an I/O
        // failure can never replace an immediate station or power estimate.
        let immediate = status.runtime ?? fromPower(status)
        var historical: BluettiRuntime?
        if let directory = directory, var value = try? persist(directory: directory, status: status) {
            value.source = .socHistory
            historical = value
        }
        status.runtime = immediate ?? historical ?? BluettiRuntime(state: .unavailable)
    }
}
