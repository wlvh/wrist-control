import Testing
@testable import WristCore

struct PointerContractTests {
    let screen = PointerScreen(displayID: 1, layoutID: 1, origin: PointerPoint(x: -1920, y: 80), width: 1920, height: 1080, backingScale: 2)
    func sample(_ q: AttitudeQuaternion = .identity, ref: UInt64 = 10, seq: UInt32 = 1,
                time: Double = 1, wear: WearConfiguration = WearConfiguration()) -> AttitudeSample {
        AttitudeSample(referenceID: ref, sequence: seq, watchTime: time, attitude: q, wear: wear)
    }
    @Test func quaternionSignsAndCoordinateConvention() throws {
        let q = AttitudeQuaternion.rotation(axis: SIMD3(0, 0, 1), radians: -.pi/6)
        let a = try #require(DirectionFeatures(sample: sample(q)))
        let b = try #require(DirectionFeatures(sample: sample(AttitudeQuaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z))))
        #expect(abs(a.heading - .pi/6) < 1e-10)
        #expect(a == b)
        let leftCrown = AttitudeQuaternion.rotation(axis: SIMD3(0, 0, 1), radians: .pi)
        let equivalent = try #require(DirectionFeatures(sample: sample(q * leftCrown, wear: WearConfiguration(crown: .left))))
        #expect(abs(a.heading-equivalent.heading) < 1e-10)
        #expect(abs(DirectionFeatures.wrappedDelta(-.pi + 0.01, .pi - 0.01) - 0.02) < 1e-10)
    }
    @Test func relativeAxesAreDifferentAndWearIsExplicit() throws {
        let roll = AttitudeQuaternion.rotation(axis: SIMD3(0, 1, 0), radians: 0.1)
        let left = try #require(DirectionFeatures(sample: sample(roll)))
        let right = try #require(DirectionFeatures(sample: sample(roll, wear: WearConfiguration(wrist: .right))))
        #expect(abs(left.heading) < 1e-10 && abs(left.elevation) < 1e-10)
        #expect(abs(left.roll + 0.1) < 1e-10 && abs(left.roll+right.roll) < 1e-10)
    }
    @Test func screenOffsetAndRetinaDoNotRescaleEvents() {
        #expect(screen.point(normalized: PointerPoint(x: 0.5, y: 0.5)) == PointerPoint(x: -960, y: 620))
        #expect(screen.clamp(PointerPoint(x: 100, y: 9999)) == PointerPoint(x: -1, y: 1159))
        #expect(PointerScreen.appKitToQuartz(PointerPoint(x: -50, y: 100), primaryHeight: 1080) == PointerPoint(x: -50, y: 980))
    }
    @Test func stopClosesCycleAndResumeDoesNotRestartIt() {
        var lease = MovementLease(); lease.newSession(44, enabled: true)
        let started = lease.start(cycle: 1); #expect(started)
        let confirmed = lease.confirmBaseline(cycle: 1); #expect(confirmed)
        #expect(lease.acceptsPose(session: 44, cycle: 1))
        lease.freeze(cycle: 2)
        #expect(!lease.acceptsPose(session: 44, cycle: 1))
        #expect(!lease.acceptsPose(session: 44, cycle: 2))
        let replay = lease.start(cycle: 1); #expect(!replay)
        lease.setEnabled(false); lease.setEnabled(true)
        #expect(lease.phase == .reading && !lease.acceptsPose(session: 44, cycle: 2))
        let next = lease.start(cycle: 3); #expect(next)
        lease.newSession(55, enabled: true)
        #expect(!lease.acceptsPose(session: 44, cycle: 3))
    }
    @Test func calibrationSurvivesFreezeButNotReferenceDisplayOrWearChange() {
        let pose = sample(); let binding = CalibrationBinding(screen: screen, sample: pose)
        #expect(binding.matches(screen: screen, sample: sample(seq: 2, time: 2)))
        #expect(!binding.matches(screen: screen, sample: sample(ref: 11)))
        #expect(!binding.matches(screen: screen, sample: sample(wear: WearConfiguration(wrist: .right))))
        let changed = PointerScreen(displayID: 1, layoutID: 2, width: 1920, height: 1080, backingScale: 2)
        #expect(!binding.matches(screen: changed, sample: pose))
        #expect(!binding.matches(screen: screen, sample: sample(AttitudeQuaternion(w: .nan))))
    }
}
