import Foundation
import CryptoKit

/// One development-installed, random 256-bit secret per device pair. Both sides
/// prove possession over fresh nonces; the secret never crosses the BLE link.
public enum PairAuthentication {
    public static let tagSize = 32
    public static let handshakeSize = Frame.size + tagSize
    private static let context = Data("WristControl-v2/".utf8)

    public static func nonce(_ kind: MessageKind) -> Frame {
        Frame(kind, session: UInt64.random(in: 1...UInt64.max),
              sequence: .random(in: .min ... .max), value: .random(in: .min ... .max),
              ticket: .random(in: .min ... .max))
    }

    private static func transcript(_ domain: String, hello: Frame, challenge: Frame, body: Data = Data()) -> Data {
        context + Data(domain.utf8) + hello.data + challenge.data + body
    }

    public static func challengePacket(secret: SymmetricKey, hello: Frame, challenge: Frame) -> Data {
        challenge.data + Data(HMAC<SHA256>.authenticationCode(
            for: transcript("server", hello: hello, challenge: challenge), using: secret))
    }

    public static func verifiedChallenge(_ packet: Data, secret: SymmetricKey, hello: Frame) -> Frame? {
        guard packet.count == handshakeSize, hello.kind == .hello,
              let challenge = Frame(data: packet.prefix(Frame.size)),
              challenge.kind == .challenge, challenge.session != 0,
              HMAC<SHA256>.isValidAuthenticationCode(packet.suffix(tagSize),
                authenticating: transcript("server", hello: hello, challenge: challenge), using: secret) else { return nil }
        return challenge
    }

    public static func proofPacket(secret: SymmetricKey, hello: Frame, challenge: Frame) -> Data {
        let proof = Frame(.authenticate, session: challenge.session)
        return proof.data + Data(HMAC<SHA256>.authenticationCode(
            for: transcript("client", hello: hello, challenge: challenge, body: proof.data), using: secret))
    }

    public static func verifyProof(_ packet: Data, secret: SymmetricKey, hello: Frame, challenge: Frame) -> Bool {
        let proof = Frame(.authenticate, session: challenge.session)
        guard packet.count == handshakeSize, packet.prefix(Frame.size) == proof.data else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(packet.suffix(tagSize),
            authenticating: transcript("client", hello: hello, challenge: challenge, body: proof.data), using: secret)
    }

    public static func sessionKey(secret: SymmetricKey, hello: Frame, challenge: Frame) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: hello.data + challenge.data,
                              info: context + Data("session".utf8), outputByteCount: 32)
    }
}

/// Counters protect both directions, including ready/paused status, from replay.
/// Direction and characteristic are authenticated so packets cannot be reflected
/// or moved from diagnostics to input. Gaps are allowed; old counters are not.
public struct AuthenticatedLink {
    public enum Role { case mac, watch }
    public enum Purpose: String { case input, status, diagnostic }
    public static let overhead = 8 + PairAuthentication.tagSize
    public static let frameSize = Frame.size + overhead
    private let key: SymmetricKey
    private let role: Role
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    public init(key: SymmetricKey, role: Role) { self.key = key; self.role = role }

    private func signedBytes(_ packetBody: Data, purpose: Purpose, fromMac: Bool) -> Data {
        Data("WristControl-v2/\(fromMac ? "mac" : "watch")/\(purpose.rawValue)/".utf8) + packetBody
    }

    public mutating func seal(_ payload: Data, purpose: Purpose) -> Data? {
        guard sent < UInt64.max else { return nil }
        sent += 1
        var bytes: [UInt8] = []; appendLE(sent, to: &bytes)
        let body = Data(bytes) + payload
        return body + Data(HMAC<SHA256>.authenticationCode(
            for: signedBytes(body, purpose: purpose, fromMac: role == .mac), using: key))
    }

    public mutating func open(_ packet: Data, purpose: Purpose) -> Data? {
        guard packet.count > Self.overhead else { return nil }
        let body = packet.dropLast(PairAuthentication.tagSize)
        guard HMAC<SHA256>.isValidAuthenticationCode(packet.suffix(PairAuthentication.tagSize),
            authenticating: signedBytes(Data(body), purpose: purpose, fromMac: role != .mac), using: key) else { return nil }
        let counter = readLE(Array(body.prefix(8)), at: 0, count: 8)
        guard counter > received else { return nil }
        received = counter
        return Data(body.dropFirst(8))
    }
}
