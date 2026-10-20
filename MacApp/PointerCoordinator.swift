import Foundation
import WristCore

/// Production routing and movement lease. Every native submission still performs
/// its own permission/authentication check; this class defines intent ordering.
final class PointerCoordinator {
    private(set) var lease = MovementLease()
    private(set) var mode: PointerMode = .a
    private(set) var scope: OutputScope = .system
    private(set) var mainPage = true
    private(set) var calibration: PointingCalibration?
    private(set) var latestSample: AttitudeSample?
    private(set) var activeScreen: PointerScreen?
    var allowed: () -> Bool = { false }
    var cursor: () -> PointerPoint = { .zero }
    var screenAt: (PointerPoint) -> PointerScreen? = { _ in nil }
    var onMove: (PointerPoint, OutputScope) -> Bool = { _, _ in false }
    var onClick: (ClickRequest, UInt64, PointerPoint, Double, OutputScope) -> Bool = { _, _, _, _, _ in false }
    var onWheel: (Double, OutputScope) -> Bool = { _, _ in false }
    var onFreeze: () -> Void = {}
    var onBreakClickPair: () -> Void = {}
    var onSample: (AttitudeSample, Double) -> Void = { _, _ in }
    var onInvalidation: (String) -> Void = { _ in }
    var onChange: () -> Void = {}
    let journal: Journal
    private var mapper: (any PointerMapping)?
    private var context: MappingContext?
    private var isolatedPoint = PointerPoint.zero
    private var baseline: [AttitudeSample] = []
    private var startedAt = 0.0
    private var lastPoseAt = 0.0
    private var gains: [PointerMode: Double] = [.a: 1600, .b: 1600]
    private var lastClick: UInt64 = 0
    private var observed: AttitudeSample?
    init(journal: Journal) { self.journal = journal }

