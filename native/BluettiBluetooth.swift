// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.

import Foundation
import CoreBluetooth
import CryptoKit
import CommonCrypto
import Security

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

// Internal rather than private so the built-in, radio-free self-tests exercise
// the exact framing, crypto and register decoder used by the live connection.
enum BluettiIoTProtocol {
    static let maximumPlaintext = 4096
    static let pollWindows: [(UInt16, UInt16)] = [(102, 16), (116, 4), (140, 8), (1300, 16), (2011, 12)]
    static let localAESKey: [UInt8] = [
        0x45,0x9f,0xc5,0x35,0x80,0x89,0x41,0xf1,0x70,0x91,0xe0,0x99,0x3e,0xe3,0xe9,0x3d
    ]
    // Published device-shared signing constant, NOT a user or station credential.
    static let hostSigningKey: [UInt8] = [
        0x4f,0x19,0xa1,0x6e,0x3e,0x87,0xbd,0xd9,0xbd,0x24,0xd3,0xe5,0x49,0x5b,0x88,0x04,
        0x15,0x11,0x94,0x3c,0xbc,0x8b,0x96,0x9a,0xde,0x96,0x41,0xd0,0xf5,0x6a,0xf3,0x37
    ]
    static let peerVerificationKey: [UInt8] = [
        0x04,0xa7,0x3a,0xbf,0x5d,0x22,0x32,0xc8,0xc1,0xc7,0x2e,0x68,0x30,0x43,0x43,0xc2,
        0x72,0x49,0x5e,0x3a,0x8f,0xd6,0xf3,0x0e,0xa9,0x6d,0xe2,0xf4,0xb3,0xce,0x60,0xb2,
        0x51,0xee,0x21,0xac,0x66,0x7c,0xf8,0xa7,0x1e,0x18,0xb4,0x6b,0x66,0x4e,0xae,0xff,
        0xe3,0xc4,0x89,0xf2,0x4f,0x69,0x5b,0x64,0x11,0xdb,0x7e,0x22,0xcc,0xc8,0x5a,0x85,0x94
    ]

    struct KeyExchange {
        let type: UInt8
        let payload: [UInt8]
    }

    static func isKeyExchange(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x2a && bytes[1] == 0x2a
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        bytes.reduce(UInt16(0)) { $0 &+ UInt16($1) }
    }

