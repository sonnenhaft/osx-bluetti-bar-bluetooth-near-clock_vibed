import Foundation

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
