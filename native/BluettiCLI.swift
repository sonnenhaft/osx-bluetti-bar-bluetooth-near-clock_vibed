// Runs in the app executable's isolated --bluetti-helper process, before NSApp.
// Foundation/POSIX only; the same code can be exercised without Bluetooth.
import Foundation
import CoreFoundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum BluettiCommand: Equatable { case status, percent, scan, cached, help, selfTest }

struct BluettiOptions {
    var command: BluettiCommand
    var device: String?
    var timeout: UInt64

    static func parse(_ arguments: [String]) throws -> BluettiOptions {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            return BluettiOptions(command: .help, device: nil, timeout: 25)
        }
        if arguments[0] == "--self-test" {
            guard arguments.count == 1 else { throw BluettiCommandError("arguments", "--self-test does not accept options.") }
            return BluettiOptions(command: .selfTest, device: nil, timeout: 25)
        }
        let command: BluettiCommand
        switch arguments[0] {
        case "status": command = .status
        case "percent": command = .percent
        case "scan": command = .scan
        case "cached": command = .cached
        default: throw BluettiCommandError("arguments", "Unknown command: \(arguments[0]). Use bluetti --help.")
        }
        var device: String?
        var timeout: UInt64 = 25
        var sawTimeout = false
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            index += 1
            guard index < arguments.count else { throw BluettiCommandError("arguments", "Missing value for \(key).") }
            let value = arguments[index]
            if key == "--device" && device == nil {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BluettiCommandError("arguments", "--device cannot be empty.")
                }
                device = value
            } else if key == "--timeout" && !sawTimeout {
                guard let seconds = UInt64(value), (5...120).contains(seconds) else {
                    throw BluettiCommandError("arguments", "--timeout must be an integer from 5 to 120.")
                }
                timeout = seconds
                sawTimeout = true
            } else { throw BluettiCommandError("arguments", "Unknown or repeated option: \(key).") }
            index += 1
        }
        if command == .scan && device != nil {
            throw BluettiCommandError("arguments", "scan lists all AC50P stations; omit --device.")
        }
        if command == .cached && sawTimeout {
            throw BluettiCommandError("arguments", "cached does not use Bluetooth; omit --timeout.")
        }
        return BluettiOptions(command: command, device: device, timeout: timeout)
    }
}

