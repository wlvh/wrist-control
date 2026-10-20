import Foundation

public enum PointerMode: UInt8, Codable, CaseIterable, Sendable { case a = 1, b, c, d }
public enum AttitudeReference: UInt8, Codable, Sendable { case arbitraryZVertical = 1, correctedZVertical }
public enum WristSide: UInt8, Codable, Sendable { case left = 0, right }
public enum CrownSide: UInt8, Codable, Sendable { case right = 0, left }

public struct WearConfiguration: Equatable, Codable, Sendable {
    public var wrist: WristSide
    public var crown: CrownSide
    public init(wrist: WristSide = .left, crown: CrownSide = .right) { self.wrist = wrist; self.crown = crown }
    public var rollSign: Double { wrist == .left ? 1 : -1 }
}

public struct PointerPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public static let zero = Self()
    public func distance(to p: Self) -> Double { hypot(x - p.x, y - p.y) }
    public static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
}

/// Quartz desktop logical coordinates: +x right, +y down. Scale is metadata,
/// NEVER a multiplier on a system-event location. Layout ID changes on re-layout.
public struct PointerScreen: Equatable, Codable, Sendable {
    public let displayID: UInt32
    public let layoutID: UInt64
    public let origin: PointerPoint
    public let width: Double
    public let height: Double
    public let backingScale: Double
    public init(displayID: UInt32, layoutID: UInt64, origin: PointerPoint = .zero,
                width: Double, height: Double, backingScale: Double = 1) {
        self.displayID = displayID; self.layoutID = layoutID; self.origin = origin
        self.width = width; self.height = height; self.backingScale = backingScale
    }
    public var isValid: Bool {
        origin.isFinite && width.isFinite && height.isFinite && width > 1 && height > 1
        && backingScale.isFinite && backingScale > 0 && layoutID != 0
    }
    public func clamp(_ p: PointerPoint) -> PointerPoint {
        PointerPoint(x: min(origin.x + width - 1, max(origin.x, p.x)),
                     y: min(origin.y + height - 1, max(origin.y, p.y)))
    }
    public func point(normalized p: PointerPoint) -> PointerPoint {
        PointerPoint(x: origin.x + p.x * width, y: origin.y + p.y * height)
    }
    public static func appKitToQuartz(_ p: PointerPoint, primaryHeight: Double) -> PointerPoint {
        PointerPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// Right-handed active rotation from device coordinates into the Core Motion
/// reference. Raw device axes: x across face, y along its long edge, z outward.
/// q and -q are equivalent. No Euler-angle subtraction is part of this type.
public struct AttitudeQuaternion: Equatable, Codable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double
    public init(w: Double = 1, x: Double = 0, y: Double = 0, z: Double = 0) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }
    public static let identity = Self()
    public var normalized: Self? {
        let n = sqrt(w*w + x*x + y*y + z*z)
        guard n.isFinite, (0.5...1.5).contains(n) else { return nil }
        return Self(w: w/n, x: x/n, y: y/n, z: z/n)
    }
    public var inverse: Self { Self(w: w, x: -x, y: -y, z: -z) }
    public static func * (a: Self, b: Self) -> Self {
        Self(w: a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
             x: a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
             y: a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
             z: a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w)
    }
    public func rotated(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let p = self * Self(w: 0, x: v.x, y: v.y, z: v.z) * inverse
        return SIMD3(p.x, p.y, p.z)
    }
    public func angularDistance(to other: Self) -> Double {
        guard let a = normalized, let b = other.normalized else { return .infinity }
        let dot = abs(a.w*b.w+a.x*b.x+a.y*b.y+a.z*b.z)
        return 2 * acos(min(1, max(0, dot)))
    }
    public static func rotation(axis: SIMD3<Double>, radians: Double) -> Self {
        let n = sqrt(axis.x*axis.x + axis.y*axis.y + axis.z*axis.z)
        guard n.isFinite, n > 0, radians.isFinite else { return Self(w: .nan) }
        let s = sin(radians/2) / n
        return Self(w: cos(radians/2), x: axis.x*s, y: axis.y*s, z: axis.z*s)
    }
}

public struct AttitudeSample: Equatable, Codable, Sendable {
    public let reference: AttitudeReference
    public let referenceID: UInt64
    public let sequence: UInt32
    /// Watch monotonic seconds at sensor sampling, never a Mac timestamp.
    public let watchTime: Double
    public let attitude: AttitudeQuaternion
    public let wear: WearConfiguration
    public init(reference: AttitudeReference = .arbitraryZVertical, referenceID: UInt64,
                sequence: UInt32, watchTime: Double, attitude: AttitudeQuaternion,
                wear: WearConfiguration = WearConfiguration()) {
        self.reference = reference; self.referenceID = referenceID; self.sequence = sequence
        self.watchTime = watchTime; self.attitude = attitude; self.wear = wear
    }
    public var isValid: Bool { referenceID != 0 && sequence != 0 && watchTime.isFinite && watchTime >= 0 && attitude.normalized != nil }
    public var canonicalAttitude: AttitudeQuaternion? {
        guard let q = attitude.normalized else { return nil }
        let faceRotation = wear.crown == .left ? AttitudeQuaternion(w: 0, z: 1) : .identity
        return q * faceRotation
    }
}