    static func keyExchange(type: UInt8, payload: [UInt8]) throws -> [UInt8] {
        guard (1...6).contains(type), payload.count <= 255 else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Invalid key-exchange payload.")
        }
        let body = [type, UInt8(payload.count)] + payload
        let sum = checksum(body[...])
        return [0x2a, 0x2a] + body + [UInt8(sum >> 8), UInt8(sum & 0xff)]
    }

    static func parseKeyExchange(_ bytes: [UInt8]) throws -> KeyExchange {
        guard bytes.count >= 6, isKeyExchange(bytes), (1...6).contains(bytes[2]),
              bytes.count == 6 + Int(bytes[3]) else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Malformed key-exchange frame.")
        }
        let n = bytes.count
        let supplied = UInt16(bytes[n - 2]) << 8 | UInt16(bytes[n - 1])
        guard supplied == checksum(bytes[2..<(n - 2)]) else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Key-exchange checksum mismatch.")
        }
        return KeyExchange(type: bytes[2], payload: Array(bytes[4..<(n - 2)]))
    }

    static func md5(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(bytes)))
    }

    static func randomSeed() throws -> [UInt8] {
        var seed = [UInt8](repeating: 0, count: 4)
        let result = seed.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, raw.count, raw.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "System random generator failed.")
        }
        return seed
    }

    static func aesCBC(_ input: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard [16, 32].contains(key.count), iv.count == 16, input.count % 16 == 0 else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "Invalid AES-CBC key, IV or block length.")
        }
        if input.isEmpty { return [] }
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var written = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    input.withUnsafeBytes { inBytes in
                        // No PKCS#7: IoT-v2 specifies explicit zero padding.
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0), keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, out.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written == input.count else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "System AES-CBC operation failed (\(status)).")
        }
        return Array(output.prefix(written))
    }

    static func expectedEncryptedLength(_ prefix: [UInt8], session: Bool) throws -> Int? {
        guard prefix.count >= 2 else { return nil }
        let length = Int(prefix[0]) << 8 | Int(prefix[1])
        guard length <= maximumPlaintext else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Encrypted frame exceeds the receive limit.")
        }
        return (session ? 6 : 2) + ((length + 15) / 16) * 16
    }

    static func encryptFrame(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]?,
                             seed suppliedSeed: [UInt8]? = nil) throws -> [UInt8] {
        guard plaintext.count <= maximumPlaintext else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Outgoing encrypted frame is too large.")
        }
        var result: [UInt8] = [UInt8(plaintext.count >> 8), UInt8(plaintext.count & 0xff)]
        let actualIV: [UInt8]
        if let iv = iv { actualIV = iv }
        else {
            let seed = try suppliedSeed ?? randomSeed()
            guard seed.count == 4 else {
                throw BluettiNativeFailure.failed(code: "crypto", message: "Invalid session IV seed.")
            }
            result += seed
            actualIV = md5(seed)
        }
        var padded = plaintext
        if padded.count % 16 != 0 { padded += [UInt8](repeating: 0, count: 16 - padded.count % 16) }
        result += try aesCBC(padded, key: key, iv: actualIV, encrypt: true)
        return result
    }

    static func decryptFrame(_ frame: [UInt8], key: [UInt8], iv: [UInt8]?) throws -> [UInt8] {
        let session = iv == nil
        guard let expected = try expectedEncryptedLength(frame, session: session), frame.count == expected else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Truncated or oversized encrypted frame.")
        }
        let length = Int(frame[0]) << 8 | Int(frame[1])
        let header = session ? 6 : 2
        let actualIV = iv ?? md5(Array(frame[2..<6]))
        let plain = try aesCBC(Array(frame[header...]), key: key, iv: actualIV, encrypt: false)
        guard length <= plain.count else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Encrypted frame length is invalid.")
        }
        return Array(plain.prefix(length))
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }

    static func readHolding(address: UInt16, quantity: UInt16) throws -> [UInt8] {
        guard quantity > 0, quantity <= 125, UInt32(address) + UInt32(quantity) <= 65536 else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Invalid holding-register read range.")
        }
        var request: [UInt8] = [1, 3, UInt8(address >> 8), UInt8(address & 0xff),
                                UInt8(quantity >> 8), UInt8(quantity & 0xff)]
        let crc = crc16(request)
        request += [UInt8(crc & 0xff), UInt8(crc >> 8)]
        return request
    }

    static func parseHolding(_ response: [UInt8], quantity: UInt16) throws -> [UInt16] {
        guard response.count >= 5, response[0] == 1 else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Invalid Modbus reply header.")
        }
        let n = response.count
        let supplied = UInt16(response[n - 2]) | UInt16(response[n - 1]) << 8
        guard crc16(Array(response[..<(n - 2)])) == supplied else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Modbus reply CRC mismatch.")
        }
        if response[1] == 0x83 {
            guard response.count == 5 else {
                throw BluettiNativeFailure.failed(code: "protocol", message: "Malformed Modbus exception.")
            }
            throw BluettiNativeFailure.failed(code: "modbus", message: "Station rejected register read (exception \(response[2])).")
        }
        guard response[1] == 3, Int(response[2]) == Int(quantity) * 2,
              response.count == 5 + Int(response[2]) else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Modbus reply length does not match the requested registers.")
        }
        return stride(from: 3, to: n - 2, by: 2).map { UInt16(response[$0]) << 8 | UInt16(response[$0 + 1]) }
    }

    static func snapshot(registers: [UInt16: UInt16], device: BluettiNativeDevice,
                         observedAt: Date = Date()) throws -> [String: Any] {
        guard let percent = registers[102], percent <= 100 else {
            throw BluettiNativeFailure.failed(code: "invalid_data", message: "Station did not return a valid battery percentage.")
        }
        let epoch = observedAt.timeIntervalSince1970
        guard epoch.isFinite, epoch >= 0, epoch < Double(Int64.max) else {
            throw BluettiNativeFailure.failed(code: "clock", message: "System time is invalid.")
        }
        let acIn = registers[146], dcIn = registers[144], acOut = registers[142], dcOut = registers[140]
        let grid = registers[103] == 1 || (acIn ?? 0) > 0
            || (registers[1314] ?? 0) > 0 || (registers[1300] ?? 0) > 0
        var result: [String: Any] = ["ok": true, "model": "AC50P", "device": device.name,
            "device_id": device.id.lowercased(), "battery_percent": Int(percent),
            "observed_at": Int64(epoch.rounded(.down)), "grid_present": grid]
        for (key, value) in [("ac_input_w", acIn), ("dc_input_w", dcIn), ("ac_output_w", acOut), ("dc_output_w", dcOut)] {
            if let value = value { result[key] = Int(value) }
        }
        if let value = registers[2011] { result["ac_on"] = value != 0 }
        if let value = registers[2012] { result["dc_on"] = value != 0 }

        // Exact rustytti register-104 semantics, then the existing CLI's sane
        // range/zero validation. A mains-idle leftover is never a native ETA.
        if let raw = registers[104], raw <= 998 {
            let charging = (acIn ?? 0) > 0
            let idle = !charging && grid && (acOut ?? 0) == 0 && (dcOut ?? 0) == 0
            if !idle && (raw > 0 || (charging ? percent == 100 : percent == 0)) {
                let state = charging ? "charging" : (percent == 0 ? "empty" : "discharging")
                var runtime: [String: Any] = ["state": state, "source": "station",
                    "remaining_seconds": state == "empty" ? 0 : Int(raw) * 360]
                if state == "discharging" && (grid || (dcIn ?? 0) > 0) { runtime["backup"] = true }
                result["runtime"] = runtime
            }
        }
        var power: [String: Any] = ["charging": false, "idle": acOut == 0 && dcOut == 0]
        if let acIn = acIn, let dcIn = dcIn, let acOut = acOut, let dcOut = dcOut {
            power["charging"] = Int(acIn) + Int(dcIn) >= Int(acOut) + Int(dcOut) + 20
        }
        if acIn != nil, let dcIn = dcIn, registers[1314] != nil || registers[1300] != nil {
            power["input_present"] = grid || dcIn > 0
        }
        result["_bluebar_power"] = power
        return result
    }
}