enum BluettiFiles {
    static func cacheDirectory() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw BluettiCommandError("filesystem", "Cannot determine the user's home directory.")
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/BlueBar", isDirectory: true)
    }

    static func unixNow() throws -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) else {
            throw BluettiCommandError("clock", "The system clock is earlier than the Unix epoch or is invalid.")
        }
        return UInt64(seconds)
    }

    static func systemError(_ number: Int32 = errno) -> String { return String(cString: strerror(number)) }

    static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #else
                let written = Glibc.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BluettiCommandError("output", systemError())
                }
                guard written > 0 else { throw BluettiCommandError("output", "Could not write output.") }
                offset += written
            }
        }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".runtime-history-\(getpid())-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw BluettiCommandError("filesystem", "Cannot create runtime history: \(systemError())") }
        var openDescriptor = true
        var renamed = false
        defer {
            if openDescriptor { _ = close(descriptor) }
            if !renamed { _ = temporary.path.withCString { unlink($0) } }
        }
        // create(...,0600) never temporarily exposes a newly written history.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BluettiCommandError("filesystem", "Cannot protect runtime history: \(systemError())")
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw BluettiCommandError("filesystem", "Cannot sync runtime history: \(systemError())") }
        let closeResult = close(descriptor)
        openDescriptor = false
        guard closeResult == 0 else { throw BluettiCommandError("filesystem", "Cannot close runtime history: \(systemError())") }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw BluettiCommandError("filesystem", "Cannot replace runtime history: \(systemError())") }
        renamed = true
    }

    static func validateStatus(_ status: BluettiStatus, now: UInt64) throws {
        guard status.ok, status.model == "AC50P", !status.device.isEmpty, status.batteryPercent <= 100 else {
            throw BluettiCommandError("invalid_data", "Battery data is missing or invalid; no percentage will be shown.")
        }
        let futureLimit = now > UInt64.max - 5 ? UInt64.max : now + 5
        guard status.observedAt <= futureLimit else {
            throw BluettiCommandError("invalid_data", "Cached timestamp is in the future. Check the Mac clock.")
        }
        let maximumAge: UInt64
        if let interval = status.refreshIntervalSeconds {
            guard [UInt64(5), 20, 30, 60, 120].contains(interval) else {
                throw BluettiCommandError("invalid_data", "Invalid cached refresh interval; expected 5, 20, 30, 60 or 120 seconds.")
            }
            maximumAge = max(90, interval + 35)
        } else { maximumAge = 90 }
        if let runtime = status.runtime, !runtime.isValid(percent: status.batteryPercent) {
            throw BluettiCommandError("invalid_data", "Cached runtime is invalid or exceeds seven days.")
        }
        let age = now >= status.observedAt ? now - status.observedAt : 0
        guard age <= maximumAge else {
            throw BluettiCommandError("stale", "Cached reading is \(age)s old (maximum \(maximumAge)s). Open BluettiBar to refresh the cache, or use bluetti status for a fresh reading.")
        }
    }

    static func cachedStatus(directory: URL, device: String?, now: UInt64) throws -> BluettiStatus {
        let bytes: Data
        do { bytes = try Data(contentsOf: directory.appendingPathComponent("status.json")) }
        catch {
            throw BluettiCommandError("cache", "No readable BluettiBar cache: \(error.localizedDescription). Open BluettiBar to refresh the cache, or use bluetti status for a fresh reading.")
        }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: bytes) }
        catch { throw BluettiCommandError("cache", "Invalid cache JSON: \(error.localizedDescription)") }
        if let object = value as? [String: Any], let ok = object["ok"] as? NSNumber,
           CFGetTypeID(ok) == CFBooleanGetTypeID(), !ok.boolValue {
            throw BluettiCommandError("cache", object["error"] as? String ?? "The last BluettiBar Bluetooth reading failed.")
        }
        let status: BluettiStatus
        do { status = try JSONDecoder().decode(BluettiStatus.self, from: bytes) }
        catch { throw BluettiCommandError("cache", "Invalid cache JSON: \(error.localizedDescription)") }
        try validateStatus(status, now: now)
        if let selector = device {
            let matches = status.device.lowercased().contains(selector.lowercased())
                || status.deviceID?.caseInsensitiveCompare(selector) == .orderedSame
            guard matches else { throw BluettiCommandError("cache", "The cached reading belongs to a different station.") }
        }
        return status
    }
}

// A genuine nonblocking cross-process flock. Never unlink this file: replacing
// its inode could allow two processes to hold independent "exclusive" locks.
final class BluettiBluetoothLock {
    private(set) var descriptor: Int32 = -1

    init(directory: URL) throws {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700]) }
        catch { throw BluettiCommandError("filesystem", "Cannot create cache directory: \(error.localizedDescription)") }
        descriptor = directory.appendingPathComponent("bluetooth.lock").path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw BluettiCommandError("filesystem", "Cannot open Bluetooth lock: \(BluettiFiles.systemError())") }
        if fchmod(descriptor, mode_t(0o600)) != 0 {
            let reason = BluettiFiles.systemError()
            release()
            throw BluettiCommandError("filesystem", "Cannot protect Bluetooth lock: \(reason)")
        }
        if Self.tryExclusive(descriptor) != 0 {
            let number = errno
            release()
            if number == EWOULDBLOCK || number == EAGAIN {
                throw BluettiCommandError("busy", "Another BluettiBar Bluetooth read is already running. Use bluetti cached or wait for it to finish.")
            }
            throw BluettiCommandError("filesystem", "Cannot lock Bluetooth reader: \(BluettiFiles.systemError(number))")
        }
    }

    static func tryExclusive(_ descriptor: Int32) -> Int32 {
        return bluetti_flock(descriptor, LOCK_EX | LOCK_NB)
    }

    func release() {
        if descriptor >= 0 { _ = close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

private final class BluettiCancellationSignals {
    private var sources: [DispatchSourceSignal] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { BluettiBluetooth.cancelCurrentOperation() }
            source.resume()
            sources.append(source)
        }
    }
    deinit {
        for source in sources { source.cancel() }
        _ = signal(SIGINT, SIG_DFL)
        _ = signal(SIGTERM, SIG_DFL)
    }
}

