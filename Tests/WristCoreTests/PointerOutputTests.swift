import Testing
@testable import WristCore
@testable import WristMacOutput

/// Exercises the actual output and coordinator classes. Closures below only
/// capture submissions or supply environmental state; they do not remap motion
/// or implement a replacement click state machine. No native events are posted.
struct PointerOutputTests {
    let point = PointerPoint(x: 200, y: 300)
    let screen = PointerScreen(displayID: 1, layoutID: 9, width: 800, height: 600, backingScale: 2)
    func request(_ id: UInt64, watch: Double, button: PointerButton = .left, cycle: UInt32 = 1) -> ClickRequest {
        ClickRequest(id: id, button: button, watchTime: watch, cycle: cycle)
    }
    func control(_ kind: MessageKind, cycle: UInt32, session: UInt64 = 42, value: Int32 = 0,
                 click: ClickRequest? = nil, age: Double = 0) -> PointerWire {
        PointerWire(frame: Frame(kind, session: session, sequence: cycle, value: value), cycle: cycle, click: click, sourceAge: age)
    }
    func pose(sequence: UInt32, watch: Double, heading: Double = 0, cycle: UInt32 = 1,
              session: UInt64 = 42, reference: UInt64 = 100, age: Double = 0) -> PointerWire {
        PointerWire(frame: Frame(.pose, session: session, sequence: sequence), cycle: cycle,
            sample: AttitudeSample(referenceID: reference, sequence: sequence, watchTime: watch,
                attitude: .rotation(axis: SIMD3(0, 0, 1), radians: -heading)), sourceAge: age)
    }
    func coordinator() -> PointerCoordinator {
        let value = PointerCoordinator(journal: Journal(source: "pointer-output-test"))
        value.allowed = { true }; value.cursor = { point }; value.screenAt = { _ in screen }
        value.newSession(42, enabled: true)
        return value
    }
    func prepare(_ coordinator: PointerCoordinator, cycle: UInt32 = 1, sequenceBase: UInt32 = 0,
                 now: Double = 10, watch: Double = 100) throws {
        let started = coordinator.handle(control(.startMovement, cycle: cycle), now: now)
        try #require(started)
        for (index, offset) in [0.13, 0.17, 0.21].enumerated() {
            let received = coordinator.handle(pose(sequence: sequenceBase + UInt32(index) + 1, watch: watch + offset, cycle: cycle), now: now + offset)
            try #require(received)
        }
        try #require(coordinator.lease.phase == .moving)
    }
    @Test func firstClickPostsImmediatelyAndSecondAddsExactlyOnePair() {
        var events: [SystemPointer.Event] = []
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { true }, interval: { 0.5 }, cursor: { point }, submit: { events.append($0); return true })
        pointer.reset(session: 42)
        #expect(pointer.click(request(1, watch: 10), session: 42, at: point, now: 100))
        #expect(events == [.down(.left, point, 1), .up(.left, point, 1)])
        #expect(pointer.click(request(2, watch: 10.2), session: 42, at: point, now: 100.2))
        #expect(events == [.down(.left, point, 1), .up(.left, point, 1), .down(.left, point, 2), .up(.left, point, 2)])
        #expect(!pointer.click(request(2, watch: 10.2), session: 42, at: point, now: 100.3))
        #expect(events.count == 4 && pointer.clickPosts == 2)
    }
    @Test func delayedTransportPositionChangeAndRightClickBreakDoubleClickPair() {
        var events: [SystemPointer.Event] = []
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { true }, interval: { 0.5 }, cursor: { point }, submit: { events.append($0); return true })
        pointer.reset(session: 42)
        _ = pointer.click(request(1, watch: 1), session: 42, at: point, now: 10)
        _ = pointer.click(request(2, watch: 1.2), session: 42, at: point, now: 10.8) // Watch interval alone is insufficient.
        let shifted = point + PointerPoint(x: 1, y: 0)
        _ = pointer.click(request(3, watch: 1.4), session: 42, at: shifted, now: 11)
        _ = pointer.click(request(4, watch: 1.5, button: .right), session: 42, at: shifted, now: 11.1)
        _ = pointer.click(request(5, watch: 1.6), session: 42, at: shifted, now: 11.2)
        #expect(events == [
            .down(.left, point, 1), .up(.left, point, 1), .down(.left, point, 1), .up(.left, point, 1),
            .down(.left, shifted, 1), .up(.left, shifted, 1), .down(.right, shifted, 1), .up(.right, shifted, 1),
            .down(.left, shifted, 1), .up(.left, shifted, 1)])
    }
    @Test func rejectedFirstClickCannotSeedASecondClickAfterPermissionReturns() {
        var allowed = false
        var events: [SystemPointer.Event] = []
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { allowed }, interval: { 0.5 }, cursor: { point }, submit: { events.append($0); return true })
        pointer.reset(session: 42)
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10))
        allowed = true
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10.1)) // refused ID is still consumed
        #expect(pointer.click(request(2, watch: 1.2), session: 42, at: point, now: 10.2))
        #expect(events == [.down(.left, point, 1), .up(.left, point, 1)])
    }
    @Test func permissionLossAfterDownStillAttemptsExactlyOneMatchingRelease() {
        var allowed = true
        var events: [SystemPointer.Event] = []
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { allowed }, interval: { 0.5 }, cursor: { point }, submit: { event in
            events.append(event); if case .down = event { allowed = false }; return true
        })
        pointer.reset(session: 42)
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10))
        #expect(events == [.down(.left, point, 1), .up(.left, point, 1)])
        #expect(!pointer.move(to: point + PointerPoint(x: 5)))
        #expect(!pointer.click(request(2, watch: 1.1), session: 42, at: point, now: 10.1))
        allowed = true
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10.2))
        #expect(events.count == 2)
    }
    @Test func rejectedDownAndFailedReleaseAreNeverRetriedAsDuplicateClicks() {
        var events: [SystemPointer.Event] = []
        var rejectDown = true
        var rejectUp = false
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { true }, interval: { 0.5 }, cursor: { point }, submit: { event in
            events.append(event)
            switch event { case .down: return !rejectDown; case .up: return !rejectUp; case .move: return true }
        })
        pointer.reset(session: 42)
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10))
        rejectDown = false
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10.1))
        rejectUp = true
        #expect(!pointer.click(request(2, watch: 1.2), session: 42, at: point, now: 10.2))
        #expect(!pointer.click(request(2, watch: 1.2), session: 42, at: point, now: 10.3))
        #expect(events == [.down(.left, point, 1), .down(.left, point, 1), .up(.left, point, 1)])
        rejectUp = false
        #expect(pointer.click(request(3, watch: 1.4), session: 42, at: point, now: 10.4))
        #expect(events.suffix(2) == [.down(.left, point, 1), .up(.left, point, 1)])
    }
    @Test func outputGateBlocksMovesAndOldSessionClicks() {
        var eligible = false
        var events: [SystemPointer.Event] = []
        let pointer = SystemPointer(journal: Journal(source: "test"), eligible: { eligible }, interval: { 0.5 }, cursor: { point }, submit: { events.append($0); return true })
        pointer.reset(session: 42)
        #expect(!pointer.move(to: point))
        eligible = true
        #expect(!pointer.move(to: PointerPoint(x: .nan)))
        #expect(pointer.move(to: point))
        pointer.reset(session: 43)
        #expect(!pointer.click(request(1, watch: 1), session: 42, at: point, now: 10))
        #expect(events == [.move(point)])
    }
    @Test func beginDoesNotJumpAndStoppedCycleCannotMoveOrReopen() throws {
        let value = coordinator()
        var moves: [PointerPoint] = []; value.onMove = { p, _ in moves.append(p); return true }
        try prepare(value); #expect(moves.isEmpty)
        #expect(value.handle(pose(sequence: 4, watch: 100.25, heading: 0.02), now: 10.25))
        #expect(moves.count == 1)
        #expect(value.handle(control(.stopMovement, cycle: 2), now: 10.26))
        #expect(!value.handle(pose(sequence: 5, watch: 100.29, heading: 0.03), now: 10.29))
        #expect(!value.handle(control(.startMovement, cycle: 1), now: 10.30))
        #expect(value.lease.phase == .reading && moves.count == 1)
        try prepare(value, cycle: 3, sequenceBase: 5, now: 11, watch: 101)
        #expect(moves.count == 1)
    }
    @Test func clickFreezesBeforeSubmittingAndLateMotionCannotChangeFrozenPoint() throws {
        let value = coordinator()
        var actualPoint = point
        var trace: [String] = []; var clicked: [PointerPoint] = []
        value.cursor = { actualPoint }
        value.onMove = { p, _ in actualPoint = p; trace.append("move"); return true }
        value.onFreeze = { trace.append("freeze") }
        value.onClick = { _, _, p, _, _ in clicked.append(p); trace.append("click"); return true }
        try prepare(value)
        #expect(value.handle(pose(sequence: 4, watch: 100.25, heading: 0.03), now: 10.25))
        let frozen = actualPoint; trace.removeAll()
        let click = request(1, watch: 100.26, cycle: 2)
        #expect(value.handle(control(.leftClick, cycle: 2, click: click), now: 10.26))
        #expect(trace == ["freeze", "click"] && clicked == [frozen])
        #expect(!value.handle(pose(sequence: 5, watch: 100.29, heading: 0.05), now: 10.29))
        #expect(actualPoint == frozen && clicked == [frozen] && value.lease.phase == .reading)
    }
    @Test func duplicateAndReconnectReplayClicksNeverReachOutput() {
        let value = coordinator(); var clicks = 0
        value.onClick = { _, _, _, _, _ in clicks += 1; return true }
        let first = control(.leftClick, cycle: 1, click: request(1, watch: 1, cycle: 1))
        #expect(value.handle(first, now: 10)); #expect(!value.handle(first, now: 10.1))
        value.newSession(43, enabled: true)
        #expect(!value.handle(first, now: 10.2))
        #expect(clicks == 1)
        let current = control(.leftClick, cycle: 1, session: 43, click: request(1, watch: 2, cycle: 1))
        #expect(value.handle(current, now: 11)); #expect(clicks == 2)
    }
    @Test func isolationTagsOnlyPracticeOutputsAndCalibrationBlindOnlyReceiveSamples() throws {
        let value = coordinator()
        var moveScopes: [OutputScope] = [], clickScopes: [OutputScope] = [], wheelScopes: [OutputScope] = []
        var samples = 0
        value.onMove = { _, scope in moveScopes.append(scope); return true }
        value.onClick = { _, _, _, _, scope in clickScopes.append(scope); return true }
        value.onWheel = { _, scope in wheelScopes.append(scope); return true }
        value.onSample = { _, _ in samples += 1 }
        value.setScope(.practice, screen: screen); try prepare(value)
        #expect(value.handle(pose(sequence: 4, watch: 100.25, heading: 0.02), now: 10.25))
        #expect(value.handle(control(.leftClick, cycle: 2, click: request(1, watch: 100.26, cycle: 2)), now: 10.26))
        #expect(moveScopes == [.practice] && clickScopes == [.practice])
        value.setScope(.calibration, screen: screen)
        #expect(!value.handle(control(.startMovement, cycle: 3), now: 10.3))
        #expect(value.handle(pose(sequence: 5, watch: 100.33, cycle: 3), now: 10.33))
        #expect(!value.handle(control(.leftClick, cycle: 4, click: request(2, watch: 100.34, cycle: 4)), now: 10.34))
        value.setScope(.blindValidation, screen: screen)
        #expect(!value.handle(control(.startMovement, cycle: 5), now: 10.4))
        #expect(value.handle(pose(sequence: 6, watch: 100.45, cycle: 5), now: 10.45))
        #expect(value.handle(control(.scroll, cycle: 6, value: 1024), now: 10.46))
        #expect(wheelScopes == [.blindValidation]) // caller receives the isolation tag; no native output here
        #expect(!moveScopes.contains(.system) && !clickScopes.contains(.system) && samples == 6)
    }
    @Test func screenEdgeDiscardsOvershootBeforeReversal() throws {
        let value = coordinator()
        var actual = PointerPoint(x: 798, y: 300)
        value.cursor = { actual }; value.onMove = { p, _ in actual = p; return true }
        try prepare(value)
        #expect(value.handle(pose(sequence: 4, watch: 100.25, heading: 0.1), now: 10.25))
        #expect(actual.x == 799)
        #expect(value.handle(pose(sequence: 5, watch: 100.29, heading: 0.09), now: 10.29))
        #expect(abs(actual.x - 783) < 1e-7)
    }
    @Test func streamTimeoutEligibilityLossAndSettingsNeverResumeOldMovement() throws {
        let value = coordinator(); var allowed = true, moves = 0, wheels = 0
        value.allowed = { allowed }; value.onMove = { _, _ in moves += 1; return true }; value.onWheel = { _, _ in wheels += 1; return true }
        try prepare(value)
        value.tick(now: 10.5)
        #expect(value.lease.phase == .reading)
        #expect(!value.handle(pose(sequence: 4, watch: 100.54, heading: 0.1), now: 10.54))
        try prepare(value, cycle: 2, sequenceBase: 4, now: 11, watch: 101)
        allowed = false; value.tick(now: 11.22); allowed = true
        #expect(!value.handle(pose(sequence: 8, watch: 101.25, heading: 0.1, cycle: 2), now: 11.25))
        #expect(value.handle(control(.mainPage, cycle: 3, value: 0), now: 11.3))
        #expect(!value.handle(control(.scroll, cycle: 4, value: 1024), now: 11.4))
        #expect(!value.handle(control(.startMovement, cycle: 5), now: 11.5))
        #expect(value.handle(control(.mainPage, cycle: 6, value: 1), now: 11.6))
        #expect(value.lease.phase == .reading && moves == 0 && wheels == 0)
    }
    @Test func oldOrInvalidSampleAgeCannotReachNativeOutput() throws {
        let value = coordinator(); var moves = 0, clicks = 0
        value.onMove = { _, _ in moves += 1; return true }; value.onClick = { _, _, _, _, _ in clicks += 1; return true }
        try prepare(value)
        #expect(!value.handle(pose(sequence: 4, watch: 100.25, heading: 0.1, age: 0.2), now: 10.25))
        #expect(value.lease.phase == .reading)
        #expect(!value.handle(control(.leftClick, cycle: 2, click: request(1, watch: 100.3, cycle: 2), age: 0.3), now: 10.3))
        #expect(moves == 0 && clicks == 0)
    }
}