/// Body pointing axis is canonical +y, face normal +z. Crown-left rotates the
/// face basis by pi about z. Wrist side reverses B's anatomical roll sign only.
/// Heading/elevation are continuous locally; differences MUST use wrappedDelta.
public struct DirectionFeatures: Equatable, Sendable {
    public let heading: Double
    public let elevation: Double
    public let roll: Double
    public init?(sample: AttitudeSample) {
        guard sample.isValid, let q = sample.canonicalAttitude else { return nil }
        let forward = q.rotated(SIMD3(0, 1, 0))
        let right = q.rotated(SIMD3(1, 0, 0))
        let normal = q.rotated(SIMD3(0, 0, 1))
        let horizontal = hypot(forward.x, forward.y)
        guard horizontal > 0.08 else { return nil } // heading/roll undefined near vertical
        heading = atan2(forward.x, forward.y)
        elevation = atan2(forward.z, horizontal)
        roll = atan2(right.z, normal.z) * sample.wear.rollSign
    }
    public static func wrappedDelta(_ a: Double, _ b: Double) -> Double { atan2(sin(a-b), cos(a-b)) }
}

public struct MappingContext: Equatable, Codable, Sendable {
    public let session: UInt64
    public let cycle: UInt32
    public let screen: PointerScreen
    public let reference: AttitudeReference
    public let referenceID: UInt64
    public let wear: WearConfiguration
    public init(session: UInt64, cycle: UInt32, screen: PointerScreen, sample: AttitudeSample) {
        self.session = session; self.cycle = cycle; self.screen = screen
        reference = sample.reference; referenceID = sample.referenceID; wear = sample.wear
    }
    public func matches(_ sample: AttitudeSample) -> Bool {
        sample.isValid && sample.referenceID == referenceID && sample.reference == reference && sample.wear == wear
    }
}

/// Unlike a movement cycle, this binding survives a short freeze. A new sensor
/// reference, process-scoped layout ID, screen geometry or wear config invalidates it.
public struct CalibrationBinding: Equatable, Codable, Sendable {
    public let screen: PointerScreen
    public let reference: AttitudeReference
    public let referenceID: UInt64
    public let wear: WearConfiguration
    public init(screen: PointerScreen, sample: AttitudeSample) {
        self.screen = screen; reference = sample.reference; referenceID = sample.referenceID; wear = sample.wear
    }
    public func matches(screen: PointerScreen, sample: AttitudeSample) -> Bool {
        screen.isValid && self.screen == screen && sample.isValid && sample.reference == reference
        && sample.referenceID == referenceID && sample.wear == wear
    }
}

public enum MappingFailure: String, Error, Codable, Sendable {
    case invalidSample, invalidParameters, contextChanged, reorderedSample, timeGap, discontinuity, notStarted, calibrationRequired
}
public enum PointerMappingResult: Equatable, Sendable {
    case none
    case relative(PointerPoint)
    case absolute(PointerPoint)
    case stop(MappingFailure)
}
public protocol PointerMapping {
    /// Called exactly once after a new cycle has a fresh, stable baseline.
    /// A/B/C return none. D may return absolute under a valid existing model.
    mutating func begin(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult
    mutating func update(sample: AttitudeSample, context: MappingContext) -> PointerMappingResult
    mutating func reset()
}

public enum MotionLimits {
    public static let maxSampleAge = 0.08
    public static let maxQueueAge = 0.06
    public static let streamTimeout = 0.15
    public static let maxAngularStep = 0.55
    public static func validate(_ sample: AttitudeSample, after previous: AttitudeSample, context: MappingContext) -> MappingFailure? {
        guard sample.isValid else { return .invalidSample }
        guard context.matches(sample) else { return .contextChanged }
        guard sample.sequence > previous.sequence, sample.watchTime > previous.watchTime else { return .reorderedSample }
        guard sample.watchTime - previous.watchTime <= streamTimeout else { return .timeGap }
        guard sample.attitude.angularDistance(to: previous.attitude) <= maxAngularStep else { return .discontinuity }
        return nil
    }
}

public enum PointerPhase: UInt8, Codable, Sendable { case reading = 0, preparing, moving, paused }
public enum OutputScope: UInt8, Codable, Sendable { case system = 0, calibration, practice, blindValidation }
public enum PointerButton: UInt8, Codable, Sendable { case left = 1, right }
public struct ClickRequest: Equatable, Sendable {
    public let id: UInt64
    public let button: PointerButton
    public let watchTime: Double
    public let cycle: UInt32
    public init(id: UInt64, button: PointerButton, watchTime: Double, cycle: UInt32) {
        self.id = id; self.button = button; self.watchTime = watchTime; self.cycle = cycle
    }
}

/// Client intent revisions are monotonic within an authenticated logical session.
/// Every explicit start/freeze/mode/click barrier gets a new cycle. A closed
/// cycle can never reopen itself from an arriving pose. Total pause is separate.
public struct MovementLease {
    public private(set) var session: UInt64 = 0
    public private(set) var cycle: UInt32 = 0
    public private(set) var phase: PointerPhase = .paused
    public init() {}
    public mutating func newSession(_ value: UInt64, enabled: Bool) {
        session = value; cycle = 0; phase = enabled ? .reading : .paused
    }
    public mutating func start(cycle next: UInt32) -> Bool {
        guard session != 0, phase != .paused, next > cycle else { return false }
        cycle = next; phase = .preparing; return true
    }
    public mutating func confirmBaseline(cycle value: UInt32) -> Bool {
        guard value == cycle, phase == .preparing else { return false }
        phase = .moving; return true
    }
    @discardableResult public mutating func freeze(cycle value: UInt32? = nil) -> Bool {
        if let value { guard value >= cycle else { return false }; cycle = value }
        if phase != .paused { phase = .reading }
        return true
    }
    public mutating func setEnabled(_ enabled: Bool) { phase = enabled ? .reading : .paused }
    public func acceptsPose(session value: UInt64, cycle valueCycle: UInt32) -> Bool {
        value == session && session != 0 && cycle == valueCycle && (phase == .preparing || phase == .moving)
    }
}
