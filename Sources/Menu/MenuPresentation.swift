import Foundation

struct MenuRow: Equatable {
    let title: String
    let toolTip: String?
}

enum MenuPresentation {
    static func lastRead(_ date: Date, now: Date) -> (title: String, nextUpdate: Date) {
        let age = max(0, now.timeIntervalSince(date))
        if age < 5 {
            return ("Last read just now", date.addingTimeInterval(5))
        }
        let unit: (seconds: Int, name: String)
        switch age {
        case ..<60: unit = (1, "second")
        case ..<3600: unit = (60, "minute")
        case ..<86400: unit = (3600, "hour")
        default: unit = (86400, "day")
        }
        let count = Int(age) / unit.seconds
        let label = count == 1 ? unit.name : unit.name + "s"
        let next = date.addingTimeInterval(Double((count + 1) * unit.seconds))
        return ("Last read \(count) \(label) ago", next)
    }

    static func power(for reading: Reading?, shortDate: (Date) -> String) -> MenuRow {
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
        var powerDetails: [String] = []
        if let date = reading?.inputPowerRetainedAt { powerDetails.append("in · last read: " + shortDate(date)) }
        if let date = reading?.outputPowerRetainedAt { powerDetails.append("out · last read: " + shortDate(date)) }
        return MenuRow(title: powers.joined(separator: " · "),
                       toolTip: powerDetails.isEmpty ? nil : powerDetails.joined(separator: "\n"))
    }

    static func runtime(for reading: Reading?, now: Date, maximumAge: TimeInterval,
                        frozenAt: Date?, loading: Bool, error: String?,
                        shortDate: (Date) -> String) -> MenuRow {
        guard let sample = reading else {
            return MenuRow(title: loading ? "Reading…" : "", toolTip: error)
        }
        let title: String
        var explanations: [String] = []
        switch sample.runtime.source {
        case .station?:
            explanations.append("Estimate reported by BLUETTI.")
        case .power?:
            explanations.append("Estimated from power usage.")
        case .socHistory?:
            explanations.append("Estimated from battery level changes.")
            if let window = sample.runtime.windowSeconds, window >= 120,
               let drop = sample.runtime.dropPercent, drop > 0 {
                explanations.append("Battery fell \(drop)% in \(window / 60) min.")
            }
        case nil:
            break
        }
        func duration(_ seconds: Int, countDown: Bool = true) -> String {
            // Keep the last received estimate. Its clock stops on a failed
            // poll, sleep, stale data, or an observation without a new ETA.
            let asOf = frozenAt
                ?? min(now, sample.runtimeMeasuredAt.addingTimeInterval(maximumAge))
            let elapsed = countDown ? max(0, asOf.timeIntervalSince(sample.runtimeMeasuredAt)) : 0
            let minutes = Int(ceil(max(0, Double(seconds) - elapsed) / 60))
            let hours = minutes / 60
            let rest = minutes % 60
            return hours == 0 ? "\(minutes) min"
                : (rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min")
        }
        if sample.runtime.backup,
           sample.runtime.state == .discharging || sample.runtime.state == .empty,
           let seconds = sample.runtime.remainingSeconds {
            // This describes unplugged autonomy, not an active countdown while
            // the load is powered externally. The next fresh sample updates it.
            title = seconds == 0 ? "0 min" : "≈ " + duration(seconds, countDown: false)
            explanations.append("Estimated runtime at the current load without external power.")
        } else {
            switch sample.runtime.state {
            case .estimating:
                title = "Estimating…"
                if sample.runtime.source == .socHistory {
                    explanations.append("Waiting for at least two minutes of readings and a 1% drop.")
                }
            case .charging:
                if let seconds = sample.runtime.remainingSeconds {
                    title = seconds == 0 ? "0 min" : "≈ " + duration(seconds)
                } else {
                    title = "Charging"
                }
                explanations.append("Time until fully charged.")
            case .steady:
                title = sample.runtime.source == .power ? "No load" : "Estimating…"
                explanations.append(sample.runtime.source == .power
                    ? "A load is required to estimate runtime." : "Battery level is steady.")
            case .unavailable:
                title = "Estimate unavailable"
            case .empty:
                title = "0 min"
            case .discharging:
                if let seconds = sample.runtime.remainingSeconds {
                    title = seconds == 0 ? "0 min" : "≈ " + duration(seconds)
                } else {
                    title = "Estimate unavailable"
                }
                explanations.append("Estimated runtime remaining.")
            }
        }
        if frozenAt != nil || sample.runtimeCarriedForward {
            explanations.append("Last known estimate. Countdown paused.")
        }
        explanations.append("last read: " + shortDate(sample.runtimeMeasuredAt))
        return MenuRow(title: title, toolTip: explanations.joined(separator: "\n"))
    }
}
