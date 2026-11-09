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

struct BluettiCommandError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

enum BluettiCommand: Equatable { case status, percent, scan, cached, help }

struct BluettiOptions {
    var command: BluettiCommand
    var device: String?
    var timeout: UInt64

    static func parse(_ arguments: [String]) throws -> BluettiOptions {
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            return BluettiOptions(command: .help, device: nil, timeout: 25)
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

    status   Read one fresh Bluetooth sample as JSON.
    percent  Read a fresh sample and print its integer battery percentage.
    scan     Find nearby AC50P stations and print their names and IDs as JSON.
    cached   Read BluettiBar's saved sample without Bluetooth; reject stale data.

    --device accepts an exact ID or part of the Bluetooth name (not case-sensitive).
    Multiple matching stations are an error. Default operation timeout: 25 seconds.

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

    static func run(arguments: [String]) -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            var command = arguments[...]
            let interval: PollInterval?
            if command.first == "--poll-session" {
                command = command.dropFirst()
                guard let value = command.first, let seconds = Int(value),
                      let choice = PollInterval(rawValue: seconds), choice.keepsConnection,
                      command.dropFirst().first == "status" else {
                    throw BluettiCommandError("arguments", "Invalid polling session.")
                }
                interval = choice
                command = command.dropFirst()
            } else { interval = nil }
            let options = try BluettiOptions.parse(Array(command))
            if options.command == .help {
                try BluettiFiles.writeAll(Data(usage.utf8), descriptor: STDOUT_FILENO)
                return 0
            }
            let directory = try BluettiFiles.cacheDirectory()
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
                    try BluettiBluetooth.readSamples(device: options.device, timeout: TimeInterval(options.timeout),
                                                     interval: interval) { object in
                        var status = try BluettiStatus.fromNative(object)
                        try BluettiFiles.validateStatus(status, now: BluettiFiles.unixNow())
                        BluettiRuntimeEstimator.attach(to: &status, directory: directory)
                        if options.command == .percent {
                            try BluettiFiles.writeAll(Data("\(status.batteryPercent)\n".utf8), descriptor: STDOUT_FILENO)
                        } else { try writeJSON(status) }
                    }
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
