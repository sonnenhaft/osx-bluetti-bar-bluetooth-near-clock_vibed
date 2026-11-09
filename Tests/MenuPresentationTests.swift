import Foundation

enum MenuPresentationTests {
    static func lastReadAge() throws {
        let date = Date(timeIntervalSince1970: 100)
        for (elapsed, label, next) in [(-2, "just now", 5), (4, "just now", 5),
                                        (5, "5 seconds ago", 6), (59, "59 seconds ago", 60),
                                        (60, "1 minute ago", 120), (121, "2 minutes ago", 180),
                                        (3600, "1 hour ago", 7200), (86400, "1 day ago", 172800)] {
            let age = MenuPresentation.lastRead(date, now: date.addingTimeInterval(Double(elapsed)))
            guard age.title == "Last read " + label,
                  age.nextUpdate == date.addingTimeInterval(Double(next)) else {
                throw BluettiCommandError("self_test", "Unexpected last-read age at \(elapsed) seconds.")
            }
        }
    }

    static func readingToMenu() throws {
        let time = Date(timeIntervalSince1970: 10_000)
        var sample: [String: Any] = [
            "ok": true, "model": "AC50P", "device": "station A", "observed_at": 10_000,
            "battery_percent": 73, "ac_input_w": 370, "ac_output_w": 120, "dc_output_w": 15,
            "runtime": ["state": "discharging", "source": "station", "remaining_seconds": 3600] as [String: Any]
        ]
        let first = try Reading.decode(sample, previous: nil, now: time, maximumAge: 90)
        var visibility = StatusVisibility(showOutput: true, showPercentage: true)
        let power = MenuPresentation.power(for: first, shortDate: { _ in "10:00" })
        let runtime = MenuPresentation.runtime(for: first, now: time.addingTimeInterval(60),
                                               maximumAge: 90, frozenAt: nil, loading: false,
                                               error: nil, shortDate: { _ in "10:00" })
        guard visibility.title(for: first) == "73% 135 W", runtime.title == "≈ 59 min",
              power.title == "in AC: 370w · out DC|AC: 15w|120w" else {
            throw BluettiCommandError("self_test", "Fresh reading mapped to incorrect menu text.")
        }
        visibility.togglePercentage(for: first)
        sample.removeValue(forKey: "dc_output_w")
        sample.removeValue(forKey: "runtime")
        let partial = try Reading.decode(sample, previous: first, now: time, maximumAge: 90)
        guard visibility.title(for: first) == "135 W", visibility.title(for: partial) == "73%",
              partial.dcOutput == 15, partial.runtimeCarriedForward else {
            throw BluettiCommandError("self_test", "Partial reading lost retained data or hid the percentage.")
        }
        visibility.toggleOutput()
        guard visibility.title(for: first) == "73%" else {
            throw BluettiCommandError("self_test", "Hiding output must restore the percentage.")
        }
        sample["device"] = "station B"
        let next = try Reading.decode(sample, previous: first, now: time, maximumAge: 90)
        guard next.dcOutput == nil, !next.runtimeCarriedForward else {
            throw BluettiCommandError("self_test", "Readings leaked between stations.")
        }
    }
}
