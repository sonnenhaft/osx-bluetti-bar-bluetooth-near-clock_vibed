import Foundation
import CoreFoundation

private struct InvalidReading: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension Reading {
    func matchesStation(id: String?, name: String) -> Bool {
        switch (deviceID, id) {
        case let (old?, new?): return old.caseInsensitiveCompare(new) == .orderedSame
        case (nil, nil): return device == name
        default: return false
        }
    }

    static func decode(_ snapshot: [String: Any], previous: Reading?, now: Date,
                       maximumAge: TimeInterval?) throws -> Reading {
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
            throw InvalidReading("Reader returned an invalid battery percentage, station identity or timestamp.")
        }
        let measuredAt = Date(timeIntervalSince1970: timestamp.doubleValue)
        let age = now.timeIntervalSince(measuredAt)
        guard age >= -30, maximumAge.map({ age <= $0 }) ?? true else {
            throw InvalidReading("Reader returned an old or invalid timestamp; waiting for a fresh sample.")
        }
        func watts(_ key: String) -> Double? {
            guard let value = snapshot[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        let deviceID = (snapshot["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let previous = previous.flatMap { $0.matchesStation(id: deviceID, name: device) ? $0 : nil }
        let acInput = watts("ac_input_w"), dcInput = watts("dc_input_w")
        let acOutput = watts("ac_output_w"), dcOutput = watts("dc_output_w")
        let inputRetained = (acInput == nil && previous?.acInput != nil)
            || (dcInput == nil && previous?.dcInput != nil)
        let outputRetained = (acOutput == nil && previous?.acOutput != nil)
            || (dcOutput == nil && previous?.dcOutput != nil)
        let parsedRuntime = RuntimeEstimate.parse(snapshot["runtime"], percent: number.intValue)
        // No new numeric ETA: retain its original meaning and observation time.
        // A valid zero is a new value and must replace an earlier estimate.
        let retainedRuntime = parsedRuntime?.remainingSeconds == nil
            && previous?.runtime.remainingSeconds != nil ? previous : nil
        return Reading(percent: number.intValue,
                           device: device, deviceID: deviceID,
                           measuredAt: measuredAt,
                           acInput: acInput ?? previous?.acInput, dcInput: dcInput ?? previous?.dcInput,
                           acOutput: acOutput ?? previous?.acOutput, dcOutput: dcOutput ?? previous?.dcOutput,
                           inputPowerRetainedAt: inputRetained ? (previous?.inputPowerRetainedAt ?? previous?.measuredAt) : nil,
                           outputPowerRetainedAt: outputRetained ? (previous?.outputPowerRetainedAt ?? previous?.measuredAt) : nil,
                           runtime: retainedRuntime?.runtime ?? parsedRuntime ?? .unavailable,
                           runtimeMeasuredAt: retainedRuntime?.runtimeMeasuredAt ?? measuredAt,
                           runtimePercent: retainedRuntime?.runtimePercent ?? number.intValue,
                           runtimeCarriedForward: retainedRuntime != nil)
    }
}