    func newSession(_ session: UInt64, enabled: Bool) {
        freeze(reason: "session_changed")
        lease.newSession(session, enabled: enabled); lastClick = 0
        latestSample = nil; observed = nil
        invalidateCalibration("connection_or_eligibility_changed")
        onChange()
    }
    func invalidateCalibration(_ reason: String) {
        calibration = nil
        if scope != .system { onInvalidation(reason) }
        journal.record("calibration_invalidated", detail: reason)
    }
    func installCalibration(_ value: PointingCalibration) { calibration = value; onChange() }
    func setScope(_ value: OutputScope, screen: PointerScreen? = nil) {
        freeze(reason: "scope_changed"); scope = value; activeScreen = screen
        if let screen { isolatedPoint = screen.point(normalized: PointerPoint(x: 0.5, y: 0.5)) }
        onChange()
    }
    func selectMode(_ value: PointerMode) {
        freeze(reason: "mode_changed"); mode = value
        journal.record("pointer_mode", detail: String(value.rawValue)); onChange()
    }
    @discardableResult func freeze(cycle: UInt32? = nil, reason: String, breakPair: Bool = true) -> Bool {
        guard lease.freeze(cycle: cycle) else { return false }
        mapper?.reset(); mapper = nil; context = nil; baseline = []
        onFreeze()
        if breakPair { onBreakClickPair() }
        journal.record("movement_frozen", detail: "cycle=\(lease.cycle);reason=\(reason)")
        onChange(); return true
    }
    func tick(now: Double) {
        guard lease.phase == .moving || lease.phase == .preparing else { return }
        if !allowed() { freeze(reason: "eligibility_lost"); return }
        if (lease.phase == .moving && now - lastPoseAt > MotionLimits.streamTimeout)
            || (lease.phase == .preparing && now - max(startedAt, lastPoseAt) > 0.5) {
            freeze(reason: "pose_stream_timeout")
        }
    }
    func handle(_ wire: PointerWire, now: Double) -> Bool {
        let frame = wire.frame
        guard frame.session == lease.session, lease.session != 0 else { return false }
        switch frame.kind {
        case .setMode:
            guard let value = PointerMode(rawValue: UInt8(clamping: frame.value)),
                  freeze(cycle: wire.cycle, reason: "watch_mode") else { return false }
            selectMode(value); return true
        case .setSensitivity:
            guard [.a, .b].contains(mode), (100...8000).contains(frame.value),
                  freeze(cycle: wire.cycle, reason: "gain_changed") else { return false }
            gains[mode] = Double(frame.value); return true
        case .mainPage:
            guard freeze(cycle: wire.cycle, reason: "watch_page_changed") else { return false }
            mainPage = frame.value == 1; return true
        case .stopMovement:
            return freeze(cycle: wire.cycle, reason: "explicit_stop")
        case .startMovement:
            guard allowed(), mainPage, scope != .calibration, scope != .blindValidation else { return false }
            guard lease.start(cycle: wire.cycle) else { return false }
            mapper?.reset(); mapper = nil; context = nil; baseline = []
            onBreakClickPair(); startedAt = now; lastPoseAt = now
            journal.record("movement_preparing", detail: "cycle=\(wire.cycle)")
            onChange(); return true
        case .pose:
            return receivePose(wire, now: now)
        case .leftClick, .rightClick:
            guard let request = wire.click, request.id > lastClick, wire.sourceAge <= 0.15,
                  wire.cycle >= lease.cycle else { return false }
            lastClick = request.id // never retry even if eligibility changes below
            guard freeze(cycle: wire.cycle, reason: "click", breakPair: false),
                  allowed(), mainPage, scope != .calibration, scope != .blindValidation else { return false }
            // Freeze point is the already-processed position at receipt. There is
            // no wait for a last pose and no later motion can alter this request.
            let point = scope == .system ? cursor() : isolatedPoint
            return onClick(request, lease.session, point, now, scope)
        case .scroll:
            guard freeze(cycle: wire.cycle, reason: "crown"), mainPage, allowed() else { return false }
            return onWheel(LinearScroll.points(frame.value), scope)
        case .idle:
            return true // stop wheel accumulation, never re-enable movement
        default: return false
        }
    }
    private func receivePose(_ wire: PointerWire, now: Double) -> Bool {
        guard allowed(), mainPage, let sample = wire.sample, sample.isValid,
              wire.sourceAge <= MotionLimits.maxSampleAge else {
            freeze(reason: "stale_or_invalid_pose"); return false
        }
        if let previous = observed {
            if sample.referenceID != previous.referenceID || sample.reference != previous.reference || sample.wear != previous.wear {
                freeze(reason: "attitude_reference_changed"); invalidateCalibration("attitude_reference_or_wear_changed")
                observed = sample; latestSample = sample; return false
            }
            guard sample.sequence > previous.sequence, sample.watchTime > previous.watchTime else { return false }
        }
        observed = sample; latestSample = sample
        if scope == .calibration || scope == .blindValidation {
            onSample(sample, now); return true
        }
        guard lease.acceptsPose(session: wire.frame.session, cycle: wire.cycle) else { return false }
        lastPoseAt = now
        onSample(sample, now)
        if lease.phase == .preparing {
            guard now - startedAt >= 0.12 else { return true } // tap/gesture settling
            let point = scope == .system ? cursor() : isolatedPoint
            guard let screen = scope == .system ? screenAt(point) : activeScreen else { freeze(reason: "display_unavailable"); return false }
            if let first = baseline.first, first.attitude.angularDistance(to: sample.attitude) > 0.015 {
                baseline.removeAll(keepingCapacity: true)
            }
            baseline.append(sample)
            guard let first = baseline.first, baseline.count >= 3, sample.watchTime - first.watchTime >= 0.06 else { return true }
            activeScreen = screen
            let bound = MappingContext(session: lease.session, cycle: lease.cycle, screen: screen, sample: sample)
            context = bound
            switch mode {
            case .a: mapper = HeadingFollowingMapping(gainX: gains[.a]!, gainY: gains[.a]!)
            case .b: mapper = RollFollowingMapping(gainX: gains[.b]!, gainY: gains[.b]!)
            case .c: mapper = TiltJoystickMapping()
            case .d:
                guard let calibration else { freeze(reason: "calibration_required"); return false }
                mapper = DPointingMapping(calibration: calibration)
            }
            let result = mapper!.begin(sample: sample, context: bound)
            if case .stop = result { return apply(result) }
            guard lease.confirmBaseline(cycle: wire.cycle) else { return false }
            journal.record("movement_started", detail: "mode=\(mode.rawValue);cycle=\(wire.cycle)")
            onChange()
            return apply(result)
        }
        guard let context else { freeze(reason: "missing_mapping_context"); return false }
        return apply(mapper?.update(sample: sample, context: context) ?? .stop(.notStarted))
    }
    private func apply(_ result: PointerMappingResult) -> Bool {
        switch result {
        case .none: return true
        case .stop(let failure):
            freeze(reason: failure.rawValue)
            if failure == .calibrationRequired { invalidateCalibration(failure.rawValue) }
            return false
        case .relative(let delta):
            guard let screen = activeScreen else { return false }
            let origin = scope == .system ? cursor() : isolatedPoint
            return output(screen.clamp(origin + delta))
        case .absolute(let point):
            guard let screen = activeScreen else { return false }
            return output(screen.clamp(point))
        }
    }
    private func output(_ point: PointerPoint) -> Bool {
        guard allowed(), lease.phase == .moving, onMove(point, scope) else { freeze(reason: "movement_output_rejected"); return false }
        if scope != .system { isolatedPoint = point }
        return true
    }
}
