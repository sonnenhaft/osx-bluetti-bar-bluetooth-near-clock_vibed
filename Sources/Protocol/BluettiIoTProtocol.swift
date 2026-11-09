// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation
import CryptoKit
import CommonCrypto
import Security

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
