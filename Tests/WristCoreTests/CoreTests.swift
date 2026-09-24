import Foundation
import Testing
@testable import WristCore

struct CoreTests {
    @Test func testLateAcknowledgementCannotClearDifferentSessionOrSequence() {
        let pending = Frame(.idle, session: 22, sequence: 1)
        #expect(!Frame(.rejected, session: 11, sequence: 1).acknowledges(pending))
        #expect(!Frame(.rejected, session: 22, sequence: 2).acknowledges(pending))
        #expect(!Frame(.ready, session: 22, sequence: 1).acknowledges(pending))
        #expect(Frame(.ack, session: 22, sequence: 1).acknowledges(pending))
        #expect(Frame(.rejected, session: 22, sequence: 1).acknowledges(pending))
    }

    @Test func testFrameRoundTripAndAllTruncatedPacketsFailClosed() {
        for kind in MessageKind.allCases {
            let frame = Frame(kind, session: 0xFEDCBA9876543210, sequence: 1234, value: -18203, ticket: 65535)
            expectEqual(frame.data.count, 20)
            expectEqual(Frame(data: frame.data), frame)
            for length in 0..<20 { expectNil(Frame(data: frame.data.prefix(length))) }
            expectNil(Frame(data: frame.data + Data([0])))
        }
        var bytes = Frame(.scroll).data; bytes[0] = 99; expectNil(Frame(data: bytes))
        bytes[0] = 1; bytes[1] = 99; expectNil(Frame(data: bytes))
    }

    @Test func testCrownWrapBothDirectionsAndImmediateReverse() {
        var crown = CrownDelta(); crown.rebase(to: 999.9)
        expectEqual(crown.update(-999.9)!, 0.2, accuracy: 1e-9)
        expectEqual(crown.update(999.8)!, -0.3, accuracy: 1e-9)
        expectEqual(crown.update(999.79)!, -0.01, accuracy: 1e-9)
    }

    @Test func testCrownFocusResetDiscontinuityAndNonfinite() {
        var crown = CrownDelta(); crown.rebase(to: 7)
        expectNil(crown.update(0))
        expectEqual(crown.update(0.01)!, 0.01, accuracy: 1e-12)
        crown.rebase(to: 0.01)
        expectEqual(crown.update(0.02)!, 0.01, accuracy: 1e-12)
        for value in [Double.nan, .infinity, -.infinity, 1001] {
            expectNil(crown.update(value)); expectNil(crown.update(0))
        }
    }

    @Test func testFractionalMappingConservesDistanceAndReverses() {
        var mapping = LinearScroll(); var total: Int64 = 0
        for _ in 0..<1000 { total += Int64(mapping.convert(delta: 0.00001)!) }
        expectEqual(Double(total) / LinearScroll.scale, 1.8, accuracy: 1 / LinearScroll.scale)
        let reverse = mapping.convert(delta: -0.01)!
        expectLessThan(reverse, 0)
        expectNil(mapping.convert(delta: .nan)); expectNil(mapping.convert(delta: 5))
    }

    @Test func testQueueDropsExpiredMovementAndNeverDrainsAfterIdleOrDisconnect() {
        var buffer = ScrollBuffer()
        buffer.add(100, now: 0); expectNil(buffer.take(now: 0.081))
        buffer.add(100, now: 1); buffer.add(-1, now: 1.01)
        expectEqual(buffer.take(now: 1.02), -1)
        buffer.add(100, now: 2); buffer.clear(); expectNil(buffer.take(now: 2.01))
        buffer.add(100, now: 3); buffer.add(20, now: 3.09)
        expectEqual(buffer.take(now: 3.10), 20)
        buffer.add(Int32.max, now: 4); expectEqual(buffer.take(now: 4), 737_280)
    }

