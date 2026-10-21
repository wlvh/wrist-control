import Foundation
import Testing
@testable import WristCore

/// These tests exercise production mappings with synthetic device quaternions.
/// They prove mathematical/state rules, not actual watch axes or usability.
struct BCMappingsTests {
    let screen = PointerScreen(displayID: 1, layoutID: 1, origin: PointerPoint(x: -300, y: 80),
                               width: 1_000, height: 700, backingScale: 2)

    func pose(heading: Double = 0, elevation: Double = 0, roll: Double = 0) -> AttitudeQuaternion {
        AttitudeQuaternion.rotation(axis: SIMD3(0, 0, 1), radians: -heading)
        * AttitudeQuaternion.rotation(axis: SIMD3(1, 0, 0), radians: elevation)
        * AttitudeQuaternion.rotation(axis: SIMD3(0, 1, 0), radians: -roll)
    }

    func tilt(_ angle: Double, direction: PointerPoint = PointerPoint(x: 1, y: 0)) -> AttitudeQuaternion {
        AttitudeQuaternion.rotation(axis: SIMD3(-direction.y, 0, -direction.x), radians: angle)
    }

    func sample(_ q: AttitudeQuaternion = .identity, seq: UInt32 = 1, time: Double = 1,
                ref: UInt64 = 10, reference: AttitudeReference = .arbitraryZVertical,
                wear: WearConfiguration = WearConfiguration()) -> AttitudeSample {
        AttitudeSample(reference: reference, referenceID: ref, sequence: seq, watchTime: time,
                       attitude: q, wear: wear)
    }

    func context(_ sample: AttitudeSample, session: UInt64 = 44, cycle: UInt32 = 3,
                 screen: PointerScreen? = nil) -> MappingContext {
        MappingContext(session: session, cycle: cycle, screen: screen ?? self.screen, sample: sample)
    }

    func relative(_ result: PointerMappingResult) throws -> PointerPoint {
        if result == .none { return .zero }
        guard case let .relative(delta) = result else {
            Issue.record("Expected relative motion or none; got \(result)")
            throw MappingFailure.invalidSample
        }
        return delta
    }

    func expectNear(_ actual: PointerPoint, _ expected: PointerPoint, tolerance: Double = 1e-8) {
        #expect(abs(actual.x - expected.x) < tolerance)
        #expect(abs(actual.y - expected.y) < tolerance)
    }

    func mapping(_ joystick: Bool) -> any PointerMapping {
        joystick ? TiltJoystickMapping() : RollFollowingMapping()
    }

