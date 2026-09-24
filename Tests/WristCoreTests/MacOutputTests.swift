import Testing
@testable import WristCore
@testable import WristMacOutput

struct MacOutputTests {
    @Test func protectedDataWillLockNotificationStopsBeforeKeyBecomesUnreadable() {
        var submitted = 0
        let wheel = SystemWheel(journal: Journal(source: "test"), permission: { true },
                                protectedData: { (true, 0) }, submit: { _ in submitted += 1; return true })
        wheel.enabled = true
        #expect(wheel.state().canScroll)
        wheel.protectionAvailable = false
        #expect(!wheel.post(points: 1))
        wheel.displayAwake = true // a screen-wake notification is not an unlock
        #expect(!wheel.state().canScroll)
        #expect(submitted == 0)
    }

    @Test func lostPermissionBetweenReceiveAndPostRevokesOldSessionEvenIfQuicklyRestored() {
        var permission = true
        var posted: [Int32] = []
        var gate = SessionGate(); gate.begin(100); let ticket = gate.issue(now: 0)
        let wheel = SystemWheel(journal: Journal(source: "test"), permission: { permission },
                                protectedData: { (true, 0) }, submit: { posted.append($0); return true })
        wheel.enabled = true
        wheel.onEligibilityLost = { gate.revoke() }
        let first = Frame(.scroll, session: 100, sequence: 1, value: 1024, ticket: ticket)
        let result = gate.accept(first, now: 0.1, targetReady: wheel.state().canScroll)
        #expect(result == nil)
        permission = false // loss after receiver check, before output's own check
        #expect(!wheel.post(points: 1))
        permission = true // restored before the next BLE timer tick
        let next = Frame(.scroll, session: 100, sequence: 2, value: 1024, ticket: ticket)
        let rejection = gate.accept(next, now: 0.2, targetReady: wheel.state().canScroll)
        #expect(rejection == "old_session")
        #expect(posted.isEmpty)
    }

    @Test func protectedDataFailureStopsWithoutPostingAndClearsFractionalIntent() {
        var readable = true
        var revoked = 0
        var posted: [Int32] = []
        let wheel = SystemWheel(journal: Journal(source: "test"), permission: { true },
                                protectedData: { (readable, readable ? 0 : -25308) },
                                submit: { posted.append($0); return true })
        wheel.enabled = true; wheel.onEligibilityLost = { revoked += 1 }
        #expect(wheel.post(points: 0.75))
        readable = false
        #expect(!wheel.post(points: 12))
        #expect(!wheel.state().canScroll)
        #expect(revoked == 1)
        readable = true
        #expect(wheel.post(points: 0.5))
        #expect(posted.isEmpty) // +0.75 from the earlier eligible state was cleared
        #expect(wheel.post(points: -1))
        #expect(posted == [-1])
    }
}
