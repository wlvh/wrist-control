import Foundation

/// Mode B: anatomical forearm roll moves right/left, elevation moves up/down.
/// Gains are Quartz logical points per radian, independent of Retina scale.
/// This type retains the last pose, never a virtual cursor outside the screen.
public struct RollFollowingMapping: PointerMapping, Sendable {
    public static let minimumGain = 100.0
    public static let maximumGain = 8_000.0
    public let gainX: Double
    public let gainY: Double
    private var state: BCMappingState?
    private var previousFeatures: DirectionFeatures?

    public init(gainX: Double = 1_600, gainY: Double = 1_600) {
        self.gainX = gainX
        self.gainY = gainY
    }

    public mutating func begin(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        reset()
        guard [gainX, gainY].allSatisfy({
            $0.isFinite && (Self.minimumGain...Self.maximumGain).contains($0)
        }) else {
            return .stop(.invalidParameters)
        }
        if let failure = BCMappingState.validateBeginning(sample: sample, context: context) {
            return .stop(failure)
        }
        guard let features = DirectionFeatures(sample: sample) else { return .stop(.invalidSample) }
        state = BCMappingState(previous: sample, context: context)
        previousFeatures = features
        return .none
    }

    public mutating func update(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        guard let state, let previousFeatures else { return .stop(.notStarted) }
        if let failure = state.validate(sample: sample, context: context) { return stop(failure) }
        guard let features = DirectionFeatures(sample: sample) else { return stop(.invalidSample) }
        let rollDelta = DirectionFeatures.wrappedDelta(features.roll, previousFeatures.roll)
        let elevationDelta = DirectionFeatures.wrappedDelta(features.elevation, previousFeatures.elevation)
        // Two individually valid samples can straddle the vertical singularity
        // while the intervening undefined pose was never delivered.
        guard abs(rollDelta) <= MotionLimits.maxAngularStep,
              abs(elevationDelta) <= MotionLimits.maxAngularStep else { return stop(.discontinuity) }
        let delta = PointerPoint(
            x: gainX * rollDelta,
            y: -gainY * elevationDelta
        )
        guard delta.isFinite else { return stop(.invalidSample) }
        self.state = BCMappingState(previous: sample, context: context)
        self.previousFeatures = features
        return delta == .zero ? .none : .relative(delta)
    }

    public mutating func reset() {
        state = nil
        previousFeatures = nil
    }

    private mutating func stop(_ failure: MappingFailure) -> PointerMappingResult {
        reset()
        return .stop(failure)
    }
}

/// Persist separately from A/B gain settings. These defaults are trial starting
/// values, not measurements of comfort, accuracy or latency on an actual wrist.
public struct JoystickParameters: Equatable, Codable, Sendable {
    public var deadZoneRadians: Double
    public var fullSpeedRadians: Double
    public var exponent: Double
    public var maxScreenWidthsPerSecond: Double

    public init(deadZoneRadians: Double = 1.5 * .pi / 180,
                fullSpeedRadians: Double = 12 * .pi / 180,
                exponent: Double = 1.5,
                maxScreenWidthsPerSecond: Double = 1) {
        self.deadZoneRadians = deadZoneRadians
        self.fullSpeedRadians = fullSpeedRadians
        self.exponent = exponent
        self.maxScreenWidthsPerSecond = maxScreenWidthsPerSecond
    }

    /// Finite, bounded tuning ranges prevent corrupt persisted values from
    /// turning a small pose change into an unbounded event. Validation also runs
    /// at begin(), because Codable deliberately preserves the supplied values.
    public var isValid: Bool {
        deadZoneRadians.isFinite && fullSpeedRadians.isFinite && exponent.isFinite
        && maxScreenWidthsPerSecond.isFinite
        && deadZoneRadians >= 0 && fullSpeedRadians > deadZoneRadians
        && fullSpeedRadians <= .pi / 2
        && exponent > 0 && exponent <= 8
        && maxScreenWidthsPerSecond > 0 && maxScreenWidthsPerSecond <= 4
    }
}

