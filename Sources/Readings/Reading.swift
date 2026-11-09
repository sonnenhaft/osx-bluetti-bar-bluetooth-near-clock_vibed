import Foundation
import CoreFoundation

enum RuntimeState: String {
    case estimating, discharging, charging, steady, unavailable, empty
}

enum RuntimeSource: String {
    case station, power
    case socHistory = "soc_history"
}

struct RuntimeEstimate {
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

struct Reading {
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
    var outputWatts: Double? {
        guard outputPowerRetainedAt == nil, let ac = acOutput, let dc = dcOutput,
              (ac + dc).isFinite else { return nil }
        return ac + dc
    }

    var runtime: RuntimeEstimate
    var runtimeMeasuredAt: Date
    var runtimePercent: Int
    var runtimeCarriedForward: Bool
}
