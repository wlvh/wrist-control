import Foundation

/// Failures are actionable: an unstable/repeated point can be collected again;
/// a changed binding invalidates the whole unfinished calibration.
public enum CalibrationFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration, invalidSample, contextChanged, reorderedSample, timeGap
    case insufficientSamples, unstable(rms: Double, maximum: Double)
    case wrongPointCount, wrongTarget(index: Int), repeatedDirection(index: Int)
    case insufficientCoverage, rankDeficient, illConditioned(Double)
    case poorFit(index: Int, rms: Double, maximum: Double), outsideCalibratedRegion, cancelled

    public var description: String {
        switch self {
        case .invalidConfiguration: return "标定参数无效"
        case .invalidSample: return "姿态无效或方向接近竖直，无法可靠定位"
        case .contextChanged: return "参考系、屏幕或佩戴配置已改变，请重新标定"
        case .reorderedSample: return "收到重复或倒序姿态，请重采当前点"
        case .timeGap: return "姿态传输中断，请重采当前点"
        case .insufficientSamples: return "稳定采样数量或时长不足"
        case .unstable: return "当前点晃动过大，请保持手臂支撑后重采"
        case .wrongPointCount: return "需要中心和四角的完整五点"
        case .wrongTarget: return "采集目标与五点顺序不一致"
        case .repeatedDirection: return "当前方向与已采点太接近，请对准目标后重采"
        case .insufficientCoverage: return "方向覆盖不足，请扩大五点之间的转向范围"
        case .rankDeficient: return "采集方向重合或共线，无法建立二维映射"
        case .illConditioned: return "两个方向过于接近，微小抖动会放大，请重采"
        case .poorFit: return "五点不能可靠地拟合，请保持坐姿并重采提示的点"
        case .outsideCalibratedRegion: return "方向超出标定附近的可靠范围，请重新对准或重校"
        case .cancelled: return "标定已取消，未保留半成品"
        }
    }

    public var suggestedPointIndex: Int? {
        switch self {
        case let .wrongTarget(index), let .repeatedDirection(index), let .poorFit(index, _, _): return index
        default: return nil
        }
    }
}

/// Initial experimental thresholds, not a claim about real-device accuracy.
public struct StableAttitudeConfiguration: Equatable, Sendable {
    public var duration: Double
    public var minimumSamples: Int
    public var maximumRMSRadians: Double
    public var maximumDeviationRadians: Double
    public init(duration: Double = 0.5, minimumSamples: Int = 10,
                maximumRMSRadians: Double = 0.015, maximumDeviationRadians: Double = 0.035) {
        self.duration = duration; self.minimumSamples = minimumSamples
        self.maximumRMSRadians = maximumRMSRadians; self.maximumDeviationRadians = maximumDeviationRadians
    }
    public var isValid: Bool {
        duration.isFinite && (0.1...3).contains(duration) && (3...128).contains(minimumSamples)
        && maximumRMSRadians.isFinite && maximumDeviationRadians.isFinite
        && maximumRMSRadians > 0 && maximumRMSRadians <= maximumDeviationRadians
        && maximumDeviationRadians <= 0.2
    }
}

public struct StableAttitudeWindow: Equatable, Sendable {
    /// Raw samples remain inspectable for this in-memory model and private evidence.
    public let samples: [AttitudeSample]
    public let meanSample: AttitudeSample
    public let rmsRadians: Double
    public let maxDeviationRadians: Double
    public var duration: Double { samples.last!.watchTime - samples.first!.watchTime }
    public var sampleRateHz: Double { Double(samples.count - 1) / duration }

