import Foundation
import CryptoKit
import Testing
@testable import WristCore

struct SystemWheelTests {
    private let secret = SymmetricKey(data: Data(repeating: 0x45, count: 32))
    private let hello = Frame(.hello, session: 12, sequence: 34, value: -56, ticket: 78)
    private let challenge = Frame(.challenge, session: 91, sequence: 23, value: 45, ticket: 67)

    @Test func mutualProofBindsBothNoncesAndRoles() {
        let server = PairAuthentication.challengePacket(secret: secret, hello: hello, challenge: challenge)
        #expect(PairAuthentication.verifiedChallenge(server, secret: secret, hello: hello) == challenge)
        let client = PairAuthentication.proofPacket(secret: secret, hello: hello, challenge: challenge)
        #expect(PairAuthentication.verifyProof(client, secret: secret, hello: hello, challenge: challenge))
        let wrong = SymmetricKey(data: Data(repeating: 0x46, count: 32))
        #expect(PairAuthentication.verifiedChallenge(server, secret: wrong, hello: hello) == nil)
        #expect(!PairAuthentication.verifyProof(client, secret: wrong, hello: hello, challenge: challenge))
        #expect(!PairAuthentication.verifyProof(server, secret: secret, hello: hello, challenge: challenge))
        #expect(PairAuthentication.verifiedChallenge(client, secret: secret, hello: hello) == nil)
        #expect(PairAuthentication.verifiedChallenge(server, secret: secret, hello: Frame(.hello, session: 99)) == nil)
        #expect(!PairAuthentication.verifyProof(client, secret: secret, hello: hello, challenge: Frame(.challenge, session: 99)))
        for index in server.indices {
            var altered = server; altered[index] ^= 1
            #expect(PairAuthentication.verifiedChallenge(altered, secret: secret, hello: hello) == nil)
        }
    }

    @Test func packetAuthenticationRejectsTamperTruncationReflectionAndWrongCharacteristic() throws {
        let key = PairAuthentication.sessionKey(secret: secret, hello: hello, challenge: challenge)
        var watch = AuthenticatedLink(key: key, role: .watch)
        let body = Frame(.scroll, session: 23, sequence: 1, value: -100, ticket: 1).data
        let sealed = watch.seal(body, purpose: .input)
        let packet = try #require(sealed)
        #expect(packet.count == 60)
        for length in 0..<packet.count {
            var mac = AuthenticatedLink(key: key, role: .mac)
            #expect(mac.open(packet.prefix(length), purpose: .input) == nil)
        }
        for index in packet.indices {
            var mac = AuthenticatedLink(key: key, role: .mac)
            var altered = packet; altered[index] ^= 1
            #expect(mac.open(altered, purpose: .input) == nil)
            #expect(mac.open(packet, purpose: .input) == body) // invalid packets don't consume counters
        }
        var mac = AuthenticatedLink(key: key, role: .mac)
        #expect(mac.open(packet, purpose: .diagnostic) == nil)
        #expect(mac.open(body, purpose: .input) == nil) // raw actions never authenticate
        #expect(watch.open(packet, purpose: .input) == nil)
        #expect(mac.open(packet, purpose: .input) == body)
        #expect(mac.open(packet, purpose: .input) == nil)
    }

    @Test func replayedReadyCannotUndoPauseAndReconnectRejectsOldTransport() throws {
        let key = PairAuthentication.sessionKey(secret: secret, hello: hello, challenge: challenge)
        var mac = AuthenticatedLink(key: key, role: .mac)
        var watch = AuthenticatedLink(key: key, role: .watch)
        let readyPacket = mac.seal(Frame(.ready, session: 1, value: 7).data, purpose: .status)
        let ready = try #require(readyPacket)
        let pausedPacket = mac.seal(Frame(.ready, session: 2, value: 6).data, purpose: .status)
        let paused = try #require(pausedPacket)
        #expect(watch.open(paused, purpose: .status) != nil)
        #expect(watch.open(ready, purpose: .status) == nil)
        #expect(watch.open(paused, purpose: .status) == nil)
        let newKey = PairAuthentication.sessionKey(secret: secret, hello: Frame(.hello, session: 999), challenge: challenge)
        var next = AuthenticatedLink(key: newKey, role: .watch)
        #expect(next.open(paused, purpose: .status) == nil)
    }

    @Test func controlRequestIsExplicitIdempotentAndStillRequiresFreshSessionTicket() {
        var gate = SessionGate(); gate.begin(1); let ticket = gate.issue(now: 10)
        let pause = Frame(.setControl, session: 1, sequence: 1, value: 0, ticket: ticket)
        #expect(gate.accept(pause, now: 10.1, targetReady: false) == nil)
        #expect(gate.accept(pause, now: 10.1, targetReady: false) == "duplicate_or_reordered")
        #expect(gate.accept(Frame(.setControl, session: 1, sequence: 2, value: 2, ticket: ticket), now: 10.1, targetReady: false) == "invalid_value")
        #expect(gate.accept(Frame(.setControl, session: 1, sequence: 2, value: 1, ticket: ticket), now: 11, targetReady: false) == "expired_ticket")
        #expect(gate.accept(Frame(.scroll, session: 1, sequence: 2, value: 100, ticket: ticket), now: 10.1, targetReady: false) == "target_unavailable")
        #expect(gate.accept(Frame(.mark, session: 1, sequence: 2, ticket: ticket), now: 10.1, targetReady: true) == "invalid_action")
        gate.begin(2)
        #expect(gate.accept(pause, now: 10.1, targetReady: false) == "old_session")
    }

    @Test func subpixelWheelMovementIsConservedAndNeverCarriedAcrossBoundaries() {
        var wheel = WheelAccumulator()
        var total: Int32 = 0
        for _ in 0..<100 { total += wheel.consume(points: 0.125)! }
        #expect(total == 12)
        #expect(wheel.consume(points: -1) == -1) // old +0.5 cannot delay reversal
        #expect(wheel.consume(points: -0.5) == 0)
        wheel.reset() // idle, pause, lock, permission revocation, new session
        #expect(wheel.consume(points: -0.5) == 0)
        #expect(wheel.consume(points: -0.5) == -1)
        #expect(wheel.consume(points: .nan) == nil)
        #expect(wheel.consume(points: .infinity) == nil)
        #expect(wheel.consume(points: 721) == nil)
        #expect(wheel.consume(points: -720) == -720)
    }

    @Test func outputRequiresEveryPermissionAndUserCondition() {
        for value: Int32 in 0..<7 { #expect(!ControlState(rawValue: value).canScroll) }
        #expect(ControlState.ready.canScroll)
    }
}