    @Test func testReceiverRejectsDuplicateOldSessionExpiredAndUnavailableTarget() {
        var gate = SessionGate(); gate.begin(123)
        let ticket = gate.issue(now: 10)
        let frame = Frame(.idle, session: 123, sequence: 1, ticket: ticket)
        expectNil(gate.accept(frame, now: 10.1, targetReady: true))
        expectEqual(gate.accept(frame, now: 10.11, targetReady: true), "duplicate_or_reordered")
        let next = Frame(.scroll, session: 123, sequence: 2, value: -100, ticket: ticket)
        expectEqual(gate.accept(next, now: 10.36, targetReady: true), "expired_ticket")
        expectEqual(gate.lastSequence, 1)
        expectEqual(gate.accept(next, now: 10.2, targetReady: false), "target_unavailable")
        gate.begin(456)
        expectEqual(gate.accept(next, now: 10.2, targetReady: true), "old_session")
        gate.revoke()
        expectEqual(gate.accept(Frame(.idle, sequence: 1), now: 10, targetReady: true), "old_session")
    }

    @Test func testReceiverRejectsImpossibleAmountsAndCapabilitiesWithoutConsumingSequence() {
        var gate = SessionGate(); gate.begin(1); let ticket = gate.issue(now: 0)
        expectEqual(gate.accept(Frame(.scroll, session: 1, sequence: 1, value: Int32.min, ticket: ticket),
                                   now: 0, targetReady: true), "oversized_scroll")
        expectEqual(gate.accept(Frame(.hello, session: 1, sequence: 1, ticket: ticket), now: 0, targetReady: true), "invalid_action")
        expectEqual(gate.accept(Frame(.idle, session: 1, sequence: 1, value: 1, ticket: ticket), now: 0, targetReady: true), "invalid_value")
        expectEqual(gate.lastSequence, 0)
    }

    @Test func testReceiverTicketUsesOnlyMacClockAndExpiresThroughNewIssues() {
        var gate = SessionGate(); gate.begin(1); let old = gate.issue(now: 100)
        for time in [100.15, 100.30, 100.45] { _ = gate.issue(now: time) }
        expectEqual(gate.accept(Frame(.scroll, session: 1, sequence: 1, value: 1, ticket: old),
                                   now: 100.45, targetReady: true), "expired_ticket")
        expectNil(gate.accept(Frame(.scroll, session: 1, sequence: 2, value: -1, ticket: gate.currentTicket),
                                 now: 100.46, targetReady: true))
    }

    @Test func testDiagnosticTransferRejectsMissingDuplicateAndWrongSessionChunks() {
        var assembler = DiagnosticAssembler(session: 99)
        let first = DiagnosticChunk(session: 99, index: 0, final: false, payload: Data("abc".utf8))
        expectEqual(DiagnosticChunk(data: first.data)?.payload, first.payload)
        expectFalse(assembler.append(DiagnosticChunk(session: 99, index: 1, final: false, payload: Data())))
        expectTrue(assembler.append(first)); expectFalse(assembler.append(first))
        expectFalse(assembler.append(DiagnosticChunk(session: 100, index: 1, final: true, payload: Data())))
        expectTrue(assembler.append(DiagnosticChunk(session: 99, index: 1, final: true, payload: Data("def".utf8))))
        expectTrue(assembler.complete); expectEqual(String(data: assembler.bytes, encoding: .utf8), "abcdef")
        expectFalse(assembler.append(DiagnosticChunk(session: 99, index: 2, final: true, payload: Data())))
    }

    @Test func testDiagnosticsAreBoundedAndValidJSON() throws {
        let journal = Journal(source: "test")
        for _ in 0..<5000 { journal.record("input") }
        expectLessThanOrEqual(journal.events.count, Journal.capacity)
        expectGreaterThan(journal.discarded, 0)
        _ = try JSONSerialization.jsonObject(with: journal.snapshot())
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs == rhs, sourceLocation: sourceLocation)
}
private func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(lhs - rhs) <= accuracy, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func expectLessThan<T: Comparable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs < rhs, sourceLocation: sourceLocation)
}
private func expectLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs <= rhs, sourceLocation: sourceLocation)
}
private func expectGreaterThan<T: Comparable>(_ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs > rhs, sourceLocation: sourceLocation)
}