    fileprivate init(samples: [AttitudeSample], configuration: StableAttitudeConfiguration) throws {
        guard let first = samples.first, let last = samples.last,
              let reference = first.attitude.normalized,
              samples.count >= configuration.minimumSamples,
              last.watchTime - first.watchTime + 1e-9 >= configuration.duration else {
            throw CalibrationFailure.insufficientSamples
        }
        // Hemisphere alignment makes alternating q/-q samples average to the
        // same rotation. Small, bounded windows permit a normalized chord mean.
        var sum = SIMD4<Double>.zero
        for sample in samples {
            guard let q = sample.attitude.normalized else { throw CalibrationFailure.invalidSample }
            let dot = reference.w*q.w + reference.x*q.x + reference.y*q.y + reference.z*q.z
            let sign = dot < 0 ? -1.0 : 1.0
            sum += sign * SIMD4(q.w, q.x, q.y, q.z)
        }
        sum /= Double(samples.count)
        guard let mean = AttitudeQuaternion(w: sum.x, x: sum.y, y: sum.z, z: sum.w).normalized else {
            throw CalibrationFailure.invalidSample
        }
        let deviations = samples.map { $0.attitude.angularDistance(to: mean) }
        let rms = sqrt(deviations.reduce(0) { $0 + $1*$1 } / Double(deviations.count))
        let maximum = deviations.max() ?? .infinity
        guard rms.isFinite, maximum.isFinite, rms <= configuration.maximumRMSRadians,
              maximum <= configuration.maximumDeviationRadians else {
            throw CalibrationFailure.unstable(rms: rms, maximum: maximum)
        }
        self.samples = samples; rmsRadians = rms; maxDeviationRadians = maximum
        meanSample = AttitudeSample(reference: last.reference, referenceID: last.referenceID,
            sequence: last.sequence, watchTime: last.watchTime, attitude: mean, wear: last.wear)
    }
}

/// Shared by calibration and blind validation. It uses only Watch-to-Watch
/// timestamp differences. Mac reception freshness belongs to the caller.
public struct StableAttitudeCollector {
    public let binding: CalibrationBinding
    public let configuration: StableAttitudeConfiguration
    public private(set) var samples: [AttitudeSample] = []
    public private(set) var completedWindow: StableAttitudeWindow?

    public init(binding: CalibrationBinding, configuration: StableAttitudeConfiguration = .init()) {
        self.binding = binding; self.configuration = configuration
    }
    public mutating func reset() { samples.removeAll(keepingCapacity: true); completedWindow = nil }

    /// Returns a window exactly once. Any failure discards the current window.
    public mutating func append(sample: AttitudeSample, screen: PointerScreen) throws -> StableAttitudeWindow? {
        do {
            guard configuration.isValid else { throw CalibrationFailure.invalidConfiguration }
            guard sample.isValid, DirectionFeatures(sample: sample) != nil else { throw CalibrationFailure.invalidSample }
            guard binding.matches(screen: screen, sample: sample) else { throw CalibrationFailure.contextChanged }
            guard completedWindow == nil else { return nil }
            if let previous = samples.last {
                guard sample.sequence > previous.sequence, sample.watchTime > previous.watchTime else {
                    throw CalibrationFailure.reorderedSample
                }
                guard sample.watchTime - previous.watchTime <= MotionLimits.streamTimeout else {
                    throw CalibrationFailure.timeGap
                }
                guard sample.attitude.angularDistance(to: previous.attitude) <= MotionLimits.maxAngularStep else {
                    throw CalibrationFailure.unstable(rms: .infinity, maximum: .infinity)
                }
            }
            // A bounded buffer also makes a caller's accidental high-rate feed safe.
            guard samples.count < 256 else { throw CalibrationFailure.insufficientSamples }
            samples.append(sample)
            guard samples.count >= configuration.minimumSamples,
                  sample.watchTime - samples[0].watchTime + 1e-9 >= configuration.duration else { return nil }
            let window = try StableAttitudeWindow(samples: samples, configuration: configuration)
            completedWindow = window
            return window
        } catch {
            reset()
            throw error
        }
    }
}

