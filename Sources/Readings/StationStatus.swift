import Foundation
import CoreFoundation

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