final class BluettiIoTCrypto {
    private(set) var temporaryKey: [UInt8]?
    private(set) var temporaryIV: [UInt8]?
    private(set) var sessionKey: [UInt8]?
    private var hostSecret: P256.KeyAgreement.PrivateKey?
    private var peerPublic: P256.KeyAgreement.PublicKey?
    var isSession: Bool { sessionKey != nil }

    func replyChallenge(_ frame: [UInt8]) throws -> [UInt8] {
        let message = try BluettiIoTProtocol.parseKeyExchange(frame)
        guard message.type == 1, message.payload.count == 4 else {
            throw BluettiNativeFailure.failed(code: "handshake", message: "Invalid station challenge.")
        }
        let iv = BluettiIoTProtocol.md5(Array(message.payload.reversed()))
        temporaryIV = iv
        temporaryKey = zip(iv, BluettiIoTProtocol.localAESKey).map { pair in pair.0 ^ pair.1 }
        sessionKey = nil
        hostSecret = nil
        peerPublic = nil
        return try BluettiIoTProtocol.keyExchange(type: 2, payload: Array(iv[8..<12]))
    }

    static func verifyPeer(point: [UInt8], signature: [UInt8], iv: [UInt8],
                           verificationKey: [UInt8] = BluettiIoTProtocol.peerVerificationKey) throws -> Bool {
        guard point.count == 64, signature.count == 64, iv.count == 16 else { return false }
        let key = try P256.Signing.PublicKey(x963Representation: Data(verificationKey))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(signature))
        let digest = SHA256.hash(data: Data(point + iv))
        return key.isValidSignature(sig, for: digest)
    }

    func replyPeer(_ frame: [UInt8]) throws -> [UInt8] {
        let message = try BluettiIoTProtocol.parseKeyExchange(frame)
        guard message.type == 4, message.payload.count == 128,
              let iv = temporaryIV, let key = temporaryKey else {
            throw BluettiNativeFailure.failed(code: "handshake", message: "Invalid station public-key message.")
        }
        let point = Array(message.payload[..<64]), signature = Array(message.payload[64...])
        guard try Self.verifyPeer(point: point, signature: signature, iv: iv) else {
            throw BluettiNativeFailure.failed(code: "handshake", message: "Station public-key signature is invalid.")
        }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data([0x04] + point))
        let secret = P256.KeyAgreement.PrivateKey()
        let hostPoint = Array(secret.publicKey.x963Representation.dropFirst())
        guard hostPoint.count == 64 else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "System returned an invalid P-256 public key.")
        }
        let signer = try P256.Signing.PrivateKey(rawRepresentation: Data(BluettiIoTProtocol.hostSigningKey))
        let digest = SHA256.hash(data: Data(hostPoint + iv))
        let hostSignature = try signer.signature(for: digest).rawRepresentation
        guard hostSignature.count == 64 else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "System returned an invalid P-256 signature.")
        }
        hostSecret = secret
        peerPublic = peer
        let plain = try BluettiIoTProtocol.keyExchange(type: 5, payload: hostPoint + Array(hostSignature))
        return try BluettiIoTProtocol.encryptFrame(plain, key: key, iv: iv)
    }

    func acceptPeer(_ frame: [UInt8]) throws {
        let message = try BluettiIoTProtocol.parseKeyExchange(frame)
        guard message.type == 6, message.payload == [0], let secret = hostSecret, let peer = peerPublic else {
            throw BluettiNativeFailure.failed(code: "handshake", message: "Station did not accept the public key.")
        }
        let shared = try secret.sharedSecretFromKeyAgreement(with: peer)
        let bytes = shared.withUnsafeBytes { Array($0) }
        guard bytes.count == 32 else {
            throw BluettiNativeFailure.failed(code: "crypto", message: "System returned an invalid P-256 shared secret.")
        }
        // Protocol requires the RAW ECDH x-coordinate, with no HKDF or hash.
        sessionKey = bytes
        hostSecret = nil
    }

    func encrypt(_ plain: [UInt8]) throws -> [UInt8] {
        if let key = sessionKey { return try BluettiIoTProtocol.encryptFrame(plain, key: key, iv: nil) }
        if let key = temporaryKey, let iv = temporaryIV { return try BluettiIoTProtocol.encryptFrame(plain, key: key, iv: iv) }
        throw BluettiNativeFailure.failed(code: "handshake", message: "No encryption key has been established.")
    }

    func decrypt(_ frame: [UInt8]) throws -> [UInt8] {
        if let key = sessionKey { return try BluettiIoTProtocol.decryptFrame(frame, key: key, iv: nil) }
        if let key = temporaryKey, let iv = temporaryIV { return try BluettiIoTProtocol.decryptFrame(frame, key: key, iv: iv) }
        throw BluettiNativeFailure.failed(code: "handshake", message: "No decryption key has been established.")
    }
}

