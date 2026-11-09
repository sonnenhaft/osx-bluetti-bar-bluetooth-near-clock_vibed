// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation

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
