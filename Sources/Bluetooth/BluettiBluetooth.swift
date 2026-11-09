// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation
import CryptoKit

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

    /// Deterministic protocol checks. Does NOT instantiate CBCentralManager,
    /// scan, connect, request Bluetooth permission, or read/write user settings.
    static func selfTest() throws -> Int {
        var tests = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw BluettiNativeFailure.failed(code: "self_test", message: "Native protocol self-test failed: " + name) }
            tests += 1
        }
        func hex(_ value: String) -> [UInt8] {
            let chars = Array(value)
            return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
        }
        let challenge = hex("2a2a0104ffdf22b702bc")
        let crypto = BluettiIoTCrypto()
        try check(try crypto.replyChallenge(challenge) == hex("2a2a02045a4fd30e0190"), "captured challenge reply")
        let key = hex("2669e7bcc1497dbc2ade3397bd1f2605"), iv = hex("63f6228941c03c4d5a4fd30e83fccf38")
        try check(crypto.temporaryKey == key && crypto.temporaryIV == iv, "temporary key and IV")
        let aligned = Array(UInt8(0)...UInt8(15)), unaligned = Array(UInt8(0)...UInt8(16))
        let temporary16 = hex("00101f8f17a678c529f1f008d9a292490550")
        let temporary17 = hex("00111f8f17a678c529f1f008d9a292490550d2928e16410c7597fbeaf4cdc6d4362a")
        try check(try BluettiIoTProtocol.encryptFrame(aligned, key: key, iv: iv) == temporary16, "AES128 zero padding aligned")
        try check(try BluettiIoTProtocol.encryptFrame(unaligned, key: key, iv: iv) == temporary17, "AES128 zero padding unaligned")
        try check(try BluettiIoTProtocol.decryptFrame(temporary17, key: key, iv: iv) == unaligned, "AES length truncation")
        let sessionKey = Array(UInt8(0)...UInt8(31)), seed: [UInt8] = [1,2,3,4]
        let session17 = hex("00110102030461bf3b04e14b5bcc639feea768d6e8c9f5c0f5210929a3a35430424b3f0afad8")
        try check(try BluettiIoTProtocol.encryptFrame(unaligned, key: sessionKey, iv: nil, seed: seed) == session17, "AES256 seed framing")
        try check(try BluettiIoTProtocol.decryptFrame(session17, key: sessionKey, iv: nil) == unaligned, "AES256 session decode")
        try check(try BluettiIoTProtocol.encryptFrame([], key: key, iv: iv) == [0,0], "empty frame no padding block")
        let decoder = BluettiFrameDecoder(crypto: crypto)
        try decoder.append(Array(temporary17.prefix(3)))
        try check(try decoder.next() == nil, "partial encrypted header")
        try decoder.append(Array(temporary17.dropFirst(3)) + temporary16)
        if case .application(let body)? = try decoder.next() { try check(body == unaligned, "fragment reassembly") }
        else { try check(false, "fragment reassembly") }
        if case .application(let body)? = try decoder.next() { try check(body == aligned, "coalesced frame retained") }
        else { try check(false, "coalesced frame retained") }
        let splitKex = BluettiFrameDecoder(crypto: BluettiIoTCrypto())
        try splitKex.append([challenge[0]])
        try check(try splitKex.next() == nil, "partial plaintext magic")
        try splitKex.append(Array(challenge.dropFirst()))
        if case .keyExchange(let body)? = try splitKex.next() { try check(body == challenge, "plaintext fragmentation") }
        else { try check(false, "plaintext fragmentation") }
        try check(try BluettiIoTProtocol.readHolding(address: 102, quantity: 16) == hex("010300660010a419"), "FC3 request CRC")
        try check(try BluettiIoTProtocol.parseHolding(hex("01030600600002004a814a"), quantity: 3) == [96,2,74], "FC3 response CRC")
        do { _ = try BluettiIoTProtocol.parseHolding(hex("01030600600002004a814b"), quantity: 3); try check(false, "bad CRC rejected") }
        catch let error as BluettiNativeFailure { try check(error.code == "protocol", "bad CRC rejected") }
        do { _ = try BluettiIoTProtocol.parseHolding(hex("018302c0f1"), quantity: 3); try check(false, "Modbus exception rejected") }
        catch let error as BluettiNativeFailure { try check(error.code == "modbus", "Modbus exception rejected") }
        let peer = hex("047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1")
        let secret = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data([UInt8](repeating: 0, count: 31) + [1]))
        let shared = try secret.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: Data(peer)))
        try check(shared.withUnsafeBytes { Array($0) } == hex("7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978"), "raw P256 ECDH")
        let verification = hex("043f29e1b8b29d8422bbb0e0f09000cf2ee2931da13cdac8129f8c09deac07f519b5ac5509ca3f3f59b234b7777a231ae595ca5aa1745fd7a62bc4d02037117dd1")
        let signature = hex("f5314e979d82bd571856c002c8e33eb78d7cc398ab51423cb166cb88d361e2d24c6d45f0b35e6c0d714fe960dc30f63de3aebb56b2106a68f6a68669a4bf999b")
        try check(try BluettiIoTCrypto.verifyPeer(point: Array(peer.dropFirst()), signature: signature, iv: iv, verificationKey: verification), "raw64 ECDSA SHA256")
        var tamperedIV = iv; tamperedIV[0] ^= 1
        try check(try !BluettiIoTCrypto.verifyPeer(point: Array(peer.dropFirst()), signature: signature, iv: tamperedIV, verificationKey: verification), "tampered peer signature rejected")
        let device = BluettiNativeDevice(id: "00000000-0000-0000-0000-000000000001", name: "AC50P-test")
        let discharge = try BluettiIoTProtocol.snapshot(registers: [102:96,103:2,104:74,140:61,142:0,144:0,146:0], device: device)
        let runtime = discharge["runtime"] as? [String: Any]
        try check(runtime?["remaining_seconds"] as? Int == 26640 && runtime?["state"] as? String == "discharging", "native discharge register")
        let charge = try BluettiIoTProtocol.snapshot(registers: [102:78,103:1,104:2,146:178], device: device)
        try check((charge["runtime"] as? [String: Any])?["remaining_seconds"] as? Int == 720, "native time to full")
        let idle = try BluettiIoTProtocol.snapshot(registers: [102:100,103:1,104:458,140:0,142:0,146:0,1314:2420], device: device)
        try check(idle["runtime"] == nil, "mains idle native time suppressed")
        let sentinel = try BluettiIoTProtocol.snapshot(registers: [102:78,104:999], device: device)
        try check(sentinel["runtime"] == nil, "native idle sentinel suppressed")
        return tests
    }
}