enum BluettiFrame {
    case keyExchange([UInt8])
    case application([UInt8])
}

final class BluettiFrameDecoder {
    let crypto: BluettiIoTCrypto
    private var buffer: [UInt8] = []
    init(crypto: BluettiIoTCrypto) { self.crypto = crypto }

    func append(_ data: [UInt8]) throws {
        guard buffer.count + data.count <= 16384 else {
            throw BluettiNativeFailure.failed(code: "protocol", message: "Station notification buffer exceeded its limit.")
        }
        buffer += data
    }

    func next() throws -> BluettiFrame? {
        guard buffer.count >= 2 else { return nil }
        if BluettiIoTProtocol.isKeyExchange(buffer) {
            guard buffer.count >= 4 else { return nil }
            let expected = 6 + Int(buffer[3])
            guard buffer.count >= expected else { return nil }
            let frame = Array(buffer.prefix(expected))
            _ = try BluettiIoTProtocol.parseKeyExchange(frame)
            buffer.removeFirst(expected)
            return .keyExchange(frame)
        }
        // A resend of type5 can cause a duplicate temporary-key type6 after
        // session activation. Consume only a fully verified exact type6 frame.
        if crypto.isSession, buffer[0] == 0, buffer[1] == 7, buffer.count >= 18,
           let key = crypto.temporaryKey, let iv = crypto.temporaryIV,
           let plain = try? BluettiIoTProtocol.decryptFrame(Array(buffer.prefix(18)), key: key, iv: iv),
           let message = try? BluettiIoTProtocol.parseKeyExchange(plain), message.type == 6, message.payload == [0] {
            buffer.removeFirst(18)
            return .keyExchange(plain)
        }
        guard let expected = try BluettiIoTProtocol.expectedEncryptedLength(buffer, session: crypto.isSession),
              buffer.count >= expected else { return nil }
        let frame = Array(buffer.prefix(expected))
        let plain = try crypto.decrypt(frame)
        buffer.removeFirst(expected)
        if BluettiIoTProtocol.isKeyExchange(plain) {
            _ = try BluettiIoTProtocol.parseKeyExchange(plain)
            return .keyExchange(plain)
        }
        return .application(plain)
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

private final class BluettiCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceID = CBUUID(string: "FF00")
    private static let notifyID = CBUUID(string: "FF01")
    private static let writeID = CBUUID(string: "FF02")
    private let finalDeadline: TimeInterval
    private let deadline: TimeInterval
    private var central: CBCentralManager!
    private var discovered: [String: (CBPeripheral, BluettiNativeDevice)] = [:]
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var failure: BluettiNativeFailure?
    private var connectionFinished = false
    private var connectionError: String?
    private var connected = false
    private var closing = false
    private var expectingDisconnect = false
    private var notifyReady = false
    private var awaitingWrite = false
    private var writeFinished = false
    private var writeError: String?
    private var codec = BluettiFrameDecoder(crypto: BluettiIoTCrypto())

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(timeout: TimeInterval, reserveCleanup: Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        finalDeadline = start + timeout
        deadline = start + max(0.1, timeout - (reserveCleanup ? min(2, timeout / 4) : 0))
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func cancel() {
        failure = .failed(code: "cancelled", message: "Bluetooth reading was cancelled.")
        if central.state == .poweredOn { central.stopScan() }
        if let peripheral = peripheral, peripheral.state != .disconnected {
            expectingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func close() {
        closing = true
        if central.state == .poweredOn { central.stopScan() }
        if let peripheral = peripheral, peripheral.state != .disconnected {
            expectingDisconnect = true
            central.cancelPeripheralConnection(peripheral)
            let cleanupEnd = min(finalDeadline, now + 2)
            while peripheral.state != .disconnected && now < cleanupEnd { pump(until: cleanupEnd) }
        }
        peripheral?.delegate = nil
        central.delegate = nil
    }

    private func check() throws {
        if let failure = failure { throw failure }
        if now >= deadline { throw BluettiNativeFailure.failed(code: "timeout", message: "Bluetooth operation exceeded its timeout.") }
    }

    private func pump(until limit: TimeInterval) {
        let slice = min(0.25, max(0, limit - now))
        guard slice > 0 else { return }
        if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: slice)) {
            Thread.sleep(forTimeInterval: min(0.05, slice))
        }
    }

    private func wait(until limit: TimeInterval, message: String, condition: () -> Bool) throws {
        while true {
            try check()
            if condition() { return }
            guard now < limit else { throw BluettiNativeFailure.failed(code: "timeout", message: message) }
            pump(until: min(deadline, limit))
        }
    }

    func scan(duration: TimeInterval) throws -> [BluettiNativeDevice] {
        try wait(until: min(deadline, now + 5), message: "Bluetooth did not become ready.") { self.central.state == .poweredOn }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        defer { central.stopScan() }
        let scanEnd = min(deadline, now + duration)
        while now < scanEnd {
            if let failure = failure { throw failure }
            pump(until: scanEnd)
        }
        if let failure = failure { throw failure }
        return discovered.values.map { $0.1 }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    func connect(_ device: BluettiNativeDevice) throws {
        try check()
        guard let found = discovered[device.id.lowercased()] else {
            throw BluettiNativeFailure.failed(code: "not_found", message: "Selected AC50P is no longer available.")
        }
        let target = found.0
        peripheral = target
        target.delegate = self
        var lastError: Error = BluettiNativeFailure.failed(code: "timeout", message: "Could not connect to AC50P.")
        for _ in 0..<3 {
            try check()
            connectionFinished = false
            connectionError = nil
            connected = false
            expectingDisconnect = false
            central.connect(target, options: nil)
            do {
                try wait(until: min(deadline, now + 5), message: "Timed out connecting to AC50P.") { self.connectionFinished }
                if let problem = connectionError { throw BluettiNativeFailure.failed(code: "bluetooth", message: problem) }
                if connected { break }
            } catch { lastError = error }
            if let failure = failure { throw failure }
            expectingDisconnect = true
            if target.state != .disconnected {
                central.cancelPeripheralConnection(target)
                try wait(until: min(deadline, now + 1), message: "Timed out cancelling the previous connection.") { target.state == .disconnected }
            }
        }
        guard connected else { throw lastError }
        expectingDisconnect = false
        target.discoverServices([Self.serviceID])
        try wait(until: min(deadline, now + 5), message: "AC50P service discovery timed out.") { self.service != nil }
        guard let service = service else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Missing AC50P service FF00.") }
        target.discoverCharacteristics([Self.notifyID, Self.writeID], for: service)
        try wait(until: min(deadline, now + 5), message: "AC50P characteristic discovery timed out.") {
            self.notifyCharacteristic != nil && self.writeCharacteristic != nil
        }
        guard let notify = notifyCharacteristic else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Missing AC50P notification characteristic.") }
        guard notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: "AC50P characteristic FF01 cannot notify.")
        }
        target.setNotifyValue(true, for: notify)
        try wait(until: min(deadline, now + 5), message: "AC50P notification subscription timed out.") { self.notifyReady }
    }

    private func write(_ bytes: [UInt8], response: Bool) throws {
        try check()
        guard let peripheral = peripheral, let characteristic = writeCharacteristic, connected else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: "AC50P is not connected.")
        }
        let kind: CBCharacteristicWriteType = response ? .withResponse : .withoutResponse
        guard characteristic.properties.contains(response ? .write : .writeWithoutResponse) else {
            throw BluettiNativeFailure.failed(code: "bluetooth", message: response ? "ATT Write Request is unavailable." : "ATT Write Command is unavailable.")
        }
        let maximum = peripheral.maximumWriteValueLength(for: kind)
        guard maximum > 0 else { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Bluetooth reported an invalid write length.") }
        let end = min(deadline, now + 3)
        var offset = 0
        while offset < bytes.count {
            try check()
            let finish = min(bytes.count, offset + maximum)
            let part = Data(bytes[offset..<finish])
            if response {
                awaitingWrite = true
                writeFinished = false
                writeError = nil
                defer { awaitingWrite = false }
                peripheral.writeValue(part, for: characteristic, type: kind)
                try wait(until: end, message: "Bluetooth Write Request timed out.") { self.writeFinished }
                if let error = writeError { throw BluettiNativeFailure.failed(code: "bluetooth", message: "Bluetooth write failed: " + error) }
            } else {
                try wait(until: end, message: "Bluetooth write queue did not become ready.") { peripheral.canSendWriteWithoutResponse }
                peripheral.writeValue(part, for: characteristic, type: kind)
            }
            offset = finish
        }
    }

