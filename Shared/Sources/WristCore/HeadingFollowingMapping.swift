import Foundation

/// A: heading and elevation of the pointing ray, in radians. No velocity or
/// acceleration; each update consumes all angular change since the last sample.
public struct HeadingFollowingMapping: PointerMapping {
    public let gainX: Double
    public let gainY: Double
    private var previous: AttitudeSample?
    private var binding: MappingContext?
    public init(gainX: Double = 1600, gainY: Double = 1600) { self.gainX = gainX; self.gainY = gainY }
    public mutating func reset() { previous = nil; binding = nil }
    public mutating func begin(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        reset()
        guard gainX.isFinite, gainY.isFinite, (100...8000).contains(gainX), (100...8000).contains(gainY) else { return .stop(.invalidParameters) }
        guard context.screen.isValid, context.matches(sample), DirectionFeatures(sample: sample) != nil else { return .stop(.invalidSample) }
        previous = sample; binding = context; return .none
    }
    public mutating func update(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        guard let old = previous, let binding else { return .stop(.notStarted) }
        guard binding == context else { reset(); return .stop(.contextChanged) }
        if let failure = MotionLimits.validate(sample, after: old, context: context) { reset(); return .stop(failure) }
        guard let a = DirectionFeatures(sample: old), let b = DirectionFeatures(sample: sample) else { reset(); return .stop(.invalidSample) }
        let heading = DirectionFeatures.wrappedDelta(b.heading, a.heading)
        let elevation = DirectionFeatures.wrappedDelta(b.elevation, a.elevation)
        guard abs(heading) <= MotionLimits.maxAngularStep, abs(elevation) <= MotionLimits.maxAngularStep else {
            reset(); return .stop(.discontinuity)
        }
        previous = sample
        let delta = PointerPoint(x: gainX * heading, y: -gainY * elevation)
        guard delta.isFinite else { reset(); return .stop(.invalidSample) }
        return delta == .zero ? .none : .relative(delta)
    }
}