public struct CalibrationObservation: Equatable, Sendable {
    /// Normalized local screen coordinates, +x right and +y down.
    public let target: PointerPoint
    public let window: StableAttitudeWindow
    public init(target: PointerPoint, window: StableAttitudeWindow) { self.target = target; self.window = window }
}

public struct CalibrationFitConfiguration: Equatable, Sendable {
    public var minimumAxisSpan: Double = 0.08
    public var minimumPointSeparation: Double = 0.025
    public var minimumMinorSpread: Double = 0.015
    public var maximumConditionNumber: Double = 25
    public var maximumTrainingRMS: Double = 0.10
    public var maximumTrainingError: Double = 0.18
    public var maximumAnchorDistance: Double = 1.2
    /// Beyond the trained angular box, allow a half-span on each side.
    /// This covers the 10%-90% targets' modest edge extrapolation.
    public var extrapolationMargin: Double = 0.5
    public init() {}
    public var isValid: Bool {
        let positive = [minimumAxisSpan, minimumPointSeparation, minimumMinorSpread,
                        maximumConditionNumber, maximumTrainingRMS, maximumTrainingError, maximumAnchorDistance]
        return positive.allSatisfy { $0.isFinite && $0 > 0 }
            && maximumConditionNumber >= 1 && maximumTrainingError >= maximumTrainingRMS
            && maximumAnchorDistance < .pi/2 && extrapolationMargin.isFinite
            && (0...1).contains(extrapolationMargin)
    }
}

public struct AffinePointingCoefficients: Equatable, Sendable {
    public let intercept: Double
    public let heading: Double
    public let elevation: Double
    fileprivate func apply(_ point: PointerPoint) -> Double {
        intercept + heading * point.x + elevation * point.y
    }
}

public struct CalibrationQuality: Equatable, Sendable {
    public let headingSpan: Double
    public let elevationSpan: Double
    public let conditionNumber: Double
    public let minorSpreadRadians: Double
    public let trainingRMSNormalized: Double
    public let trainingMaximumNormalized: Double
    public let trainingRMSPoints: Double
    public let trainingMaximumPoints: Double
    public let maximumSamplingDeviationRadians: Double
}

public struct CalibrationPredictionError: Equatable, Sendable {
    public let calibrationID: UUID
    /// Never clipped to the display: clipping would under-report edge error.
    public let predicted: PointerPoint
    public let target: PointerPoint
    public let errorPoints: Double
}

/// In-memory, fixed-anchor affine model. Deliberately not Codable: coefficients
/// restored from disk must not silently become an active calibration.
public struct PointingCalibration: Equatable, Sendable {
    public static let modelVersion = 1
    public static let targets: [PointerPoint] = [
        PointerPoint(x: 0.5, y: 0.5), PointerPoint(x: 0.1, y: 0.1),
        PointerPoint(x: 0.9, y: 0.1), PointerPoint(x: 0.9, y: 0.9),
        PointerPoint(x: 0.1, y: 0.9)
    ]
    public let calibrationID: UUID
    public let binding: CalibrationBinding
    public let observations: [CalibrationObservation]
    public let quality: CalibrationQuality
    public let horizontal: AffinePointingCoefficients
    public let vertical: AffinePointingCoefficients
    public let anchorHeading: Double
    public let anchorElevation: Double
    public let configuration: CalibrationFitConfiguration
    private let featureMinimum: PointerPoint
    private let featureMaximum: PointerPoint

    private static func features(sample: AttitudeSample, heading: Double, elevation: Double) throws -> PointerPoint {
        guard let direction = DirectionFeatures(sample: sample) else { throw CalibrationFailure.invalidSample }
        return PointerPoint(x: DirectionFeatures.wrappedDelta(direction.heading, heading),
                            y: DirectionFeatures.wrappedDelta(direction.elevation, elevation))
    }