    private func nextFrame(until end: TimeInterval) throws -> BluettiFrame {
        while true {
            try check()
            if let frame = try codec.next() { return frame }
            guard now < end else { throw BluettiNativeFailure.failed(code: "timeout", message: "Timed out waiting for the AC50P reply.") }
            pump(until: min(deadline, end))
        }
    }

    private func receiveKey(_ type: UInt8, until end: TimeInterval) throws -> [UInt8] {
        while true {
            if case .keyExchange(let frame) = try nextFrame(until: end),
               try BluettiIoTProtocol.parseKeyExchange(frame).type == type { return frame }
        }
    }

    func handshake() throws {
        let challenge = try receiveKey(1, until: min(deadline, now + 8))
        let type2 = try codec.crypto.replyChallenge(challenge)
        do { try write(type2, response: true) }
        catch {
            try check()
            // Only type2 prefers ATT Write Request. Some stacks expose only
            // Write Command; preserve the upstream's bounded fallback.
            try write(type2, response: false)
        }
        let peer = try receiveKey(4, until: min(deadline, now + 5))
        let type5 = try codec.crypto.replyPeer(peer)
        try write(type5, response: false)
        let accepted: [UInt8]
        do { accepted = try receiveKey(6, until: min(deadline, now + 2.5)) }
        catch let error as BluettiNativeFailure where error.code == "timeout" {
            try check()
            // Same bytes, signature and ephemeral pair. Never regenerate type5.
            try write(type5, response: false)
            accepted = try receiveKey(6, until: min(deadline, now + 1.5))
        }
        try codec.crypto.acceptPeer(accepted)
        try write(codec.crypto.encrypt([0x01]), response: false)
        let drainEnd = min(deadline, now + 0.4)
        while now < drainEnd {
            do { _ = try nextFrame(until: drainEnd) }
            catch let error as BluettiNativeFailure where error.code == "timeout" { break }
        }
    }