    @Test func beginAtCurrentPoseAndEquivalentQuaternionSignsProduceNoJump() throws {
        let q = pose(heading: 2.8, elevation: 0.25, roll: -0.4)
        let baseline = sample(q)
        let ctx = context(baseline)
        for joystick in [false, true] {
            var mapper = mapping(joystick)
            #expect(mapper.begin(sample: baseline, context: ctx) == .none)
            let same = sample(q, seq: 2, time: 1.04)
            expectNear(try relative(mapper.update(sample: same, context: ctx)), .zero)
            let negated = AttitudeQuaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z)
            expectNear(try relative(mapper.update(sample: sample(negated, seq: 3, time: 1.08),
                                                 context: ctx)), .zero)
        }
    }

    @Test func bUsesActualRollAxisAndElevationRatherThanHeadingGain() throws {
        let baseline = sample()
        let ctx = context(baseline)
        let cases: [(AttitudeQuaternion, PointerPoint, PointerPoint)] = [
            (pose(heading: 0.15), .zero, PointerPoint(x: 240, y: 0)),
            (pose(roll: 0.15), PointerPoint(x: 240, y: 0), .zero),
            (pose(roll: -0.15), PointerPoint(x: -240, y: 0), .zero),
            (pose(elevation: 0.15), PointerPoint(x: 0, y: -240), PointerPoint(x: 0, y: -240)),
            (pose(elevation: -0.15), PointerPoint(x: 0, y: 240), PointerPoint(x: 0, y: 240))
        ]
        for (q, expectedB, expectedA) in cases {
            var a = HeadingFollowingMapping()
            var b = RollFollowingMapping()
            #expect(a.begin(sample: baseline, context: ctx) == .none)
            #expect(b.begin(sample: baseline, context: ctx) == .none)
            expectNear(try relative(a.update(sample: sample(q, seq: 2, time: 1.04), context: ctx)), expectedA)
            expectNear(try relative(b.update(sample: sample(q, seq: 2, time: 1.04), context: ctx)), expectedB)
        }
    }

    @Test func bRollAndCHeadingCrossSignedPiWithoutTeleporting() throws {
        var b = RollFollowingMapping()
        let baselineB = sample(pose(roll: .pi - 0.02))
        let ctxB = context(baselineB)
        #expect(b.begin(sample: baselineB, context: ctxB) == .none)
        expectNear(try relative(b.update(sample: sample(pose(roll: -.pi + 0.02), seq: 2, time: 1.04),
                                        context: ctxB)), PointerPoint(x: 64, y: 0))
        expectNear(try relative(b.update(sample: sample(pose(roll: .pi - 0.02), seq: 3, time: 1.08),
                                        context: ctxB)), PointerPoint(x: -64, y: 0))

        var c = TiltJoystickMapping(parameters: JoystickParameters(deadZoneRadians: 0, exponent: 1))
        let baselineC = sample(pose(heading: .pi - 0.02))
        let ctxC = context(baselineC)
        #expect(c.begin(sample: baselineC, context: ctxC) == .none)
        let delta = try relative(c.update(sample: sample(pose(heading: -.pi + 0.02), seq: 2, time: 1.04),
                                          context: ctxC))
        expectNear(delta, PointerPoint(x: 1_000 * 0.04 / (12 * .pi / 180) * 0.04, y: 0))
    }

    @Test func wearCorrectionPreservesCAndExplicitlyReversesOnlyBRoll() throws {
        let inverseCrownRotation = AttitudeQuaternion(w: 0, z: -1)
        for wrist in [WristSide.left, .right] {
            for crown in [CrownSide.right, .left] {
                let wear = WearConfiguration(wrist: wrist, crown: crown)
                let rawBasis: AttitudeQuaternion = crown == .left ? inverseCrownRotation : .identity
                let baseline = sample(rawBasis, wear: wear)
                let ctx = context(baseline)
                var b = RollFollowingMapping()
                #expect(b.begin(sample: baseline, context: ctx) == .none)
                let movedB = sample(pose(elevation: 0.1, roll: 0.1) * rawBasis,
                                    seq: 2, time: 1.04, wear: wear)
                expectNear(try relative(b.update(sample: movedB, context: ctx)),
                           PointerPoint(x: 160 * wear.rollSign, y: -160))
                var c = TiltJoystickMapping()
                #expect(c.begin(sample: baseline, context: ctx) == .none)
                let movedC = sample(tilt(0.3, direction: PointerPoint(x: 1, y: -1)) * rawBasis,
                                    seq: 2, time: 1.04, wear: wear)
                let component = 40 / sqrt(2.0)
                expectNear(try relative(c.update(sample: movedC, context: ctx)),
                           PointerPoint(x: component, y: -component))
            }
        }
    }

    @Test func bSameTrajectoryTelescopesAcrossSampleRatesAndSkippedSnapshots() throws {
        for rate in [10, 25, 50, 100] {
            var b = RollFollowingMapping()
            let baseline = sample()
            let ctx = context(baseline)
            #expect(b.begin(sample: baseline, context: ctx) == .none)
            var total = PointerPoint.zero
            for index in 1...rate {
                let fraction = Double(index) / Double(rate)
                let current = sample(pose(heading: 0.3 * fraction, elevation: 0.12 * fraction,
                                          roll: 0.4 * fraction),
                                     seq: UInt32(index * 4 + 1), time: 1 + fraction)
                total = total + (try relative(b.update(sample: current, context: ctx)))
            }
            expectNear(total, PointerPoint(x: 640, y: -192))
        }
    }

    @Test func bAndCDiscardOutwardMotionAtConsumerAndReverseImmediately() throws {
        let baseline = sample()
        let ctx = context(baseline)
        var b = RollFollowingMapping()
        #expect(b.begin(sample: baseline, context: ctx) == .none)
        var cursor = PointerPoint(x: screen.origin.x + screen.width - 1, y: 300)
        cursor = screen.clamp(cursor + (try relative(b.update(
            sample: sample(pose(roll: 0.2), seq: 2, time: 1.04), context: ctx))))
        #expect(cursor.x == 699)
        cursor = screen.clamp(cursor + (try relative(b.update(
            sample: sample(pose(roll: 0.19), seq: 3, time: 1.08), context: ctx))))
        #expect(abs(cursor.x - 683) < 1e-8)

        var c = TiltJoystickMapping()
        #expect(c.begin(sample: baseline, context: ctx) == .none)
        cursor.x = 699
        for index in 1...5 {
            cursor = screen.clamp(cursor + (try relative(c.update(
                sample: sample(tilt(0.21), seq: UInt32(index + 1), time: 1 + 0.04 * Double(index)),
                context: ctx))))
        }
        #expect(cursor.x == 699)
        cursor = screen.clamp(cursor + (try relative(c.update(
            sample: sample(tilt(-0.21), seq: 7, time: 1.24), context: ctx))))
        #expect(abs(cursor.x - 659) < 1e-8)
    }

    @Test func cRadialDeadZoneMonotonicSpeedSaturationAndDiagonalCap() throws {
        let parameters = JoystickParameters()
        let angles = [0, parameters.deadZoneRadians * 0.99, parameters.deadZoneRadians,
                      parameters.deadZoneRadians + 0.001, 0.08, 0.15,
                      parameters.fullSpeedRadians, 0.3]
        var previousSpeed = 0.0
        for angle in angles {
            var c = TiltJoystickMapping(parameters: parameters)
            let baseline = sample()
            let ctx = context(baseline)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            let delta = try relative(c.update(sample: sample(tilt(angle), seq: 2, time: 1.04), context: ctx))
            let speed = hypot(delta.x, delta.y) / 0.04
            let fraction = max(0, min(1, (angle - parameters.deadZoneRadians)
                                          / (parameters.fullSpeedRadians - parameters.deadZoneRadians)))
            #expect(abs(speed - 1_000 * pow(fraction, parameters.exponent)) < 1e-8)
            #expect(speed + 1e-8 >= previousSpeed && speed <= 1_000 + 1e-8)
            previousSpeed = speed
        }
        for direction in [PointerPoint(x: 1, y: 0), PointerPoint(x: 0, y: 1),
                          PointerPoint(x: 1, y: 1), PointerPoint(x: -1, y: -1)] {
            var c = TiltJoystickMapping()
            let baseline = sample()
            let ctx = context(baseline)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            let delta = try relative(c.update(sample: sample(tilt(0.3, direction: direction),
                                                              seq: 2, time: 1.04), context: ctx))
            #expect(abs(hypot(delta.x, delta.y) - 40) < 1e-8)
            let norm = hypot(direction.x, direction.y)
            expectNear(delta, PointerPoint(x: direction.x / norm * 40, y: direction.y / norm * 40))
        }
    }

    @Test func cHeldTiltMovesWhileBHeldPoseStopsAndReturnToNeutralHasNoTail() throws {
        let baseline = sample()
        let ctx = context(baseline)
        var b = RollFollowingMapping()
        var c = TiltJoystickMapping()
        #expect(b.begin(sample: baseline, context: ctx) == .none)
        #expect(c.begin(sample: baseline, context: ctx) == .none)
        let tilted = tilt(0.21, direction: PointerPoint(x: 0, y: -1))
        let first = sample(tilted, seq: 2, time: 1.04)
        #expect(try relative(b.update(sample: first, context: ctx)).y < 0)
        expectNear(try relative(c.update(sample: first, context: ctx)), PointerPoint(x: 0, y: -40))
        let held = sample(tilted, seq: 3, time: 1.08)
        #expect(b.update(sample: held, context: ctx) == .none)
        expectNear(try relative(c.update(sample: held, context: ctx)), PointerPoint(x: 0, y: -40))
        #expect(c.update(sample: sample(seq: 4, time: 1.12), context: ctx) == .none)
        #expect(c.update(sample: sample(seq: 5, time: 1.16), context: ctx) == .none)
        c.reset()
        #expect(c.update(sample: sample(tilted, seq: 6, time: 1.20), context: ctx) == .stop(.notStarted))
        let newBaseline = sample(tilted, seq: 7, time: 1.24)
        let newContext = context(newBaseline, cycle: 4)
        #expect(c.begin(sample: newBaseline, context: newContext) == .none)
        #expect(c.update(sample: sample(tilted, seq: 8, time: 1.28), context: newContext) == .none)
    }

    @Test func cHeldDistanceUsesWatchTimeRatherThanCallbackCount() throws {
        for rate in [10, 25, 50, 100] {
            var c = TiltJoystickMapping()
            let baseline = sample()
            let ctx = context(baseline)
            let held = tilt(0.21)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            _ = c.update(sample: sample(held, seq: 2, time: 1.01), context: ctx)
            var total = PointerPoint.zero
            for index in 1...rate {
                let current = sample(held, seq: UInt32(index * 3 + 2),
                                     time: 1.01 + Double(index) / Double(rate))
                total = total + (try relative(c.update(sample: current, context: ctx)))
            }
            expectNear(total, PointerPoint(x: 1_000, y: 0))
        }
    }

    @Test func cRampIntegrationHasBoundedSamplingErrorIncludingMergedSnapshots() throws {
        let parameters = JoystickParameters()
        // Linear angle ramp neutral -> full speed in one second, then back.
        // Analytic integral of the specified power curve is 700 logical points.
        let expected = 2 * screen.width * (parameters.fullSpeedRadians - parameters.deadZoneRadians)
                     / (parameters.fullSpeedRadians * (parameters.exponent + 1))
        let fixedTimes: [[Double]] = [10, 25, 50, 100].map { rate in
            (1...(rate * 2)).map { Double($0) / Double(rate) }
        }
        let mergedTimes: [Double] = (0..<20).flatMap { index -> [Double] in
            let start = Double(index) * 0.1 + 0.01
            let end = Double(index + 1) * 0.1
            return [start, end]
        }
        for times in fixedTimes + [mergedTimes] {
            var c = TiltJoystickMapping(parameters: parameters)
            let baseline = sample()
            let ctx = context(baseline)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            var total = PointerPoint.zero
            for (index, elapsed) in times.enumerated() {
                let factor = elapsed <= 1 ? elapsed : 2 - elapsed
                let current = sample(tilt(parameters.fullSpeedRadians * factor),
                                     seq: UInt32(index * 5 + 2), time: 1 + elapsed)
                total = total + (try relative(c.update(sample: current, context: ctx)))
            }
            #expect(abs(total.x - expected) / expected < 0.01)
            #expect(abs(total.y) < 1e-8)
        }
        // The immediate current-speed rule is intentionally not exact
        // quadrature. A one-way ramp reveals its sampling bias, which the
        // symmetric trajectory above can cancel. Compare nominal 25/50 Hz.
        var rampDistances: [Double] = []
        for rate in [25, 50] {
            var c = TiltJoystickMapping(parameters: parameters)
            let baseline = sample()
            let ctx = context(baseline)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            var distance = 0.0
            for index in 1...rate {
                let elapsed = Double(index) / Double(rate)
                let current = sample(tilt(parameters.fullSpeedRadians * elapsed),
                                     seq: UInt32(index + 1), time: 1 + elapsed)
                distance += try relative(c.update(sample: current, context: ctx)).x
            }
            #expect(abs(distance - expected / 2) / (expected / 2) < 0.06)
            rampDistances.append(distance)
        }
        #expect(abs(rampDistances[0] - rampDistances[1]) / (expected / 2) < 0.03)
    }

    @Test func cUsesNeutralBodyFrameEvenWhenWatchPointsVertically() throws {
        let localTilt = tilt(0.3, direction: PointerPoint(x: 1, y: -1))
        for neutral in [AttitudeQuaternion.identity, pose(heading: 2, elevation: 0.6, roll: -0.7),
                        pose(elevation: .pi / 2)] {
            var c = TiltJoystickMapping()
            let baseline = sample(neutral)
            let ctx = context(baseline)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            expectNear(try relative(c.update(sample: sample(neutral * localTilt, seq: 2, time: 1.04),
                                            context: ctx)),
                       PointerPoint(x: 40 / sqrt(2.0), y: -40 / sqrt(2.0)))
        }
        var c = TiltJoystickMapping()
        let baseline = sample()
        let ctx = context(baseline)
        #expect(c.begin(sample: baseline, context: ctx) == .none)
        #expect(c.update(sample: sample(pose(roll: 0.3), seq: 2, time: 1.04), context: ctx) == .none)
    }

    @Test func noNewSampleTimeReversalAndLongGapsStopAndClearBothMappings() {
        let baseline = sample()
        let ctx = context(baseline)
        let cases: [(AttitudeSample, MappingFailure)] = [
            (baseline, .reorderedSample),
            (sample(seq: 1, time: 1.04), .reorderedSample),
            (sample(seq: 2, time: 1), .reorderedSample),
            (sample(seq: 2, time: 0.99), .reorderedSample),
            (sample(seq: 2, time: 1.151), .timeGap),
            (sample(seq: 2, time: 20), .timeGap)
        ]
        for joystick in [false, true] {
            for (invalid, failure) in cases {
                var mapper = mapping(joystick)
                #expect(mapper.begin(sample: baseline, context: ctx) == .none)
                #expect(mapper.update(sample: invalid, context: ctx) == .stop(failure))
                #expect(mapper.update(sample: sample(seq: 3, time: 1.08), context: ctx) == .stop(.notStarted))
            }
        }
    }

    @Test func changedContextInvalidatesTheEntireCycleRatherThanRebasing() {
        let baseline = sample()
        let ctx = context(baseline)
        let next = sample(seq: 2, time: 1.04)
        let changedScreen = PointerScreen(displayID: 1, layoutID: 2, origin: screen.origin,
                                          width: screen.width, height: screen.height, backingScale: 2)
        let changedReference = sample(seq: 2, time: 1.04, ref: 11)
        let changedFrame = sample(seq: 2, time: 1.04, reference: .correctedZVertical)
        let changedWrist = sample(seq: 2, time: 1.04, wear: WearConfiguration(wrist: .right))
        let changedCrown = sample(seq: 2, time: 1.04, wear: WearConfiguration(crown: .left))
        let cases: [(AttitudeSample, MappingContext)] = [
            (next, context(baseline, session: 45)), (next, context(baseline, cycle: 4)),
            (next, context(baseline, screen: changedScreen)),
            (changedReference, ctx), (changedFrame, ctx), (changedWrist, ctx), (changedCrown, ctx),
            (changedReference, context(changedReference))
        ]
        for joystick in [false, true] {
            for (current, changed) in cases {
                var mapper = mapping(joystick)
                #expect(mapper.begin(sample: baseline, context: ctx) == .none)
                #expect(mapper.update(sample: current, context: changed) == .stop(.contextChanged))
                #expect(mapper.update(sample: next, context: ctx) == .stop(.notStarted))
            }
        }
    }

    @Test func invalidSamplesAndAngularJumpsStopUntilAnExplicitNewBeginning() {
        let baseline = sample()
        let ctx = context(baseline)
        let invalidSamples = [
            sample(AttitudeQuaternion(w: .nan), seq: 2, time: 1.04),
            sample(AttitudeQuaternion(x: .infinity), seq: 2, time: 1.04),
            sample(AttitudeQuaternion(w: 0), seq: 2, time: 1.04),
            sample(seq: 0, time: 1.04), sample(seq: 2, time: .nan),
            sample(seq: 2, time: .infinity), sample(seq: 2, time: -1),
            sample(seq: 2, time: 1.04, ref: 0)
        ]
        for joystick in [false, true] {
            for invalid in invalidSamples {
                var mapper = mapping(joystick)
                #expect(mapper.begin(sample: invalid, context: context(invalid)) == .stop(.invalidSample))
                #expect(mapper.begin(sample: baseline, context: ctx) == .none)
                #expect(mapper.update(sample: invalid, context: ctx) == .stop(.invalidSample))
                #expect(mapper.update(sample: sample(seq: 3, time: 1.08), context: ctx) == .stop(.notStarted))
            }
            var mapper = mapping(joystick)
            #expect(mapper.begin(sample: baseline, context: ctx) == .none)
            let jumped = sample(pose(elevation: MotionLimits.maxAngularStep + 0.01), seq: 2, time: 1.04)
            #expect(mapper.update(sample: jumped, context: ctx) == .stop(.discontinuity))
            #expect(mapper.update(sample: sample(seq: 3, time: 1.08), context: ctx) == .stop(.notStarted))
            let fresh = sample(pose(elevation: 0.2), seq: 4, time: 2)
            #expect(mapper.begin(sample: fresh, context: context(fresh, cycle: 4)) == .none)
            mapper.reset()
            #expect(mapper.update(sample: sample(seq: 5, time: 2.04), context: ctx) == .stop(.notStarted))
        }
    }

    @Test func ambiguousDirectionsStopWithoutReusingLastValidVelocity() {
        var b = RollFollowingMapping()
        let baselineB = sample(pose(elevation: 1.4))
        let ctxB = context(baselineB)
        #expect(b.begin(sample: baselineB, context: ctxB) == .none)
        #expect(b.update(sample: sample(pose(elevation: .pi / 2), seq: 2, time: 1.04),
                         context: ctxB) == .stop(.invalidSample))
        // Both endpoints pass the feature's vertical exclusion, but a missing
        // intermediate sample must not turn ten degrees of pitch into pi roll.
        let beforePole = sample(pose(elevation: 85 * .pi / 180))
        let afterPole = sample(pose(elevation: 95 * .pi / 180), seq: 2, time: 1.04)
        let poleContext = context(beforePole)
        #expect(DirectionFeatures(sample: beforePole) != nil && DirectionFeatures(sample: afterPole) != nil)
        #expect(beforePole.attitude.angularDistance(to: afterPole.attitude) < MotionLimits.maxAngularStep)
        #expect(b.begin(sample: beforePole, context: poleContext) == .none)
        #expect(b.update(sample: afterPole, context: poleContext) == .stop(.discontinuity))
        var c = TiltJoystickMapping()
        let baseline = sample()
        let ctx = context(baseline)
        #expect(c.begin(sample: baseline, context: ctx) == .none)
        for index in 1...3 {
            let result = c.update(sample: sample(tilt(Double(index) * 0.4), seq: UInt32(index + 1),
                                                 time: 1 + Double(index) * 0.04), context: ctx)
            guard case .relative = result else { Issue.record("Expected bounded forward motion"); return }
        }
        #expect(c.update(sample: sample(tilt(1.6), seq: 5, time: 1.16), context: ctx) == .stop(.discontinuity))
        #expect(c.update(sample: sample(tilt(1.2), seq: 6, time: 1.20), context: ctx) == .stop(.notStarted))
    }

    @Test func parametersRoundTripAndRejectNonFiniteOutOfRangeOrContradictoryValues() throws {
        let custom = JoystickParameters(deadZoneRadians: 0.02, fullSpeedRadians: 0.3,
                                        exponent: 2, maxScreenWidthsPerSecond: 0.75)
        let encoded = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(JoystickParameters.self, from: encoded) == custom)
        #expect(custom.isValid && JoystickParameters().isValid)
        let invalidParameters = [
            JoystickParameters(deadZoneRadians: -0.01),
            JoystickParameters(deadZoneRadians: 0.3, fullSpeedRadians: 0.3),
            JoystickParameters(deadZoneRadians: .nan),
            JoystickParameters(fullSpeedRadians: .infinity),
            JoystickParameters(fullSpeedRadians: .pi),
            JoystickParameters(exponent: 0), JoystickParameters(exponent: -1),
            JoystickParameters(exponent: .nan), JoystickParameters(exponent: 9),
            JoystickParameters(maxScreenWidthsPerSecond: 0),
            JoystickParameters(maxScreenWidthsPerSecond: .infinity),
            JoystickParameters(maxScreenWidthsPerSecond: 5)
        ]
        let baseline = sample()
        let ctx = context(baseline)
        for parameters in invalidParameters {
            #expect(!parameters.isValid)
            var c = TiltJoystickMapping(parameters: parameters)
            #expect(c.begin(sample: baseline, context: ctx) == .stop(.invalidParameters))
            #expect(c.update(sample: sample(seq: 2, time: 1.04), context: ctx) == .stop(.notStarted))
        }
        for invalidGain in [0, -1, RollFollowingMapping.minimumGain - 1,
                            Double.nan, Double.infinity, RollFollowingMapping.maximumGain + 1] {
            for invalidX in [false, true] {
                var b = RollFollowingMapping(gainX: invalidX ? invalidGain : 1_600,
                                             gainY: invalidX ? 1_600 : invalidGain)
                #expect(b.begin(sample: baseline, context: ctx) == .stop(.invalidParameters))
            }
        }
    }

    @Test func invalidStartContextAndOverflowAreRejectedAndRetinaDoesNotMultiplyMotion() throws {
        let baseline = sample()
        let invalidScreen = PointerScreen(displayID: 1, layoutID: 1, width: .nan, height: 700)
        for joystick in [false, true] {
            for invalid in [context(baseline, session: 0), context(baseline, cycle: 0),
                            context(baseline, screen: invalidScreen)] {
                var mapper = mapping(joystick)
                #expect(mapper.begin(sample: baseline, context: invalid) == .stop(.contextChanged))
            }
        }
        let hugeScreen = PointerScreen(displayID: 1, layoutID: 1, width: Double.greatestFiniteMagnitude, height: 700)
        var invalid = TiltJoystickMapping(parameters: JoystickParameters(maxScreenWidthsPerSecond: 4))
        #expect(invalid.begin(sample: baseline, context: context(baseline, screen: hugeScreen)) == .stop(.invalidParameters))
        for scale in [1.0, 2.0, 3.0] {
            let target = PointerScreen(displayID: 1, layoutID: 1, origin: PointerPoint(x: 800, y: -200),
                                       width: 1_000, height: 700, backingScale: scale)
            var c = TiltJoystickMapping()
            let ctx = context(baseline, screen: target)
            #expect(c.begin(sample: baseline, context: ctx) == .none)
            expectNear(try relative(c.update(sample: sample(tilt(0.21), seq: 2, time: 1.04), context: ctx)),
                       PointerPoint(x: 40, y: 0))
        }
    }
}
