// Embedded, offline regressions. No BLE objects, fixture downloads, HOME changes,
// or writes to the user's live cache. Temporary directories clean themselves up.
import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class BluettiTestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("bluettibar-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

enum BluettiNativeSelfTests {
    // Private child-process entry. It never creates files, touches the real
    // cache, initializes Bluetooth, or accepts arbitrary filesystem paths.
    static func probeExistingTestLock(path: String) throws -> Int32 {
        guard (path as NSString).isAbsolutePath else {
            throw BluettiCommandError("self_test", "The lock-test path must be absolute.")
        }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let directory = file.deletingLastPathComponent()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = "bluettibar-selftest-"
        guard path == file.path, file.lastPathComponent == "bluetooth.lock",
              directory.deletingLastPathComponent().path == base.path,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw BluettiCommandError("self_test", "The lock-test path is outside its isolated temporary directory.")
        }
        let descriptor = file.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw BluettiCommandError("self_test", "Cannot open the existing test lock.") }
        defer { _ = close(descriptor) }
        let blocked = BluettiBluetoothLock.tryExclusive(descriptor) != 0
        let reason = errno
        guard blocked && (reason == EWOULDBLOCK || reason == EAGAIN) else {
            throw BluettiCommandError("self_test", "The child process did not observe an exclusive Bluetooth lock.")
        }
        return 0
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw BluettiCommandError("self_test", message) }
    }

    private static func errorCode(_ error: Error) -> String {
        if let problem = error as? BluettiCommandError { return problem.code }
        if let failure = error as? BluettiNativeFailure {
            switch failure { case let .failed(code, _): return code }
        }
        return "unknown"
    }

    private static func expectError(_ expected: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { try require(errorCode(error) == expected, "Expected \(expected), got \(errorCode(error))."); return }
        throw BluettiCommandError("self_test", "Expected \(expected), but the operation succeeded.")
    }

    private static func sample(_ at: UInt64, _ percent: UInt16) -> BluettiStatus {
        return BluettiStatus(at: at, percent: percent)
    }

    private static func device(_ name: String, _ id: String) -> BluettiNativeDevice {
        return BluettiNativeDevice(id: id, name: name, json: ["name": name, "id": id, "model": "AC50P"])
    }

    private static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw BluettiCommandError("self_test", "Expected an encoded JSON object.")
        }
        return object
    }

    private static func runtimeJSON(_ status: BluettiStatus) throws -> [String: Any] {
        let value = try json(status)
        try require(value["power"] == nil && value["_bluebar_power"] == nil, "Internal power flags escaped into public JSON.")
        guard let runtime = value["runtime"] as? [String: Any] else {
            throw BluettiCommandError("self_test", "Missing public runtime.")
        }
        return runtime
    }

    private static func runtimeEquals(_ status: BluettiStatus, _ expected: [String: Any]) throws {
        let actual = try runtimeJSON(status)
        let actualJSON = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys])
        let expectedJSON = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        try require(actualJSON == expectedJSON, "Public runtime does not match the expected fields: \(actual)")
    }

    private static func snapshot(_ percent: UInt16, _ native: BluettiRuntime? = nil) throws -> [String: Any] {
        var result: [String: Any] = [
            "ok": true, "model": "AC50P", "device": "AC50P-regression", "device_id": "regression-id",
            "battery_percent": percent, "observed_at": UInt64(1000),
            "dc_output_w": 60, "ac_output_w": 0, "dc_input_w": 0, "ac_input_w": 0,
            "grid_present": false, "ac_on": false, "dc_on": true,
            "_bluebar_power": ["input_present": false, "charging": false, "idle": false]
        ]
        if let native = native { result["runtime"] = try json(native) }
        return result
    }

    private static func unknownPower(_ value: [String: Any]) -> [String: Any] {
        var result = value
        for key in ["ac_input_w", "dc_input_w", "ac_output_w", "dc_output_w", "ac_on", "dc_on", "_bluebar_power"] {
            result.removeValue(forKey: key)
        }
        return result
    }

    private static func attached(_ raw: [String: Any], at: UInt64, directory: URL?) throws -> BluettiStatus {
        var raw = raw
        raw["observed_at"] = at
        var status = try BluettiStatus.fromNative(raw)
        BluettiRuntimeEstimator.attach(to: &status, directory: directory)
        return status
    }

    static func run() throws -> Int {
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            do { try body(); count += 1 }
            catch {
                let detail = (error as? BluettiCommandError)?.message ?? error.localizedDescription
                throw BluettiCommandError("self_test", "\(name): \(detail)")
            }
        }

        try test("last_read_age", MenuPresentationTests.lastReadAge)
        try test("reading_to_menu", MenuPresentationTests.readingToMenu)

        // The original seven command/cache/selection test groups.
        try test("selection_never_chooses_arbitrarily") {
            let choices = [device("AC50P123", "a"), device("AC50P456", "b")]
            try expectError("ambiguous") { _ = try bluettiChooseDevice(choices, selector: nil) }
            let partial = try bluettiChooseDevice(choices, selector: "456")
            let exactID = try bluettiChooseDevice(choices, selector: "A")
            try require(partial.id == "b" && exactID.name == "AC50P123", "ID/name selection changed.")
        }
        try test("matching_ids_do_not_bypass_duplicate_name_guard") {
            let choices = [device("AC50P123", "a"), device("AC50P123", "b")]
            try expectError("ambiguous") { _ = try bluettiChooseDevice(choices, selector: "a") }
        }
        try test("stale_or_future_cache_is_not_a_live_percentage") {
            try BluettiFiles.validateStatus(sample(910, 42), now: 1000)
            try expectError("stale") { try BluettiFiles.validateStatus(sample(909, 42), now: 1000) }
            try expectError("invalid_data") { try BluettiFiles.validateStatus(sample(1006, 42), now: 1000) }
        }
        try test("cache_lifetime_tracks_only_supported_polling_intervals") {
            var status = sample(890, 42)
            try expectError("stale") { try BluettiFiles.validateStatus(status, now: 1000) }
            status.refreshIntervalSeconds = 120
            try BluettiFiles.validateStatus(status, now: 1000)
            for (interval, limit) in [(UInt64(5), UInt64(90)), (20, 90), (30, 90), (60, 95), (120, 155)] {
                status.refreshIntervalSeconds = interval
                status.observedAt = 1000 - limit
                try BluettiFiles.validateStatus(status, now: 1000)
                try expectError("stale") { try BluettiFiles.validateStatus(status, now: 1001) }
            }
        }
        try test("invalid_polling_interval_cannot_extend_cache_lifetime") {
            var status = sample(890, 42)
            for interval in [UInt64(0), 15, 600, UInt64.max] {
                status.refreshIntervalSeconds = interval
                try expectError("invalid_data") { try BluettiFiles.validateStatus(status, now: 1000) }
            }
        }
        try test("malformed_status_is_rejected") {
            var status = sample(1000, 101)
            try expectError("invalid_data") { try BluettiFiles.validateStatus(status, now: 1000) }
            status.batteryPercent = 0; status.ok = false
            try expectError("invalid_data") { try BluettiFiles.validateStatus(status, now: 1000) }
        }
        try test("flags_are_validated_without_bluetooth") {
            try require(try BluettiOptions.parse(["--help"]).command == .help, "Help parsing changed.")
            for arguments in [["status", "--timeout", "0"], ["status", "--device", ""], ["cached", "--timeout", "25"]] {
                try expectError("arguments") { _ = try BluettiOptions.parse(arguments) }
            }
        }

        // The original nine SOC/history regression groups.
        try test("persists_between_processes_and_uses_observed_drop") {
            let (history, first) = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 80))
            try require(first.state == .estimating, "First sample invented an ETA.")
            let restored = try JSONDecoder().decode(BluettiRuntimeHistory.self, from: JSONEncoder().encode(history))
            let (_, second) = BluettiRuntimeEstimator.estimate(previous: restored, status: sample(1120, 78))
            try require(second.remainingSeconds == 4680 && second.windowSeconds == 120 && second.dropPercent == 2, "Observed SOC slope changed.")
        }
        try test("equal_integer_samples_keep_anchor_without_dividing_by_zero") {
            let (first, _) = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 80))
            let (history, same) = BluettiRuntimeEstimator.estimate(previous: first, status: sample(1060, 80))
            try require(same.state == .estimating && history.samples.first?.at == 1000, "Equal SOC lost its baseline.")
            let (_, eta) = BluettiRuntimeEstimator.estimate(previous: history, status: sample(1120, 79))
            try require(eta.remainingSeconds == 9480, "One-percent slope changed.")
        }
        try test("short_drop_does_not_invent_an_accurate_rate") {
            let (first, _) = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 80))
            let (earlyHistory, early) = BluettiRuntimeEstimator.estimate(previous: first, status: sample(1030, 79))
            try require(early.state == .estimating, "Thirty seconds was treated as a sufficient window.")
            let (history, plateau) = BluettiRuntimeEstimator.estimate(previous: earlyHistory, status: sample(1120, 79))
            try require(plateau.remainingSeconds == nil, "An old short drop fabricated a rate.")
            let (_, eta) = BluettiRuntimeEstimator.estimate(previous: history, status: sample(1150, 78))
            try require(eta.remainingSeconds == 5850, "The second observed drop was not used.")
        }
        try test("unchanged_percentage_counts_down_then_expires") {
            let (first, _) = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 80))
            let (drop, _) = BluettiRuntimeEstimator.estimate(previous: first, status: sample(1240, 79))
            let (heldHistory, held) = BluettiRuntimeEstimator.estimate(previous: drop, status: sample(1480, 79))
            try require(held.remainingSeconds == 79 * 240 - 240, "A plateau inflated the countdown.")
            let (history, _) = BluettiRuntimeEstimator.estimate(previous: heldHistory, status: sample(1720, 79))
            let (_, expired) = BluettiRuntimeEstimator.estimate(previous: history, status: sample(1721, 79))
            try require(expired.state == .steady && expired.remainingSeconds == nil, "A stale slope survived its grace period.")
        }
        try test("charge_device_time_and_sleep_reset_the_baseline") {
            let (first, _) = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 80))
            let (history, _) = BluettiRuntimeEstimator.estimate(previous: first, status: sample(1240, 79))
            try require(BluettiRuntimeEstimator.estimate(previous: history, status: sample(1300, 80)).1.state == .charging, "Rising SOC did not reset to charging.")
            for at in [UInt64(1200), 1240, 1541] {
                try require(BluettiRuntimeEstimator.estimate(previous: history, status: sample(at, 78)).1.state == .estimating, "Clock/sleep gap reused an invalid slope.")
            }
            var other = sample(1300, 78); other.deviceID = "id2"
            try require(BluettiRuntimeEstimator.estimate(previous: history, status: other).1.state == .estimating, "Another station inherited an ETA.")
            var charging = sample(1300, 79); charging.power.charging = true
            let (charged, value) = BluettiRuntimeEstimator.estimate(previous: history, status: charging)
            try require(value.state == .charging, "Known charging was ignored.")
            try require(BluettiRuntimeEstimator.estimate(previous: charged, status: sample(1330, 78)).1.state == .estimating, "Charging history seeded a discharge slope.")
        }
        try test("zero_empty_and_known_power_transition_are_explicit") {
            try require(BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 0)).1.remainingSeconds == 0, "Empty battery lost its valid zero.")
            var powered = sample(1000, 80); powered.power.inputPresent = true
            let (history, _) = BluettiRuntimeEstimator.estimate(previous: nil, status: powered)
            var battery = sample(1240, 79); battery.power.inputPresent = false
            try require(BluettiRuntimeEstimator.estimate(previous: history, status: battery).1.state == .estimating, "An input transition retained the prior slope.")
        }
        try test("long_full_plateau_does_not_inflate_first_discharge") {
            var history = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 100)).0
            for at in stride(from: 1030, through: 2800, by: 30) {
                history = BluettiRuntimeEstimator.estimate(previous: history, status: sample(UInt64(at), 100)).0
            }
            let (_, value) = BluettiRuntimeEstimator.estimate(previous: history, status: sample(2830, 99))
            try require(value.state == .estimating && value.remainingSeconds == nil, "Full-on-mains plateau inflated first discharge.")
        }
        try test("history_window_is_bounded") {
            var history = BluettiRuntimeEstimator.estimate(previous: nil, status: sample(1000, 90)).0
            for at in stride(from: 1030, through: 2800, by: 30) {
                history = BluettiRuntimeEstimator.estimate(previous: history, status: sample(UInt64(at), 90)).0
            }
            let (bounded, value) = BluettiRuntimeEstimator.estimate(previous: history, status: sample(2830, 89))
            try require(bounded.samples.allSatisfy { $0.at >= 1930 }, "History escaped its fifteen-minute window.")
            try require(value.windowSeconds == 900 && value.remainingSeconds == 89 * 900, "Bounded-window calculation changed.")
        }
        try test("writes_history_atomically_without_touching_error_cache") {
            let directory = try BluettiTestDirectory()
            let cache = Data("{\"ok\":false,\"error\":\"BlueBar is not running\"}".utf8)
            try cache.write(to: directory.url.appendingPathComponent("status.json"))
            let first = try BluettiRuntimeEstimator.persist(directory: directory.url, status: sample(1000, 80))
            let next = try BluettiRuntimeEstimator.persist(directory: directory.url, status: sample(1240, 78))
            let after = try Data(contentsOf: directory.url.appendingPathComponent("status.json"))
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            try require(first.state == .estimating && next.remainingSeconds == 9360, "Cross-invocation history did not produce the observed rate.")
            try require(after == cache && files.count == 2, "History write altered the API cache or leaked a temporary file.")
        }

        // The original eight native -> fallback -> public JSON integration groups.
        try test("native_discharge_survives_snapshot_attachment_and_public_json") {
            let directory = try BluettiTestDirectory()
            let native = BluettiRuntimeEstimator.fromStation(hours: 1.3, charging: false, percent: 78)
            let status = try attached(snapshot(78, native), at: 1000, directory: directory.url)
            let expected: [String: Any] = ["state": "discharging", "source": "station", "remaining_seconds": 4680]
            try runtimeEquals(status, expected)
            let restored = try JSONDecoder().decode(BluettiStatus.self, from: JSONEncoder().encode(status))
            try runtimeEquals(restored, expected)
        }
        try test("native_time_to_full_keeps_its_charging_meaning") {
            let directory = try BluettiTestDirectory()
            let native = BluettiRuntimeEstimator.fromStation(hours: 0.2, charging: true, percent: 78)
            let status = try attached(snapshot(78, native), at: 1000, directory: directory.url)
            try runtimeEquals(status, ["state": "charging", "source": "station", "remaining_seconds": 720])
        }
        try test("native_eta_wins_over_history_charging_idle_and_history_io_failure") {
            let directory = try BluettiTestDirectory()
            _ = try attached(unknownPower(snapshot(80)), at: 1000, directory: directory.url)
            let prior = try attached(unknownPower(snapshot(78)), at: 1120, directory: directory.url)
            try require(prior.runtime?.remainingSeconds == 4680 && prior.runtime?.source == .socHistory, "SOC fixture did not form a baseline.")
            var charging = try snapshot(77, BluettiRuntimeEstimator.fromStation(hours: 1.5, charging: false, percent: 77))
            charging["ac_input_w"] = 500
            let status = try attached(charging, at: 1150, directory: directory.url)
            try runtimeEquals(status, ["state": "discharging", "source": "station", "remaining_seconds": 5400, "backup": true])
            var idle = try snapshot(76, BluettiRuntimeEstimator.fromStation(hours: 0.2, charging: false, percent: 76))
            idle["dc_output_w"] = 0
            let whileIdle = try attached(idle, at: 1180, directory: directory.url)
            try require(whileIdle.runtime?.remainingSeconds == 720 && whileIdle.runtime?.source == .station, "Idle watts replaced native ETA.")
            let history = directory.url.appendingPathComponent(BluettiRuntimeEstimator.historyFilename)
            try FileManager.default.removeItem(at: history)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false, attributes: nil)
            let blocked = try attached(snapshot(75, BluettiRuntimeEstimator.fromStation(hours: 0.3, charging: false, percent: 75)), at: 1210, directory: directory.url)
            try require(blocked.runtime?.remainingSeconds == 1080 && blocked.runtime?.source == .station, "History I/O failure replaced native ETA.")
        }
        try test("unusable_native_values_do_not_escape_as_an_eta") {
            let cases: [(Double?, Bool)] = [(nil, false), (99.9, false), (0, false), (.nan, false),
                                           (.infinity, false), (-1, false), (99.9, false), (0, true), (.nan, true)]
            for (hours, charging) in cases {
                let native = hours.flatMap { BluettiRuntimeEstimator.fromStation(hours: $0, charging: charging, percent: 78) }
                let status = try attached(unknownPower(snapshot(78, native)), at: 1000, directory: nil)
                let value = try runtimeJSON(status)
                try require(value["remaining_seconds"] == nil && value["source"] == nil, "Invalid native data escaped as ETA.")
            }
        }
        try test("native_zero_is_valid_only_at_the_corresponding_soc_endpoint") {
            let empty = try attached(snapshot(0, BluettiRuntimeEstimator.fromStation(hours: 0, charging: false, percent: 0)), at: 1000, directory: nil)
            try runtimeEquals(empty, ["state": "empty", "source": "station", "remaining_seconds": 0])
            let full = try attached(snapshot(100, BluettiRuntimeEstimator.fromStation(hours: 0, charging: true, percent: 100)), at: 1000, directory: nil)
            try runtimeEquals(full, ["state": "charging", "source": "station", "remaining_seconds": 0])
        }
        try test("missing_native_and_power_data_use_persisted_soc_as_last_fallback") {
            let directory = try BluettiTestDirectory()
            let initial = try attached(unknownPower(snapshot(80)), at: 1000, directory: directory.url)
            try require(initial.runtime?.remainingSeconds == nil, "First unknown-power sample fabricated ETA.")
            let second = try attached(unknownPower(snapshot(78)), at: 1120, directory: directory.url)
            try runtimeEquals(second, ["state": "discharging", "source": "soc_history", "remaining_seconds": 4680,
                                       "window_seconds": 120, "drop_percent": 2])
        }
        try test("first_power_sample_gives_autonomy_without_waiting_for_soc_to_change") {
            let directory = try BluettiTestDirectory()
            var load = try snapshot(80); load["dc_output_w"] = 100
            let first = try attached(load, at: 1000, directory: directory.url)
            try runtimeEquals(first, ["state": "discharging", "source": "power", "remaining_seconds": 10095])
            for hours in [99.9, 0.0] {
                var fallback = try snapshot(80, BluettiRuntimeEstimator.fromStation(hours: hours, charging: false, percent: 80))
                fallback["dc_output_w"] = 100
                let status = try attached(fallback, at: 1000, directory: nil)
                try runtimeEquals(status, ["state": "discharging", "source": "power", "remaining_seconds": 10095])
            }
        }
        try test("power_under_external_or_unknown_input_is_backup_autonomy_not_time_to_full") {
            var mains = try snapshot(80)
            mains["dc_output_w"] = 100; mains["grid_present"] = true; mains["ac_input_w"] = 150
            let reserve = try attached(mains, at: 1000, directory: nil)
            try runtimeEquals(reserve, ["state": "discharging", "source": "power", "remaining_seconds": 10095, "backup": true])
            var unknown = try snapshot(80); unknown["dc_output_w"] = 100
            for key in ["ac_input_w", "dc_input_w", "_bluebar_power"] { unknown.removeValue(forKey: key) }
            let uncertain = try attached(unknown, at: 1000, directory: nil)
            try runtimeEquals(uncertain, ["state": "discharging", "source": "power", "remaining_seconds": 10095, "backup": true])
        }

        // Additional native port gates: parser edge cases, actual cache I/O,
        // a child-process lock attempt, file permissions, and corrupt history.
        try test("argument_boundaries_and_repeated_flags") {
            try require(try BluettiOptions.parse([]).command == .help, "Empty invocation is not help.")
            try require(try BluettiOptions.parse(["--self-test"]).command == .selfTest, "Self-test parsing failed.")
            for timeout in ["5", "120"] {
                let options = try BluettiOptions.parse(["status", "--timeout", timeout, "--device", "AC50P"])
                try require(options.timeout == UInt64(timeout) && options.device == "AC50P", "Valid timeout bounds were changed.")
            }
            for arguments in [["no-such-command"], ["status", "--device"], ["status", "--bad", "x"],
                              ["scan", "--device", "AC50P"], ["status", "--timeout", "4"],
                              ["status", "--timeout", "121"], ["status", "--timeout", "1.5"],
                              ["status", "--timeout", "5", "--timeout", "6"],
                              ["status", "--device", "a", "--device", "b"], ["--self-test", "extra"]] {
                try expectError("arguments") { _ = try BluettiOptions.parse(arguments) }
            }
            for code in ["crypto", "handshake", "protocol", "modbus", "permission"] {
                let value = BluettiNativeCommand.publicError(BluettiNativeFailure.failed(code: code, message: "fixture"))
                try require(value.code == "bluetooth" && value.message == "fixture", "A transport failure changed the public error category.")
            }
            for code in ["timeout", "not_found", "ambiguous", "invalid_data", "clock"] {
                let value = BluettiNativeCommand.publicError(BluettiNativeFailure.failed(code: code, message: "fixture"))
                try require(value.code == code, "A non-transport error category was changed.")
            }
        }
        try test("cached_reader_rejects_errors_wrong_station_and_unbounded_eta") {
            let directory = try BluettiTestDirectory()
            let cache = directory.url.appendingPathComponent("status.json")
            try Data("{\"ok\":false,\"error\":\"offline\",\"battery_percent\":99}".utf8).write(to: cache)
            try expectError("cache") { _ = try BluettiFiles.cachedStatus(directory: directory.url, device: nil, now: 1000) }
            var status = sample(1000, 42)
            try JSONEncoder().encode(status).write(to: cache)
            let matching = try BluettiFiles.cachedStatus(directory: directory.url, device: "ID1", now: 1000)
            try require(matching.batteryPercent == 42, "Exact cached UUID was rejected.")
            try expectError("cache") { _ = try BluettiFiles.cachedStatus(directory: directory.url, device: "other", now: 1000) }
            status.runtime = BluettiRuntime(state: .discharging, remainingSeconds: 604_801)
            try JSONEncoder().encode(status).write(to: cache)
            try expectError("invalid_data") { _ = try BluettiFiles.cachedStatus(directory: directory.url, device: nil, now: 1000) }
            try Data("{broken".utf8).write(to: cache)
            try expectError("cache") { _ = try BluettiFiles.cachedStatus(directory: directory.url, device: nil, now: 1000) }
        }
        try test("flock_is_exclusive_across_processes_and_releases") {
            let directory = try BluettiTestDirectory()
            let held = try BluettiBluetoothLock(directory: directory.url)
            defer { held.release() }
            try expectError("busy") { _ = try BluettiBluetoothLock(directory: directory.url) }
            let path = directory.url.appendingPathComponent("bluetooth.lock")
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                throw BluettiCommandError("self_test", "Cannot locate the executable for the lock test.")
            }
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--bluetti-helper", "--self-test-lock-child", path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            // The child has no signal handlers or Bluetooth run loop. Bound even
            // a failed launch path without calling Swift-unavailable Darwin fork.
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
            child.waitUntilExit()
            deadline.cancel()
            try require(child.terminationReason == .exit && child.terminationStatus == 0,
                        "A second process bypassed the Bluetooth flock or the lock-test child failed.")
            held.release()
            let next = try BluettiBluetoothLock(directory: directory.url)
            next.release()
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try require(mode == 0o600 && FileManager.default.fileExists(atPath: path), "Lock permissions/inode lifetime changed.")
        }
        try test("atomic_history_is_private_and_corruption_cannot_fabricate_eta") {
            let directory = try BluettiTestDirectory()
            let path = directory.url.appendingPathComponent(BluettiRuntimeEstimator.historyFilename)
            try Data("{broken".utf8).write(to: path)
            let value = try BluettiRuntimeEstimator.persist(directory: directory.url, status: sample(1000, 80))
            try require(value.state == .estimating && value.remainingSeconds == nil, "Corrupt history fabricated an ETA.")
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "History is not mode0600.")
            let data = try Data(contentsOf: path)
            let restored = try JSONDecoder().decode(BluettiRuntimeHistory.self, from: data)
            try require(restored.version == 1 && restored.samples.count == 1, "Atomic history is not readable in the compatible schema.")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            try require(files == [BluettiRuntimeEstimator.historyFilename], "A temporary history file leaked.")
        }
        return count
    }
}
