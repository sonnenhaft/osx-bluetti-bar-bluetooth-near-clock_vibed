// AC50P protocol adapted from rustytti 0.1.1: https://gitlab.com/spock/rustytti
// Upstream notice: THIRD_PARTY_NOTICES.txt. Crypto uses Apple's system libraries.
import Foundation
import CryptoKit

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
