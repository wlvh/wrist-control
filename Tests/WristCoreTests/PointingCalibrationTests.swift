import Foundation
import AppKit
import Testing
@testable import WristCore
import WristMacOutput

struct PointingCalibrationTests {
    @Test func privateEvidencePreservesTrainingSamplesWithoutClaimingIndependentAccuracy() throws {
        let model = try PointingCalibration.fit(observations: observations(), screen: screen)
        let record = CalibrationEvidence(model: model, macBuild: "4", watchBuild: "4", sourceRevision: "test")
        let json = try #require(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
        let points = try #require(json["observations"] as? [[String: Any]])
        #expect(points.count == 5)
        #expect((points[0]["samples"] as? [[String: Any]])?.count == 16)
        #expect((json["independentAccuracy"] as? String)?.contains("Not established") == true)
        #expect(json["calibrationID"] as? String == model.calibrationID.uuidString)
    }
    let screen = PointerScreen(displayID: 9, layoutID: 42, origin: PointerPoint(x: -1600, y: 80),
                               width: 1600, height: 1000, backingScale: 2)

    /// Rotate canonical +y to heading/elevation; optional roll leaves the ray unchanged.
    func pose(heading: Double, elevation: Double, roll: Double = 0, ref: UInt64 = 7,
              sequence: UInt32 = 1, time: Double = 1,
              wear: WearConfiguration = .init(), negate: Bool = false) -> AttitudeSample {
        let canonical = AttitudeQuaternion.rotation(axis: SIMD3(0, 0, 1), radians: -heading)
            * AttitudeQuaternion.rotation(axis: SIMD3(1, 0, 0), radians: elevation)
            * AttitudeQuaternion.rotation(axis: SIMD3(0, 1, 0), radians: roll)
        let crownCorrection = wear.crown == .left ? AttitudeQuaternion(w: 0, z: 1) : .identity
        let raw = canonical * crownCorrection.inverse
        let q = negate ? AttitudeQuaternion(w: -raw.w, x: -raw.x, y: -raw.y, z: -raw.z) : raw
        return AttitudeSample(referenceID: ref, sequence: sequence, watchTime: time, attitude: q, wear: wear)
    }

    func stableWindow(heading: Double, elevation: Double, ref: UInt64 = 7,
                      wear: WearConfiguration = .init(), alternatingSigns: Bool = false) throws -> StableAttitudeWindow {
        let first = pose(heading: heading, elevation: elevation, ref: ref, wear: wear)
        var collector = StableAttitudeCollector(binding: CalibrationBinding(screen: screen, sample: first))
        var completed: StableAttitudeWindow?
        for index in 0...15 {
            completed = try collector.append(sample: pose(heading: heading, elevation: elevation, ref: ref,
                sequence: UInt32(index+1), time: 1+Double(index)/30, wear: wear,
                negate: alternatingSigns && index.isMultiple(of: 2)), screen: screen) ?? completed
        }
        return try #require(completed)
    }

    /// Known affine map includes cross-axis coupling, so a hardcoded separate
    /// x/y gain cannot satisfy the held-out predictions.
    func angles(for target: PointerPoint, anchor: Double = 0) -> PointerPoint {
        // u = .5 + 1.8*a + .3*b; v = .5 - .2*a - 2.0*b
        let u = target.x-0.5, v = target.y-0.5
        let determinant = -3.54
        return PointerPoint(x: anchor + (-2*u - 0.3*v)/determinant,
                            y: (0.2*u + 1.8*v)/determinant)
    }

    func observations(anchor: Double = 0, wear: WearConfiguration = .init()) throws -> [CalibrationObservation] {
        try PointingCalibration.targets.map { target in
            let angle = angles(for: target, anchor: anchor)
            return CalibrationObservation(target: target, window: try stableWindow(heading: angle.x, elevation: angle.y,
                                                                                  wear: wear, alternatingSigns: true))
        }
    }