/// Mode C: deviation from the begin pose controls speed. The neutral +y ray is
/// the forward direction; its tangent plane uses +x right and -z screen-down.
/// Roll about that ray does not move the cursor. Wrist side affects B only;
/// crown orientation is corrected by AttitudeSample.canonicalAttitude.
///
/// Every update consumes one strictly newer Watch sample. The latest sample's
/// speed is multiplied by that sample's Watch-time delta (rectangle rule).
/// There is no timer, last-speed replay, cursor position, or accumulated debt.
/// The owner still expires its movement lease when no sample arrives.
public struct TiltJoystickMapping: PointerMapping, Sendable {
    public let parameters: JoystickParameters
    private var state: BCMappingState?
    private var neutral: AttitudeQuaternion?
    private var maxPointsPerSecond: Double = 0

    public init(parameters: JoystickParameters = JoystickParameters()) {
        self.parameters = parameters
    }

    public mutating func begin(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        reset()
        guard parameters.isValid else { return .stop(.invalidParameters) }
        if let failure = BCMappingState.validateBeginning(sample: sample, context: context) {
            return .stop(failure)
        }
        let speed = context.screen.width * parameters.maxScreenWidthsPerSecond
        guard speed.isFinite, speed > 0 else { return .stop(.invalidParameters) }
        guard let attitude = sample.canonicalAttitude else { return .stop(.invalidSample) }
        state = BCMappingState(previous: sample, context: context)
        neutral = attitude
        maxPointsPerSecond = speed
        return .none
    }

    public mutating func update(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        guard let state, let neutral else { return .stop(.notStarted) }
        if let failure = state.validate(sample: sample, context: context) { return stop(failure) }
        guard let attitude = sample.canonicalAttitude else { return stop(.invalidSample) }
        guard let offset = Self.angularOffset(neutral.inverse * attitude) else {
            return stop(.discontinuity)
        }
        let radius = hypot(offset.x, offset.y)
        let dt = sample.watchTime - state.previous.watchTime
        self.state = BCMappingState(previous: sample, context: context)
        guard radius > parameters.deadZoneRadians else { return .none }
        let fraction = min(1, (radius - parameters.deadZoneRadians)
                                / (parameters.fullSpeedRadians - parameters.deadZoneRadians))
        let distance = maxPointsPerSecond * pow(fraction, parameters.exponent) * dt
        let delta = PointerPoint(x: offset.x / radius * distance, y: offset.y / radius * distance)
        guard delta.isFinite else { return stop(.invalidSample) }
        return delta == .zero ? .none : .relative(delta)
    }

    public mutating func reset() {
        state = nil
        neutral = nil
        maxPointsPerSecond = 0
    }

    /// The vector length is the spherical angle from the neutral forward ray.
    /// This radial construction gives one speed cap for diagonal motion too.
    /// Beyond the neutral forward hemisphere, stop instead of allowing a
    /// pointing reversal to pass through the ambiguous antipodal direction.
    private static func angularOffset(_ relative: AttitudeQuaternion) -> PointerPoint? {
        let forward = relative.rotated(SIMD3(0, 1, 0))
        guard forward.x.isFinite, forward.y.isFinite, forward.z.isFinite, forward.y >= 0 else { return nil }
        let transverse = hypot(forward.x, forward.z)
        guard transverse > 1e-12 else { return .zero }
        let angle = atan2(transverse, forward.y)
        return PointerPoint(x: angle * forward.x / transverse, y: -angle * forward.z / transverse)
    }

    private mutating func stop(_ failure: MappingFailure) -> PointerMappingResult {
        reset()
        return .stop(failure)
    }
}

private struct BCMappingState: Sendable {
    let previous: AttitudeSample
    let context: MappingContext

    static func validateBeginning(sample: AttitudeSample, context: MappingContext) -> MappingFailure? {
        guard sample.isValid else { return .invalidSample }
        guard context.session != 0, context.cycle != 0, context.screen.isValid, context.matches(sample) else {
            return .contextChanged
        }
        return nil
    }

    func validate(sample: AttitudeSample, context: MappingContext) -> MappingFailure? {
        guard self.context == context else { return .contextChanged }
        return MotionLimits.validate(sample, after: previous, context: context)
    }
}
