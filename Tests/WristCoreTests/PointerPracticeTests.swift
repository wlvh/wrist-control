import Foundation
import Testing
@testable import WristCore

struct PointerPracticeTests {
    @Test func actualReferenceCanFillAnUnknownRunButCannotRelabelItLater() throws {
        var value = try run()
        let first = value.bindReference(88), repeated = value.bindReference(88), changed = value.bindReference(89)
        #expect(first && repeated && !changed)
        #expect(value.result.configuration.metadata.referenceID == 88)
        #expect(value.result.configuration.source == .a && value.result.configuration.seed == 42)
    }
    let screen = PointerScreen(displayID: 1, layoutID: 7, origin: PointerPoint(x: -1440, y: 80), width: 1440, height: 900, backingScale: 2)
    var region: PracticeRegion { PracticeRegion(origin: PointerPoint(x: -1400, y: 140), width: 1360, height: 760) }
    var target: PracticeTarget { PracticeTarget(id: 1, center: PointerPoint(x: -750, y: 400), diameter: 48) }
    func run(targets: [PracticeTarget]? = nil, stage: PracticeStage = .formal) throws -> PointerPracticeRun {
        try PointerPracticeRun(configuration: PracticeConfiguration(screen: screen, region: region,
            source: .a, stage: stage, seed: 42, sessionIndex: 1, timeoutSeconds: 30), targets: targets ?? [target])
    }
    @Test func deterministicBalancedTargetsStayInsideLogicalRegion() throws {
        let a = try PointerPracticeSchedule.targets(screen: screen, region: region, count: 20, seed: 42)
        let b = try PointerPracticeSchedule.targets(screen: screen, region: region, count: 20, seed: 42)
        let other = try PointerPracticeSchedule.targets(screen: screen, region: region, count: 20, seed: 43)
        #expect(a == b && a != other)
        #expect(Set(a.map(\.diameter)) == Set([24.0, 48, 96]))
        #expect(a.allSatisfy { region.contains($0.center, inset: $0.diameter / 2) })
        #expect(a.filter { $0.diameter == 24 }.count == 7)
        #expect(a.filter { $0.diameter == 48 }.count == 7)
        #expect(a.filter { $0.diameter == 96 }.count == 6)
        let nonRetina = PointerScreen(displayID: 1, layoutID: 7, origin: screen.origin, width: screen.width, height: screen.height, backingScale: 1)
        #expect(try PointerPracticeSchedule.targets(screen: nonRetina, region: region, count: 20, seed: 42) == a)
    }
    @Test func practiceAndFormalAreSeparateAndOrderRotates() throws {
        let configuration = PracticeConfiguration(screen: screen, region: region, source: .b, stage: .warmup, seed: 1, sessionIndex: 1)
        #expect(try PointerPracticeRun(configuration: configuration).targets.count == 4)
        #expect(try PointerPracticeRun(configuration: PracticeConfiguration(screen: screen, region: region, source: .b, stage: .formal, seed: 1, sessionIndex: 1)).targets.count == 20)
        #expect(PointerPracticeSchedule.modeOrder(sessionIndex: 0) == [.a, .b, .c, .d])
        #expect(PointerPracticeSchedule.modeOrder(sessionIndex: 1) == [.b, .c, .d, .a])
        #expect(PointerPracticeSchedule.modeOrder(sessionIndex: 4) == [.a, .b, .c, .d])
        #expect(PointerPracticeSchedule.modeOrder(sessionIndex: -1) == [.d, .a, .b, .c])
    }
    @Test func entryFreezeAndClickCostsAreIndependent() throws {
        var value = try run(); let mutation1 = value.beginNext(at: 10); #expect(mutation1)
        value.move(to: target.center, at: 12)
        value.freeze(at: 13)
        value.freeze(at: 13.2) // repeated callback is not another correction
        value.click(at: target.center, button: .left, clickCount: 1, time: 14.5)
        let trial = try #require(value.result.trials.first)
        #expect(trial.totalSeconds == 4.5)
        #expect(trial.firstTargetEntrySeconds == 2)
        #expect(trial.firstFreezeSeconds == 3)
        #expect(trial.freezeToCompletionSeconds == 1.5)
        #expect(trial.firstClickHit == true && trial.freezeCount == 1 && trial.explicitFreeze)
        #expect(value.isComplete)
    }
    @Test func targetAlreadyUnderPointerStartsWithZeroAcquisitionCost() throws {
        var value = try run()
        let began = value.beginNext(at: 5, initialPointer: target.center)
        #expect(began)
        value.freeze(at: 6); value.click(at: target.center, button: .left, clickCount: 1, time: 7)
        #expect(value.result.trials[0].firstTargetEntrySeconds == 0)
        #expect(value.result.trials[0].targetEntries == 1)
        #expect(value.result.trials[0].totalSeconds == 2)
    }
    @Test func correctionsAndWrongButtonsRemainInEvidence() throws {
        var value = try run(); value.beginNext(at: 0)
        value.move(to: target.center, at: 1)
        let outside = PointerPoint(x: target.center.x + 40, y: target.center.y)
        value.move(to: outside, at: 2); value.freeze(at: 3)
        value.click(at: outside, button: .left, clickCount: 1, time: 4)
        value.move(to: target.center, at: 5); value.freeze(at: 6)
        value.click(at: target.center, button: .right, clickCount: 1, time: 7)
        value.click(at: target.center, button: .left, clickCount: 1, time: 8)
        let trial = try #require(value.result.trials.first)
        #expect(trial.firstClickHit == false && trial.missedClicks == 2)
        #expect(trial.targetReentries == 1 && trial.movementResumptions == 1)
        #expect(trial.clicks.map(\.failure) == [.miss, .wrongButton, nil])
        #expect(trial.freezeToCompletionSeconds == 5) // includes correction after the first freeze
    }
    @Test func backwardTimeAndClicksBetweenTargetsDoNotCorruptScores() throws {
        var value = try run(targets: [target, PracticeTarget(id: 2, center: target.center, diameter: 48)])
        value.beginNext(at: 10); value.move(to: target.center, at: 12)
        value.freeze(at: 11)
        value.click(at: target.center, button: .left, clickCount: 1, time: 13)
        value.click(at: target.center, button: .left, clickCount: 2, time: 13.1)
        #expect(value.result.trials.count == 1 && value.result.ignoredEvents == 2)
        value.beginNext(at: 14)
        value.click(at: target.center, button: .left, clickCount: 2, time: 14.1)
        #expect(value.result.trials.count == 1 && value.isActive)
        value.click(at: target.center, button: .left, clickCount: 1, time: 15)
        #expect(value.result.trials.count == 2 && value.result.trials[1].clicks.first?.failure == .extraClick)
    }
    @Test func failureDenominatorsAndInvalidSuccessAreHonest() throws {
        var value = try run(targets: [target, PracticeTarget(id: 2, center: target.center, diameter: 24), PracticeTarget(id: 3, center: target.center, diameter: 96)])
        value.beginNext(at: 0); value.finish(.hit, at: 1)
        #expect(value.isActive && value.trials.isEmpty)
        value.tick(at: 30); value.beginNext(at: 31); value.finish(.skipped, at: 35)
        value.beginNext(at: 36); value.finish(.aborted, at: 37)
        #expect(value.result.trials.map(\.outcome) == [.timeout, .skipped, .aborted])
        #expect(value.result.summary.attempted == 3 && value.result.summary.failures == 3)
        #expect(value.result.summary.totalSecondsForCompleted.count == 0)
        #expect(value.result.summary.totalSecondsForCompleted.median == nil)
    }
    @Test func implicitClickFreezeIsNotReportedAsMeasuredFreezeCost() throws {
        var value = try run(); value.beginNext(at: 1)
        value.click(at: target.center, button: .left, clickCount: 1, time: 4)
        #expect(value.result.trials[0].freezeToCompletionSeconds == 0)
        #expect(!value.result.trials[0].explicitFreeze)
        #expect(value.result.summary.freezeToCompletionSeconds.count == 0)
    }
    @Test func feedbackAndMetadataSurviveJSONExport() throws {
        var value = try run(); value.beginNext(at: 0); value.finish(.skipped, at: 3)
        value.recordFeedback(effort: 8, text: "看表时发生转腕，失败保留")
        let payload = try PointerPracticeEvidence(regularRuns: [value.result], blindRuns: []).encoded()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PointerPracticeEvidence.self, from: payload)
        #expect(decoded.regularRuns[0].effort == 8)
        #expect(decoded.regularRuns[0].feedback == "看表时发生转腕，失败保留")
        #expect(decoded.regularRuns[0].configuration.metadata.sourceSHA == "待记录")
        #expect(decoded.regularRuns[0].configuration.modeOrder == [.b, .c, .d, .a])
        value.recordFeedback(effort: 11, text: "")
        #expect(value.result.effort == nil)
    }
    @Test func invalidGeometryCannotCreateAFalseTrial() throws {
        #expect(throws: PracticeError.invalidRegion) {
            try PointerPracticeSchedule.targets(screen: screen,
                region: PracticeRegion(origin: screen.origin, width: .nan, height: 600), count: 20, seed: 1)
        }
        #expect(throws: PracticeError.invalidTarget) {
            try run(targets: [PracticeTarget(id: 1, center: PointerPoint(x: 100, y: 100), diameter: 24)])
        }
    }
    @Test func medianAndRangeDoNotInventTailPercentiles() {
        let value = PracticeRange([1, 9, 2, 3])
        #expect(value.count == 4 && value.median == 2.5 && value.minimum == 1 && value.maximum == 9)
        #expect(PracticeRange([]).median == nil)
    }
    let training: [PointerPoint] = [.init(x: 0.5, y: 0.5), .init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.1), .init(x: 0.9, y: 0.9), .init(x: 0.1, y: 0.9)]
    func blind(posture: BlindPracticePosture = .original, calibrationID: UUID = UUID()) throws -> BlindPointerPractice {
        try BlindPointerPractice(screen: screen, region: region, calibrationID: calibrationID, posture: posture,
                                 trainingTargetsNormalized: training, seed: 42)
    }
    @Test func blindTargetsAreIndependentAndRandomized() throws {
        let a = try blind(), b = try blind()
        #expect(a.targets.count == 9 && a.targets == b.targets)
        #expect(Set(a.targets.map(\.id)).count == 9)
        #expect(a.targets.allSatisfy { target in training.allSatisfy { screen.point(normalized: $0).distance(to: target.center) > 48 } })
        #expect(a.targets.allSatisfy { region.contains($0.center, inset: 24) })
    }
    @Test func blindPredictionLocksOnceBeforeAnyCorrection() throws {
        var value = try blind(); value.beginNext(at: 1)
        let target = try #require(value.currentTarget)
        let outsideScreen = PointerPoint(x: screen.origin.x - 500, y: screen.origin.y - 300)
        let mutation2 = value.lockPrediction(outsideScreen, at: 3, sampleCount: 15, sampleRateHz: 28, rmsRadians: 0.001, maxDeviationRadians: 0.002); #expect(mutation2)
        let mutation3 = value.lockPrediction(target.center, at: 4, sampleCount: 15, sampleRateHz: 28, rmsRadians: 0.001, maxDeviationRadians: 0.002); #expect(!mutation3)
        #expect(value.result.trials.count == 1 && value.result.hits == 0)
        #expect(value.result.trials[0].prediction == outsideScreen)
        #expect(value.result.trials[0].errorPoints == target.center.distance(to: outsideScreen))
        #expect(value.result.trials[0].errorPoints! > target.center.distance(to: screen.clamp(outsideScreen)))
    }
    @Test func postureGroupsAndFailedBlindSamplesStaySeparate() throws {
        let calibrationID = UUID()
        var original = try blind(calibrationID: calibrationID)
        var perturbed = try blind(posture: .perturbed, calibrationID: calibrationID)
        original.beginNext(at: 0); original.fail(.unstable, at: 2)
        perturbed.beginNext(at: 3); perturbed.fail(.invalidContext, at: 4)
        let data = try PointerPracticeEvidence(regularRuns: [], blindRuns: [original.result, perturbed.result]).encoded()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PointerPracticeEvidence.self, from: data)
        #expect(restored.blindRuns.map(\.posture) == [.original, .perturbed])
        #expect(restored.blindRuns.allSatisfy { $0.calibrationID == calibrationID && $0.trials.count == 1 && $0.errors.count == 0 })
    }
    @Test func productionStableCollectorGatesBlindLockWithoutAnotherModel() throws {
        let first = AttitudeSample(referenceID: 100, sequence: 1, watchTime: 1, attitude: .identity)
        var collector = StableAttitudeCollector(binding: CalibrationBinding(screen: screen, sample: first))
        var value = try blind(); value.beginNext(at: 10)
        var stable: StableAttitudeWindow?
        for index in 0...13 {
            let sample = AttitudeSample(referenceID: 100, sequence: UInt32(index + 1), watchTime: 1 + Double(index) * 0.04, attitude: .identity)
            let result = try collector.append(sample: sample, screen: screen)
            if index < 13 { #expect(result == nil) }
            if let result { stable = result }
        }
        let window = try #require(stable), target = try #require(value.currentTarget)
        let locked = value.lockPrediction(target.center, at: 11, sampleCount: window.samples.count,
            sampleRateHz: window.sampleRateHz, rmsRadians: window.rmsRadians, maxDeviationRadians: window.maxDeviationRadians)
        #expect(locked && value.result.hits == 1 && value.result.trials[0].sampleCount == 14)
        let afterLock = try collector.append(sample: AttitudeSample(referenceID: 100, sequence: 15, watchTime: 1.56, attitude: .identity), screen: screen)
        #expect(afterLock == nil)
        collector.reset()
        #expect(throws: CalibrationFailure.contextChanged) {
            try collector.append(sample: AttitudeSample(referenceID: 101, sequence: 16, watchTime: 1.6, attitude: .identity), screen: screen)
        }
    }
    @Test func stopAndClickBarriersRejectLateConfirmationAndOldCycles() {
        var lease = MovementLease(); lease.newSession(101, enabled: true)
        let mutation4 = lease.start(cycle: 7); #expect(mutation4)
        let mutation5 = lease.freeze(cycle: 8); #expect(mutation5) // stop arrives before the baseline acknowledgement
        let mutation6 = lease.confirmBaseline(cycle: 7); #expect(!mutation6)
        #expect(!lease.acceptsPose(session: 101, cycle: 7))
        #expect(!lease.acceptsPose(session: 101, cycle: 8))
        let mutation7 = lease.start(cycle: 7); #expect(!mutation7)
        let mutation8 = lease.start(cycle: 9); #expect(mutation8); let mutation9 = lease.confirmBaseline(cycle: 9); #expect(mutation9)
        let mutation10 = lease.freeze(cycle: 10); #expect(mutation10) // click's freeze barrier
        #expect(!lease.acceptsPose(session: 101, cycle: 9))
        let mutation11 = lease.confirmBaseline(cycle: 9); #expect(!mutation11)
        let mutation12 = lease.freeze(cycle: 8); #expect(!mutation12)
        #expect(lease.phase == .reading && lease.cycle == 10)
    }
    @Test func pauseDisconnectAndModeBarrierNeverReopenMovement() {
        var lease = MovementLease(); lease.newSession(111, enabled: true)
        let mutation13 = lease.start(cycle: 1); #expect(mutation13); let mutation14 = lease.confirmBaseline(cycle: 1); #expect(mutation14)
        lease.setEnabled(false)
        #expect(!lease.acceptsPose(session: 111, cycle: 1))
        let mutation15 = lease.start(cycle: 2); #expect(!mutation15); lease.setEnabled(true)
        #expect(lease.phase == .reading && !lease.confirmBaseline(cycle: 1))
        let mutation16 = lease.start(cycle: 3); #expect(mutation16); lease.freeze(cycle: 4) // a mode change
        let mutation17 = lease.confirmBaseline(cycle: 3); #expect(!mutation17)
        lease.newSession(222, enabled: true)
        #expect(!lease.acceptsPose(session: 111, cycle: 99))
        let mutation18 = lease.start(cycle: 1); #expect(mutation18); let mutation19 = lease.confirmBaseline(cycle: 1); #expect(mutation19)
        #expect(!lease.acceptsPose(session: 111, cycle: 1))
        #expect(lease.acceptsPose(session: 222, cycle: 1))
    }
}