    @Test func fitsKnownAffineAndPredictsOnlyHeldOutPoints() throws {
        let model = try PointingCalibration.fit(observations: observations(), screen: screen)
        #expect(model.observations.count == 5)
        #expect(model.quality.trainingRMSNormalized < 1e-12)
        #expect(abs(model.horizontal.heading-1.8) < 1e-10)
        #expect(abs(model.horizontal.elevation-0.3) < 1e-10)
        #expect(abs(model.vertical.heading+0.2) < 1e-10)
        #expect(abs(model.vertical.elevation+2.0) < 1e-10)
        for target in [PointerPoint(x: 0.23, y: 0.68), PointerPoint(x: 0.73, y: 0.32),
                       PointerPoint(x: 0.02, y: 0.98), PointerPoint(x: 0.98, y: 0.02)] {
            let angle = angles(for: target)
            let predicted = try model.predict(sample: pose(heading: angle.x, elevation: angle.y), screen: screen)
            #expect(predicted.distance(to: screen.point(normalized: target)) < 1e-8)
        }
    }

    @Test func signAlignedAverageAndMeasuredSamplingRate() throws {
        let first = pose(heading: 0.27, elevation: 0.11)
        var collector = StableAttitudeCollector(binding: CalibrationBinding(screen: screen, sample: first))
        var window: StableAttitudeWindow?
        for index in 0...15 {
            let jitter = index.isMultiple(of: 2) ? 0.003 : -0.003
            let result = try collector.append(sample: pose(heading: 0.27+jitter, elevation: 0.11,
                sequence: UInt32(index+1), time: 1+Double(index)/30, negate: index.isMultiple(of: 2)), screen: screen)
            if index < 15 { #expect(result == nil) }
            window = result ?? window
        }
        let capture = try #require(window)
        #expect(capture.meanSample.attitude.angularDistance(to: first.attitude) < 1e-6)
        #expect(abs(capture.sampleRateHz-30) < 1e-10)
        #expect(abs(capture.duration-0.5) < 1e-10)
        #expect(capture.rmsRadians < 0.004)
        #expect(try collector.append(sample: pose(heading: 0.27, elevation: 0.11,
            sequence: 17, time: 1.54), screen: screen) == nil)
    }

    @Test func unstableSampleWindowIsRejectedAndCleared() throws {
        let first = pose(heading: 0, elevation: 0)
        var collector = StableAttitudeCollector(binding: CalibrationBinding(screen: screen, sample: first))
        var failure: CalibrationFailure?
        for index in 0...15 {
            do {
                _ = try collector.append(sample: pose(heading: index.isMultiple(of: 2) ? 0.08 : -0.08, elevation: 0,
                    sequence: UInt32(index+1), time: 1+Double(index)/30), screen: screen)
            } catch { failure = error as? CalibrationFailure }
        }
        guard case .unstable = failure else { Issue.record("Expected unstable sample window"); return }
        #expect(collector.samples.isEmpty && collector.completedWindow == nil)
        // One outlier can hide in a low RMS; the maximum-deviation limit must
        // still reject it rather than quietly biasing the calibration.
        failure = nil
        for index in 0...15 {
            do {
                _ = try collector.append(sample: pose(heading: index == 8 ? 0.045 : 0, elevation: 0,
                    sequence: UInt32(index+1), time: 1+Double(index)/30), screen: screen)
            } catch { failure = error as? CalibrationFailure }
        }
        guard case let .unstable(rms, maximum) = failure else { Issue.record("Expected isolated outlier rejection"); return }
        #expect(rms < 0.015 && maximum > 0.035)
    }

    @Test func collectorsRejectInvalidContextGapsAndReordering() throws {
        let first = pose(heading: 0, elevation: 0)
        let binding = CalibrationBinding(screen: screen, sample: first)
        var collector = StableAttitudeCollector(binding: binding)
        _ = try collector.append(sample: first, screen: screen)
        #expect(throws: CalibrationFailure.reorderedSample) { try collector.append(sample: first, screen: screen) }
        #expect(collector.samples.isEmpty)
        _ = try collector.append(sample: first, screen: screen)
        #expect(throws: CalibrationFailure.timeGap) {
            try collector.append(sample: pose(heading: 0, elevation: 0, sequence: 2, time: 1.2), screen: screen)
        }
        #expect(throws: CalibrationFailure.contextChanged) {
            try collector.append(sample: pose(heading: 0, elevation: 0, ref: 8), screen: screen)
        }
        #expect(throws: CalibrationFailure.invalidSample) {
            try collector.append(sample: AttitudeSample(referenceID: 7, sequence: 2, watchTime: .nan, attitude: .identity),
                                 screen: screen)
        }
        #expect(throws: CalibrationFailure.invalidSample) {
            try collector.append(sample: pose(heading: 0, elevation: .pi/2), screen: screen)
        }
    }

    @Test func degeneracyCoverageAndIllConditioningAreDistinctFailures() throws {
        let repeated = try stableWindow(heading: 0, elevation: 0)
        let allRepeated = PointingCalibration.targets.map { CalibrationObservation(target: $0, window: repeated) }
        #expect(throws: CalibrationFailure.repeatedDirection(index: 1)) {
            try PointingCalibration.fit(observations: allRepeated, screen: screen)
        }
        let line = try PointingCalibration.targets.enumerated().map { index, target in
            CalibrationObservation(target: target, window: try stableWindow(heading: Double(index)*0.1, elevation: Double(index)*0.1))
        }
        #expect(throws: CalibrationFailure.rankDeficient) {
            try PointingCalibration.fit(observations: line, screen: screen)
        }
        let poorlyConditioned = try PointingCalibration.targets.enumerated().map { index, target in
            let a = Double(index)*0.1
            return CalibrationObservation(target: target, window: try stableWindow(heading: a,
                elevation: a + (index.isMultiple(of: 2) ? 0.001 : -0.001)))
        }
        do {
            _ = try PointingCalibration.fit(observations: poorlyConditioned, screen: screen)
            Issue.record("Expected ill-conditioned geometry rejection")
        } catch { guard case .illConditioned = error as? CalibrationFailure else { throw error } }
        let tiny = try PointingCalibration.targets.map { target in
            CalibrationObservation(target: target, window: try stableWindow(heading: (target.x-0.5)*0.1,
                                                                           elevation: (target.y-0.5)*0.075))
        }
        #expect(throws: CalibrationFailure.insufficientCoverage) {
            try PointingCalibration.fit(observations: tiny, screen: screen)
        }
    }

    @Test func rejectsWrongTargetsNonfiniteParametersAndBadFit() throws {
        var values = try observations()
        values[2] = CalibrationObservation(target: PointerPoint(x: .nan, y: 0.1), window: values[2].window)
        #expect(throws: CalibrationFailure.wrongTarget(index: 2)) {
            try PointingCalibration.fit(observations: values, screen: screen)
        }
        var configuration = CalibrationFitConfiguration(); configuration.maximumConditionNumber = .infinity
        #expect(throws: CalibrationFailure.invalidConfiguration) {
            try PointingCalibration.fit(observations: observations(), screen: screen, configuration: configuration)
        }
        let overflowingScreen = PointerScreen(displayID: 9, layoutID: 42,
            origin: PointerPoint(x: Double.greatestFiniteMagnitude/2, y: 0),
            width: Double.greatestFiniteMagnitude, height: 1000)
        #expect(throws: CalibrationFailure.invalidConfiguration) {
            try PointingCalibration.fit(observations: observations(), screen: overflowingScreen)
        }
        var inaccurate = try observations()
        inaccurate[0] = CalibrationObservation(target: PointingCalibration.targets[0],
            window: try stableWindow(heading: 0.14, elevation: 0.12))
        do {
            _ = try PointingCalibration.fit(observations: inaccurate, screen: screen)
            Issue.record("Expected inconsistent five-point fit rejection")
        } catch { guard case .poorFit = error as? CalibrationFailure else { throw error } }
    }

    @Test func anchorHandlesAngleBoundaryWithoutRecentering() throws {
        let anchor = Double.pi-0.03
        let model = try PointingCalibration.fit(observations: observations(anchor: anchor), screen: screen)
        for target in [PointerPoint(x: 0.15, y: 0.62), PointerPoint(x: 0.85, y: 0.38)] {
            let angle = angles(for: target, anchor: anchor)
            let direct = pose(heading: angle.x, elevation: angle.y)
            let wrapped = pose(heading: angle.x-2 * .pi, elevation: angle.y, negate: true)
            let first = try model.predict(sample: direct, screen: screen)
            let second = try model.predict(sample: wrapped, screen: screen)
            #expect(first.distance(to: screen.point(normalized: target)) < 1e-8)
            #expect(first.distance(to: second) < 1e-8)
        }
        #expect(abs(model.anchorHeading-anchor) < 1e-10)
    }

    @Test func allWearConfigurationsAndRollKeepThePointingRay() throws {
        for wrist in [WristSide.left, .right] {
            for crown in [CrownSide.left, .right] {
                let wear = WearConfiguration(wrist: wrist, crown: crown)
                let model = try PointingCalibration.fit(observations: observations(wear: wear), screen: screen)
                let target = PointerPoint(x: 0.7, y: 0.3), angle = angles(for: PointerPoint(x: 0.7, y: 0.3))
                let result = try model.predict(sample: pose(heading: angle.x, elevation: angle.y, roll: 0.8, wear: wear),
                                               screen: screen)
                #expect(result.distance(to: screen.point(normalized: target)) < 1e-8)
            }
        }
    }

    @Test func displayOffsetRetinaAndRawErrorAreNotConflated() throws {
        let model = try PointingCalibration.fit(observations: observations(), screen: screen)
        let target = PointerPoint(x: 1.05, y: 0.5), angle = angles(for: PointerPoint(x: 1.05, y: 0.5))
        let sample = pose(heading: angle.x, elevation: angle.y)
        let raw = try model.predictRaw(sample: sample, screen: screen)
        let bounded = try model.predict(sample: sample, screen: screen)
        #expect(raw.distance(to: screen.point(normalized: target)) < 1e-8)
        #expect(abs(raw.x-80) < 1e-8 && abs(raw.y-580) < 1e-8)
        #expect(abs(bounded.x - (-1)) < 1e-8)
        let edgeTarget = PointerPoint(x: -1, y: 580)
        let error = try model.predictionError(sample: sample, screen: screen, target: edgeTarget)
        #expect(abs(error.errorPoints-81) < 1e-8 && error.predicted == raw)
        #expect(throws: CalibrationFailure.outsideCalibratedRegion) {
            try model.predict(sample: pose(heading: 1.5, elevation: 0), screen: screen)
        }
    }

    @Test func everyBindingChangeInvalidatesTheModelIncludingProcessLayout() throws {
        let model = try PointingCalibration.fit(observations: observations(), screen: screen)
        let valid = pose(heading: 0, elevation: 0)
        let screens = [
            PointerScreen(displayID: 10, layoutID: 42, origin: screen.origin, width: 1600, height: 1000, backingScale: 2),
            PointerScreen(displayID: 9, layoutID: 43, origin: screen.origin, width: 1600, height: 1000, backingScale: 2),
            PointerScreen(displayID: 9, layoutID: 42, origin: .zero, width: 1600, height: 1000, backingScale: 2),
            PointerScreen(displayID: 9, layoutID: 42, origin: screen.origin, width: 1800, height: 1000, backingScale: 2),
            PointerScreen(displayID: 9, layoutID: 42, origin: screen.origin, width: 1600, height: 1000, backingScale: 1)
        ]
        for changed in screens {
            #expect(!model.isValid(sample: valid, screen: changed))
            #expect(throws: CalibrationFailure.contextChanged) { try model.predict(sample: valid, screen: changed) }
        }
        for changed in [
            pose(heading: 0, elevation: 0, ref: 8),
            pose(heading: 0, elevation: 0, wear: .init(wrist: .right)),
            pose(heading: 0, elevation: 0, wear: .init(crown: .left)),
            AttitudeSample(reference: .correctedZVertical, referenceID: 7, sequence: 1, watchTime: 1, attitude: .identity)
        ] {
            #expect(throws: CalibrationFailure.contextChanged) { try model.predict(sample: changed, screen: screen) }
        }
    }

    @Test func draftKeepsGoodPointsButCancelsAllOnContextChange() throws {
        let values = try observations()
        var draft = PointingCalibrationDraft(screen: screen)
        try draft.record(window: values[0].window, at: 0)
        #expect(throws: CalibrationFailure.repeatedDirection(index: 1)) { try draft.record(window: values[0].window, at: 1) }
        #expect(draft.observations[0] != nil && draft.observations[1] == nil)
        for index in 1...4 { try draft.record(window: values[index].window, at: index) }
        #expect(try draft.fit().quality.trainingRMSNormalized < 1e-12)
        draft.removePoint(at: 3)
        #expect(draft.observations.compactMap { $0 }.count == 4)
        try draft.record(window: values[3].window, at: 3)
        #expect(try draft.fit().observations.count == 5)
        let changed = try stableWindow(heading: 0.2, elevation: 0.2, ref: 8)
        #expect(throws: CalibrationFailure.contextChanged) { try draft.record(window: changed, at: 3) }
        #expect(draft.isCancelled && draft.observations.allSatisfy { $0 == nil })
        #expect(throws: CalibrationFailure.cancelled) { try draft.fit() }
        var cancelled = PointingCalibrationDraft(screen: screen)
        try cancelled.record(window: values[0].window, at: 0); cancelled.cancel()
        #expect(cancelled.binding == nil && cancelled.observations.allSatisfy { $0 == nil })
    }

    @Test func absoluteMappingSurvivesFreezeAndRejectsOldOrBrokenCycles() throws {
        let model = try PointingCalibration.fit(observations: observations(), screen: screen)
        var mapping = DPointingMapping(calibration: model)
        let angle = angles(for: PointerPoint(x: 0.67, y: 0.36))
        let initial = pose(heading: angle.x, elevation: angle.y, sequence: 1, time: 1)
        let context = MappingContext(session: 4, cycle: 1, screen: screen, sample: initial)
        let first = mapping.begin(sample: initial, context: context)
        guard case let .absolute(firstPoint) = first else { Issue.record("Expected immediate absolute alignment"); return }
        let moved = pose(heading: angle.x+0.02, elevation: angle.y, sequence: 2, time: 1.03)
        guard case .absolute = mapping.update(sample: moved, context: context) else { Issue.record("Expected movement"); return }
        mapping.reset()
        let resumed = pose(heading: angle.x, elevation: angle.y, sequence: 20, time: 4)
        let next = MappingContext(session: 4, cycle: 2, screen: screen, sample: resumed)
        #expect(mapping.begin(sample: resumed, context: next) == .absolute(firstPoint))
        #expect(mapping.calibration.calibrationID == model.calibrationID)
        #expect(mapping.update(sample: resumed, context: next) == .stop(.reorderedSample))
        #expect(mapping.update(sample: moved, context: context) == .stop(.notStarted))
        _ = mapping.begin(sample: resumed, context: next)
        let gap = pose(heading: angle.x, elevation: angle.y, sequence: 21, time: 4.2)
        #expect(mapping.update(sample: gap, context: next) == .stop(.timeGap))
        let changed = pose(heading: angle.x, elevation: angle.y, ref: 8, sequence: 22, time: 4.3)
        #expect(mapping.begin(sample: changed, context: MappingContext(session: 4, cycle: 3, screen: screen, sample: changed))
                == .stop(.calibrationRequired))
    }

    @MainActor @Test func ownWindowUsesLogicalCoordinatesAndCancellationCompletesOnce() throws {
        _ = NSApplication.shared
        var completions = 0
        var receivedModel: PointingCalibration?
        let controller = CalibrationWindowController(screen: screen,
            appKitFrame: NSRect(x: -1600, y: 0, width: 1600, height: 1000)) {
                completions += 1; receivedModel = $0
            }
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.isFlipped)
        #expect(view.bounds.width == screen.width && view.bounds.height == screen.height)
        controller.ingest(sample: pose(heading: 0, elevation: 0),
                          receivedAtMac: ProcessInfo.processInfo.systemUptime)
        // Optional offline visual proof. The window is never ordered on screen.
        if let path = ProcessInfo.processInfo.environment["WRIST_CALIBRATION_PREVIEW_PATH"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
        controller.invalidate(reason: "test reference change")
        controller.invalidate(reason: "second cancellation")
        #expect(completions == 1 && receivedModel == nil)
        #expect(controller.cancellationReason == "test reference change")
        #expect(controller.window?.isVisible == false)
    }
}
