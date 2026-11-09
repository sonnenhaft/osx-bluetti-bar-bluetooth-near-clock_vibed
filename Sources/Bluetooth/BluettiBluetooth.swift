// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation

struct BluettiNativeDevice {
    let id: String
    let name: String
    var json: [String: Any]

    init(id: String, name: String, json: [String: Any]? = nil) {
        self.id = (UUID(uuidString: id)?.uuidString ?? id).lowercased()
        self.name = name
        self.json = json ?? ["id": self.id, "name": name, "model": "AC50P"]
    }
}

enum BluettiNativeFailure: Error {
    case failed(code: String, message: String)

    var code: String {
        switch self { case .failed(let code, _): return code }
    }
    var message: String {
        switch self { case .failed(_, let message): return message }
    }
}

final class BluettiBluetooth {
    private static weak var active: BluettiCentral?

    /// Invoke on the main thread in the headless helper process. CoreBluetooth
    /// callbacks run on its main queue; the bounded driver pumps that RunLoop.
    static func scan(timeout: TimeInterval) throws -> [BluettiNativeDevice] {
        try validateInvocation(timeout)
        let driver = BluettiCentral(timeout: timeout, reserveCleanup: false)
        active = driver
        defer { driver.close(); active = nil }
        return try driver.scan(duration: min(6, timeout))
    }

    static func read(device: String?, timeout: TimeInterval) throws -> [String: Any] {
        try validateInvocation(timeout)
        let driver = BluettiCentral(timeout: timeout, reserveCleanup: true)
        active = driver
        defer { driver.close(); active = nil }
        let found = try driver.scan(duration: min(4, max(0.2, timeout - 3)))
        let selected = try bluettiChooseDevice(found, selector: device)
        try driver.connect(selected)
        try driver.handshake()
        let registers = try driver.readRegisters()
        return try BluettiIoTProtocol.snapshot(registers: registers, device: selected)
    }

    static func cancelCurrentOperation() {
        if Thread.isMainThread { active?.cancel() }
        else { DispatchQueue.main.async { active?.cancel() } }
    }

    private static func validateInvocation(_ timeout: TimeInterval) throws {
        guard Thread.isMainThread else {
            throw BluettiNativeFailure.failed(code: "runtime", message: "Bluetooth must run on the helper's main thread.")
        }
        guard timeout.isFinite, timeout >= 1, timeout <= 120 else {
            throw BluettiNativeFailure.failed(code: "arguments", message: "Bluetooth timeout must be between 1 and 120 seconds.")
        }
    }
}