    public static func fit(observations: [CalibrationObservation], screen: PointerScreen,
                           calibrationID: UUID = UUID(),
                           configuration: CalibrationFitConfiguration = .init()) throws -> Self {
        guard screen.isValid, screen.point(normalized: PointerPoint(x: 1, y: 1)).isFinite,
              configuration.isValid else { throw CalibrationFailure.invalidConfiguration }
        guard observations.count == targets.count else { throw CalibrationFailure.wrongPointCount }
        let first = observations[0].window.meanSample
        let binding = CalibrationBinding(screen: screen, sample: first)
        guard let anchor = DirectionFeatures(sample: first) else { throw CalibrationFailure.invalidSample }
        var features: [PointerPoint] = []
        for (index, observation) in observations.enumerated() {
            guard observation.target.isFinite, observation.target.distance(to: targets[index]) <= 1e-9 else {
                throw CalibrationFailure.wrongTarget(index: index)
            }
            guard binding.matches(screen: screen, sample: observation.window.meanSample) else {
                throw CalibrationFailure.contextChanged
            }
            let point = try Self.features(sample: observation.window.meanSample, heading: anchor.heading, elevation: anchor.elevation)
            guard hypot(point.x, point.y) <= configuration.maximumAnchorDistance else {
                throw CalibrationFailure.outsideCalibratedRegion
            }
            for previous in features where point.distance(to: previous) < configuration.minimumPointSeparation {
                throw CalibrationFailure.repeatedDirection(index: index)
            }
            features.append(point)
        }
        let low = PointerPoint(x: features.map(\.x).min()!, y: features.map(\.y).min()!)
        let high = PointerPoint(x: features.map(\.x).max()!, y: features.map(\.y).max()!)
        let count = Double(features.count)
        let mean = PointerPoint(x: features.map(\.x).reduce(0, +)/count, y: features.map(\.y).reduce(0, +)/count)
        let centered = features.map { PointerPoint(x: $0.x-mean.x, y: $0.y-mean.y) }
        let aa = centered.reduce(0) { $0 + $1.x*$1.x }
        let bb = centered.reduce(0) { $0 + $1.y*$1.y }
        let ab = centered.reduce(0) { $0 + $1.x*$1.y }
        // Centering separates the intercept from the two slope columns. These
        // eigenvalues inspect the actual 2-D angular geometry before inversion.
        let determinant = aa*bb - ab*ab
        let largestEigenvalue = (aa + bb + hypot(aa-bb, 2*ab))/2
        guard largestEigenvalue.isFinite, largestEigenvalue > 0,
              determinant.isFinite, determinant > largestEigenvalue*largestEigenvalue*1e-12 else {
            throw CalibrationFailure.rankDeficient
        }
        let smallestEigenvalue = determinant/largestEigenvalue
        let condition = sqrt(largestEigenvalue/smallestEigenvalue)
        guard condition <= configuration.maximumConditionNumber else { throw CalibrationFailure.illConditioned(condition) }
        let minorSpread = sqrt(smallestEigenvalue/count)
        guard high.x-low.x >= configuration.minimumAxisSpan, high.y-low.y >= configuration.minimumAxisSpan,
              minorSpread >= configuration.minimumMinorSpread else { throw CalibrationFailure.insufficientCoverage }

        func solve(_ targetValues: [Double]) throws -> AffinePointingCoefficients {
            let targetMean = targetValues.reduce(0, +)/count
            var at = 0.0, bt = 0.0
            for index in centered.indices {
                at += centered[index].x * (targetValues[index]-targetMean)
                bt += centered[index].y * (targetValues[index]-targetMean)
            }
            let heading = (bb*at-ab*bt)/determinant
            let elevation = (aa*bt-ab*at)/determinant
            let intercept = targetMean-heading*mean.x-elevation*mean.y
            guard [intercept, heading, elevation].allSatisfy(\.isFinite) else { throw CalibrationFailure.rankDeficient }
            return AffinePointingCoefficients(intercept: intercept, heading: heading, elevation: elevation)
        }
        let horizontal = try solve(observations.map { $0.target.x })
        let vertical = try solve(observations.map { $0.target.y })
        var errors: [Double] = [], pointErrors: [Double] = []
        for index in features.indices {
            let predicted = PointerPoint(x: horizontal.apply(features[index]), y: vertical.apply(features[index]))
            errors.append(predicted.distance(to: observations[index].target))
            pointErrors.append(screen.point(normalized: predicted).distance(to: screen.point(normalized: observations[index].target)))
        }
        let rms = sqrt(errors.reduce(0) { $0+$1*$1 }/count)
        let maximum = errors.max()!
        let pointRMS = sqrt(pointErrors.reduce(0) { $0+$1*$1 }/count)
        guard pointRMS.isFinite, pointErrors.allSatisfy(\.isFinite) else { throw CalibrationFailure.invalidConfiguration }
        guard rms.isFinite, maximum.isFinite, rms <= configuration.maximumTrainingRMS,
              maximum <= configuration.maximumTrainingError else {
            throw CalibrationFailure.poorFit(index: errors.firstIndex(of: maximum) ?? 4, rms: rms, maximum: maximum)
        }
        let quality = CalibrationQuality(headingSpan: high.x-low.x, elevationSpan: high.y-low.y,
            conditionNumber: condition, minorSpreadRadians: minorSpread,
            trainingRMSNormalized: rms, trainingMaximumNormalized: maximum,
            trainingRMSPoints: pointRMS,
            trainingMaximumPoints: pointErrors.max()!,
            maximumSamplingDeviationRadians: observations.map { $0.window.maxDeviationRadians }.max()!)
        return Self(calibrationID: calibrationID, binding: binding, observations: observations, quality: quality,
                    horizontal: horizontal, vertical: vertical, anchorHeading: anchor.heading,
                    anchorElevation: anchor.elevation, configuration: configuration,
                    featureMinimum: low, featureMaximum: high)
    }