    func readRegisters() throws -> [UInt16: UInt16] {
        var result: [UInt16: UInt16] = [:]
        for (address, quantity) in BluettiIoTProtocol.pollWindows {
            let command = try BluettiIoTProtocol.readHolding(address: address, quantity: quantity)
            try write(codec.crypto.encrypt(command), response: false)
            let end = min(deadline, now + 3)
            var values: [UInt16]?
            while values == nil {
                if case .application(let plain) = try nextFrame(until: end) {
                    if plain.isEmpty || plain == [0x01] { continue } // Delayed session-ping acknowledgement.
                    values = try BluettiIoTProtocol.parseHolding(plain, quantity: quantity)
                }
            }
            for (index, value) in values!.enumerated() { result[address + UInt16(index)] = value }
        }
        return result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if closing { return }
        switch central.state {
        case .poweredOn, .unknown, .resetting: break
        case .poweredOff: failure = .failed(code: "bluetooth", message: "Bluetooth is off. Turn it on in System Settings.")
        case .unauthorized: failure = .failed(code: "permission", message: "Allow Bluetooth access for BluettiBar in System Settings > Privacy & Security > Bluetooth.")
        case .unsupported: failure = .failed(code: "bluetooth", message: "This Mac does not support Bluetooth Low Energy.")
        @unknown default: failure = .failed(code: "bluetooth", message: "Bluetooth is unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closing, let rawName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.uppercased().contains("AC50P") else { return }
        let id = peripheral.identifier.uuidString.lowercased()
        discovered[id] = (peripheral, BluettiNativeDevice(id: id, name: name))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connected = true
        connectionFinished = true
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectionError = error?.localizedDescription ?? "AC50P connection failed. Close the BLUETTI phone app and try again."
        connectionFinished = true
        connected = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connected = false
        if !closing && !expectingDisconnect {
            failure = .failed(code: "bluetooth", message: error?.localizedDescription ?? "AC50P disconnected during the reading.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Service discovery failed: " + error.localizedDescription); return }
        service = peripheral.services?.first { $0.uuid == Self.serviceID }
        if service == nil { failure = .failed(code: "bluetooth", message: "AC50P service FF00 was not found.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == Self.serviceID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Characteristic discovery failed: " + error.localizedDescription); return }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == Self.notifyID }
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeID }
        if notifyCharacteristic == nil || writeCharacteristic == nil {
            failure = .failed(code: "bluetooth", message: "AC50P characteristics FF01/FF02 were not found.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.notifyID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Notifications failed: " + error.localizedDescription); return }
        notifyReady = characteristic.isNotifying
        if !notifyReady { failure = .failed(code: "bluetooth", message: "Station stopped Bluetooth notifications.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.notifyID, !closing else { return }
        if let error = error { failure = .failed(code: "bluetooth", message: "Notification read failed: " + error.localizedDescription); return }
        guard let value = characteristic.value else { return }
        do { try codec.append(Array(value)) }
        catch let error as BluettiNativeFailure { failure = error }
        catch { failure = .failed(code: "protocol", message: "Invalid station notification.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.writeID, awaitingWrite else { return }
        writeError = error?.localizedDescription
        writeFinished = true
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // The synchronous writer checks canSendWriteWithoutResponse after this
        // delegate event wakes the main RunLoop.
    }
}