enum BluettiNativeCommand {
    static let usage = """
    bluetti — read-only BLUETTI AC50P battery reader

    Usage:
      bluetti status  [--device NAME_OR_ID] [--timeout SECONDS]
      bluetti percent [--device NAME_OR_ID] [--timeout SECONDS]
      bluetti scan    [--timeout SECONDS]
      bluetti cached [--device NAME_OR_ID]
      bluetti --help
      bluetti --self-test

    status   Read one fresh Bluetooth sample as JSON.
    percent  Read a fresh sample and print its integer battery percentage.
    scan     Find nearby AC50P stations and print their names and IDs as JSON.
    cached   Read BluettiBar's saved sample without Bluetooth; reject stale data.

    --device accepts an exact ID or part of the Bluetooth name (not case-sensitive).
    Multiple matching stations are an error. Default operation timeout: 25 seconds.
    --self-test checks protocol/runtime/cache logic without using Bluetooth.

    Close the official BLUETTI phone app before connecting. macOS may request
    Bluetooth access for BluettiBar or the terminal used to launch this helper.

    """

    static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try encoder.encode(value) }
        catch { throw BluettiCommandError("output", error.localizedDescription) }
        var line = bytes
        line.append(0x0a)
        try BluettiFiles.writeAll(line, descriptor: STDOUT_FILENO)
    }

    static func writeJSONObject(_ value: [String: Any]) throws {
        var data: Data
        do { data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        catch { throw BluettiCommandError("output", error.localizedDescription) }
        data.append(0x0a)
        try BluettiFiles.writeAll(data, descriptor: STDOUT_FILENO)
    }

    static func publicError(_ error: Error) -> BluettiCommandError {
        if let problem = error as? BluettiCommandError { return problem }
        if let failure = error as? BluettiNativeFailure {
            switch failure {
            case let .failed(code, message):
                // The original helper exposed protocol/crypto/permission
                // failures under its stable public "bluetooth" category.
                let transport = ["crypto", "handshake", "protocol", "modbus", "permission"]
                return BluettiCommandError(transport.contains(code) ? "bluetooth" : code, message)
            }
        }
        return BluettiCommandError("runtime", error.localizedDescription)
    }

    // The optional URL is dependency injection for offline verification only;
    // there is no extra command-line flag/environment override in the app.
    static func run(arguments: [String], cacheDirectory: URL? = nil) -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            if arguments.first == "--self-test-lock-child" {
                guard arguments.count == 2 else {
                    throw BluettiCommandError("arguments", "Invalid internal lock-test invocation.")
                }
                return try BluettiNativeSelfTests.probeExistingTestLock(path: arguments[1])
            }
            let options = try BluettiOptions.parse(arguments)
            if options.command == .help {
                try BluettiFiles.writeAll(Data(usage.utf8), descriptor: STDOUT_FILENO)
                return 0
            }
            if options.command == .selfTest {
                let protocolCount = try BluettiBluetooth.selfTest()
                let logicCount = try BluettiNativeSelfTests.run()
                try writeJSONObject(["ok": true, "self_test": "passed", "tests": protocolCount + logicCount,
                                     "protocol_tests": protocolCount, "logic_tests": logicCount])
                return 0
            }
            let directory = try cacheDirectory ?? BluettiFiles.cacheDirectory()
            if options.command == .cached {
                try writeJSON(BluettiFiles.cachedStatus(directory: directory, device: options.device,
                                                       now: BluettiFiles.unixNow()))
                return 0
            }
            let bluetoothLock = try BluettiBluetoothLock(directory: directory)
            defer { bluetoothLock.release() }
            let cancellation = BluettiCancellationSignals()
            return try withExtendedLifetime(cancellation) {
                if options.command == .scan {
                    let devices = try BluettiBluetooth.scan(timeout: TimeInterval(options.timeout))
                    let entries: [[String: Any]] = devices.filter { ($0.json["model"] as? String) == "AC50P" }
                        .map { ["name": $0.name, "id": $0.id, "model": "AC50P"] }
                    try writeJSONObject(["ok": true, "devices": entries])
                } else {
                    let object = try BluettiBluetooth.read(device: options.device, timeout: TimeInterval(options.timeout))
                    var status = try BluettiStatus.fromNative(object)
                    try BluettiFiles.validateStatus(status, now: BluettiFiles.unixNow())
                    BluettiRuntimeEstimator.attach(to: &status, directory: directory)
                    if options.command == .percent {
                        try BluettiFiles.writeAll(Data("\(status.batteryPercent)\n".utf8), descriptor: STDOUT_FILENO)
                    } else { try writeJSON(status) }
                }
                return Int32(0)
            }
        } catch {
            let problem = publicError(error)
            try? writeJSONObject(["ok": false, "code": problem.code, "error": problem.message])
            return 1
        }
    }
}