    public func isValid(sample: AttitudeSample, screen: PointerScreen) -> Bool {
        binding.matches(screen: screen, sample: sample)
    }

    public func predictRaw(sample: AttitudeSample, screen: PointerScreen) throws -> PointerPoint {
        guard sample.isValid else { throw CalibrationFailure.invalidSample }
        guard binding.matches(screen: screen, sample: sample) else { throw CalibrationFailure.contextChanged }
        let point = try Self.features(sample: sample, heading: anchorHeading, elevation: anchorElevation)
        let marginX = (featureMaximum.x-featureMinimum.x) * configuration.extrapolationMargin
        let marginY = (featureMaximum.y-featureMinimum.y) * configuration.extrapolationMargin
        guard hypot(point.x, point.y) <= configuration.maximumAnchorDistance,
              point.x >= featureMinimum.x-marginX, point.x <= featureMaximum.x+marginX,
              point.y >= featureMinimum.y-marginY, point.y <= featureMaximum.y+marginY else {
            throw CalibrationFailure.outsideCalibratedRegion
        }
        let result = screen.point(normalized: PointerPoint(x: horizontal.apply(point), y: vertical.apply(point)))
        guard result.isFinite else { throw CalibrationFailure.invalidSample }
        return result
    }

    public func predict(sample: AttitudeSample, screen: PointerScreen) throws -> PointerPoint {
        screen.clamp(try predictRaw(sample: sample, screen: screen))
    }

    public func predictionError(sample: AttitudeSample, screen: PointerScreen,
                                target: PointerPoint) throws -> CalibrationPredictionError {
        guard target.isFinite else { throw CalibrationFailure.invalidSample }
        let predicted = try predictRaw(sample: sample, screen: screen)
        let distance = predicted.distance(to: target)
        guard distance.isFinite else { throw CalibrationFailure.invalidSample }
        return CalibrationPredictionError(calibrationID: calibrationID, predicted: predicted,
                                          target: target, errorPoints: distance)
    }
}

