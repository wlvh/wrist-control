import Foundation
import Testing
@testable import WristCore

struct PointerWireTests {
    @Test func authenticatedClientBuildHasFixedValidatedRevisionBytes() throws {
        let sha = String(repeating: "ab", count: 20)
        let value = PointerWire(frame: Frame(.clientInfo, session: 1, sequence: 1, value: 4), revision: sha)
        let decoded = try #require(PointerWire(data: value.data))
        #expect(decoded.revision == sha && decoded.frame.value == 4 && value.data.count == 40)
        for count in 0..<40 { #expect(PointerWire(data: value.data.prefix(count)) == nil) }
        #expect(PointerWire(frame: value.frame, revision: String(repeating: "😀", count: 10)).data.isEmpty)
        #expect(PointerWire(frame: value.frame, revision: String(repeating: "g", count: 40)).data.isEmpty)
    }
    @Test func rejectedStopDoesNotEatPendingTotalPauseAndOldStatusCannotResumeIt() {
        var live = WatchIntentState(); live.cycle = 7; live.phase = .paused; live.desiredControl = false
        live.reject(kind: .stopMovement, actionCycle: 6, controlEnabled: true)
        live.confirm(cycle: 7, phase: .moving)
        #expect(live.desiredControl == false && live.phase == .paused)
    }
    @Test func rejectedCurrentStartReturnsToReadingButPreservesNewerIntent() {
        var live = WatchIntentState(); live.cycle = 7; live.phase = .preparing
        live.reject(kind: .startMovement, actionCycle: 7, controlEnabled: true)
        #expect(live.cycle == 7 && live.phase == .reading)
        live.cycle = 8; live.phase = .preparing
        live.reject(kind: .startMovement, actionCycle: 7, controlEnabled: true)
        live.confirm(cycle: 7, phase: .reading)
        #expect(live.cycle == 8 && live.phase == .preparing)
    }
    @Test func poseRoundTripAndEveryTruncationRejects() throws {
        let sample = AttitudeSample(referenceID: 8, sequence: 4, watchTime: 123.5,
            attitude: .rotation(axis: SIMD3(0, 0, 1), radians: 0.2))
        let wire = PointerWire(frame: Frame(.pose, session: 9, sequence: 44, ticket: 7), cycle: 12, sample: sample, sourceAge: 0.023)
        #expect(wire.data.count == 61)
        let result = try #require(PointerWire(data: wire.data))
        #expect(result.cycle == 12 && result.frame.sequence == 44 && result.sample?.referenceID == 8)
        #expect(result.sourceAge == 0.023)
        #expect(result.sample!.attitude.angularDistance(to: sample.attitude) < 1e-6)
        for count in 0..<wire.data.count { #expect(PointerWire(data: wire.data.prefix(count)) == nil) }
        var wrongVersion = wire.data; wrongVersion[0] = 2
        #expect(PointerWire(data: wrongVersion) == nil)
        #expect(PointerWire(frame: wire.frame, cycle: 12, sample: sample, sourceAge: .nan).data.isEmpty)
    }
    @Test func clickAndControlCarryIndependentCycleAndValue() throws {
        let click = ClickRequest(id: 91, button: .left, watchTime: 15.125, cycle: 6)
        let wire = PointerWire(frame: Frame(.leftClick, session: 5, sequence: 10), cycle: 6, click: click)
        #expect(try #require(PointerWire(data: wire.data)).click == click)
        for kind: MessageKind in [.scroll, .setMode, .setSensitivity, .mainPage] {
            let body = PointerWire(frame: Frame(kind, session: 5, sequence: 11, value: 3), cycle: 9)
            let result = try #require(PointerWire(data: body.data))
            #expect(result.frame.value == 3 && result.cycle == 9)
        }
        let frame = Frame(.ready, session: 5, value: ControlState.ready.rawValue)
        let status = PointerStatus(frame: frame, cycle: 9, phase: .moving, mode: .b, scope: .practice, doubleClickInterval: 0.5)
        let decoded = try #require(PointerStatus(data: status.data))
        #expect(decoded.cycle == 9 && decoded.mode == .b && decoded.phase == .moving && decoded.doubleClickInterval == 0.5)
    }
    @Test func posePermitIsShorterAndSafetyControlsRemainReachableWhilePaused() {
        var gate = SessionGate(); gate.begin(5)
        let ticket = gate.issue(now: 10)
        let pose = Frame(.pose, session: 5, sequence: 1, value: 1, ticket: ticket)
        let rejected = gate.accept(pose, now: 10.2, targetReady: true, maxAge: MotionLimits.streamTimeout)
        #expect(rejected == "expired_ticket")
        let stop = Frame(.stopMovement, session: 5, sequence: 2, value: 2, ticket: ticket)
        let stopped = gate.accept(stop, now: 10.2, targetReady: false)
        #expect(stopped == nil)
        let replay = gate.accept(stop, now: 10.21, targetReady: false)
        #expect(replay == "duplicate_or_reordered")
    }
}