/// Stores only this attempted calibration. A failed point can be replaced
/// without losing the other four; an invalid binding clears all partial work.
public struct PointingCalibrationDraft {
    public let screen: PointerScreen
    public private(set) var observations: [CalibrationObservation?] = Array(repeating: nil, count: 5)
    public private(set) var binding: CalibrationBinding?
    public private(set) var isCancelled = false
    public init(screen: PointerScreen) { self.screen = screen }
    public mutating func cancel() {
        observations = Array(repeating: nil, count: 5); binding = nil; isCancelled = true
    }
    public mutating func removePoint(at index: Int) {
        guard observations.indices.contains(index) else { return }
        observations[index] = nil
    }
    public mutating func record(window: StableAttitudeWindow, at index: Int) throws {
        guard !isCancelled else { throw CalibrationFailure.cancelled }
        guard screen.isValid, observations.indices.contains(index) else { throw CalibrationFailure.invalidConfiguration }
        if let binding, !binding.matches(screen: screen, sample: window.meanSample) {
            cancel(); throw CalibrationFailure.contextChanged
        }
        if binding == nil { binding = CalibrationBinding(screen: screen, sample: window.meanSample) }
        guard let incoming = DirectionFeatures(sample: window.meanSample) else { throw CalibrationFailure.invalidSample }
        for (otherIndex, observation) in observations.enumerated() where otherIndex != index {
            guard let observation, let other = DirectionFeatures(sample: observation.window.meanSample) else { continue }
            let distance = hypot(DirectionFeatures.wrappedDelta(incoming.heading, other.heading), incoming.elevation-other.elevation)
            guard distance >= CalibrationFitConfiguration().minimumPointSeparation else {
                throw CalibrationFailure.repeatedDirection(index: index)
            }
        }
        observations[index] = CalibrationObservation(target: PointingCalibration.targets[index], window: window)
    }
    public func fit() throws -> PointingCalibration {
        guard !isCancelled else { throw CalibrationFailure.cancelled }
        return try PointingCalibration.fit(observations: observations.compactMap { $0 }, screen: screen)
    }
}

/// Absolute output never depends on a previous pointer location. reset() ends a
/// movement cycle but deliberately retains the valid calibration across freezes.
public struct DPointingMapping: PointerMapping {
    public let calibration: PointingCalibration
    private var context: MappingContext?
    private var previous: AttitudeSample?
    public init(calibration: PointingCalibration) { self.calibration = calibration }
    public mutating func reset() { context = nil; previous = nil }
    private mutating func stop(_ reason: MappingFailure) -> PointerMappingResult { reset(); return .stop(reason) }

    public mutating func begin(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        reset()
        guard context.session != 0, context.cycle != 0, context.screen.isValid else { return stop(.invalidParameters) }
        guard sample.isValid else { return stop(.invalidSample) }
        guard context.matches(sample), calibration.binding.matches(screen: context.screen, sample: sample) else {
            return stop(.calibrationRequired)
        }
        do {
            let point = try calibration.predict(sample: sample, screen: context.screen)
            self.context = context; previous = sample
            return .absolute(point)
        } catch { return stop(.invalidSample) }
    }
    public mutating func update(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult {
        guard let established = self.context, let previous else { return .stop(.notStarted) }
        guard established == context else { return stop(.contextChanged) }
        guard calibration.binding.matches(screen: context.screen, sample: sample) else {
            return stop(sample.isValid ? .calibrationRequired : .invalidSample)
        }
        if let failure = MotionLimits.validate(sample, after: previous, context: context) { return stop(failure) }
        do {
            let point = try calibration.predict(sample: sample, screen: context.screen)
            self.previous = sample
            return .absolute(point)
        } catch { return stop(.invalidSample) }
    }
}
