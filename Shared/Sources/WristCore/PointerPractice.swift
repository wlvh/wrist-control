import Foundation

/// An area of the selected display in Quartz global logical units. It is kept
/// in the evidence so a run in a smaller window is never described as full-screen.
public struct PracticeRegion: Equatable, Codable, Sendable {
    public let origin: PointerPoint
    public let width: Double
    public let height: Double
    public init(origin: PointerPoint, width: Double, height: Double) {
        self.origin = origin; self.width = width; self.height = height
    }
    public func contains(_ p: PointerPoint, inset: Double = 0) -> Bool {
        p.isFinite && p.x >= origin.x + inset && p.x <= origin.x + width - inset
        && p.y >= origin.y + inset && p.y <= origin.y + height - inset
    }
    public func point(x: Double, y: Double) -> PointerPoint {
        PointerPoint(x: origin.x + x * width, y: origin.y + y * height)
    }
    public func isValid(in screen: PointerScreen) -> Bool {
        screen.isValid && origin.isFinite && width.isFinite && height.isFinite && width >= 120 && height >= 120
        && origin.x >= screen.origin.x && origin.y >= screen.origin.y
        && origin.x + width <= screen.origin.x + screen.width
        && origin.y + height <= screen.origin.y + screen.height
    }
}

public struct PracticeTarget: Equatable, Codable, Sendable {
    public let id: Int
    public let center: PointerPoint
    /// Diameter, not radius, in screen logical units. Backing scale is not applied.
    public let diameter: Double
    public init(id: Int, center: PointerPoint, diameter: Double) {
        self.id = id; self.center = center; self.diameter = diameter
    }
    public func contains(_ point: PointerPoint) -> Bool { point.isFinite && center.distance(to: point) <= diameter / 2 }
}

public enum PracticeStage: String, Codable, Sendable { case warmup, formal }
public enum PracticeSource: String, Codable, CaseIterable, Sendable {
    case a, b, c, d, mouseReference
    public var mode: PointerMode? {
        switch self { case .a: return .a; case .b: return .b; case .c: return .c; case .d: return .d; case .mouseReference: return nil }
    }
}
public enum PracticeError: String, Error { case invalidRegion, invalidTarget, invalidCount, invalidTime, noIndependentTargets }
public enum PracticeOutcome: String, Codable, Sendable { case hit, timeout, skipped, aborted }
public enum PracticeClickFailure: String, Codable, Sendable { case miss, wrongButton, extraClick }

/// The user/integrator supplies these facts; unknown is deliberately not replaced
/// with the source tree's current HEAD or an assumed installed build.
public struct PracticeMetadata: Codable, Sendable {
    public var runID: String
    public var macBuild: String
    public var watchBuild: String
    public var sourceSHA: String
    public var posture: String
    public var transport: String
    public var modeParameters: String
    public var referenceID: UInt64?
    public var calibrationID: UUID?
    public init(runID: String = UUID().uuidString, macBuild: String = "待记录", watchBuild: String = "待记录",
                sourceSHA: String = "待记录", posture: String = "待记录", transport: String = "待记录",
                modeParameters: String = "默认参数；实际值待记录", referenceID: UInt64? = nil, calibrationID: UUID? = nil) {
        self.runID = runID; self.macBuild = macBuild; self.watchBuild = watchBuild; self.sourceSHA = sourceSHA
        self.posture = posture; self.transport = transport; self.modeParameters = modeParameters
        self.referenceID = referenceID; self.calibrationID = calibrationID
    }
}

public struct PracticeConfiguration: Codable, Sendable {
    public let screen: PointerScreen
    public let region: PracticeRegion
    public let source: PracticeSource
    public let stage: PracticeStage
    public let seed: UInt64
    public let sessionIndex: Int
    public let modeOrder: [PointerMode]
    public let timeoutSeconds: Double
    public let metadata: PracticeMetadata
    public init(screen: PointerScreen, region: PracticeRegion, source: PracticeSource, stage: PracticeStage,
                seed: UInt64, sessionIndex: Int, timeoutSeconds: Double = 30, metadata: PracticeMetadata = .init()) {
        self.screen = screen; self.region = region; self.source = source; self.stage = stage
        self.seed = seed; self.sessionIndex = sessionIndex; modeOrder = PointerPracticeSchedule.modeOrder(sessionIndex: sessionIndex)
        self.timeoutSeconds = timeoutSeconds; self.metadata = metadata
    }
}

public enum PointerPracticeSchedule {
    public static let targetDiameters: [Double] = [24, 48, 96]
    /// Rotation balances order across successive sessions; it does not claim to
    /// eliminate learning/fatigue within one four-mode comparison.
    public static func modeOrder(sessionIndex: Int) -> [PointerMode] {
        let all = PointerMode.allCases, offset = ((sessionIndex % 4) + 4) % 4
        return Array(all[offset...] + all[..<offset])
    }
    public static func targets(screen: PointerScreen, region: PracticeRegion, count: Int, seed: UInt64) throws -> [PracticeTarget] {
        guard region.isValid(in: screen) else { throw PracticeError.invalidRegion }
        guard (1...200).contains(count) else { throw PracticeError.invalidCount }
        var random = PracticeRandom(seed: seed)
        var sizes = (0..<count).map { targetDiameters[$0 % targetDiameters.count] }
        random.shuffle(&sizes)
        return sizes.enumerated().map { index, diameter in
            let inset = diameter / 2 + 4
            return PracticeTarget(id: index + 1,
                center: PointerPoint(x: region.origin.x + inset + random.unit() * (region.width - inset * 2),
                                     y: region.origin.y + inset + random.unit() * (region.height - inset * 2)), diameter: diameter)
        }
    }
}

private struct PracticeRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for i in stride(from: values.count - 1, through: 1, by: -1) { values.swapAt(i, Int(next() % UInt64(i + 1))) }
    }
}

public struct PracticeClickRecord: Codable, Sendable {
    public let elapsedSeconds: Double
    public let point: PointerPoint
    public let button: PointerButton
    public let clickCount: Int
    public let failure: PracticeClickFailure?
}
public struct PracticeTrialResult: Codable, Sendable {
    public let target: PracticeTarget
    public let outcome: PracticeOutcome
    public let totalSeconds: Double
    public let firstTargetEntrySeconds: Double?
    public let firstFreezeSeconds: Double?
    public let freezeToCompletionSeconds: Double?
    public let explicitFreeze: Bool
    public let targetEntries: Int
    public let freezeCount: Int
    public let movementResumptions: Int
    public let clicks: [PracticeClickRecord]
    public var firstClickHit: Bool? { clicks.first.map { $0.failure == nil } }
    public var missedClicks: Int { clicks.filter { $0.failure != nil }.count }
    public var targetReentries: Int { max(0, targetEntries - 1) }
}
public struct PracticeRange: Codable, Sendable {
    public let count: Int
    public let median: Double?
    public let minimum: Double?
    public let maximum: Double?
    public init(_ values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted(); count = sorted.count
        minimum = sorted.first; maximum = sorted.last
        if sorted.isEmpty { median = nil }
        else { median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2 }
    }
}
public struct PracticeSummary: Codable, Sendable {
    public let attempted: Int
    public let completed: Int
    public let failures: Int
    public let firstClickHits: Int
    public let totalSecondsForCompleted: PracticeRange
    public let firstTargetEntrySeconds: PracticeRange
    public let freezeToCompletionSeconds: PracticeRange
}
public struct PracticeRunResult: Codable, Sendable {
    public let configuration: PracticeConfiguration
    public let targets: [PracticeTarget]
    public let trials: [PracticeTrialResult]
    public let ignoredEvents: Int
    public let effort: Int?
    public let feedback: String
    public func withFeedback(effort: Int?, text: String) -> Self {
        Self(configuration: configuration, targets: targets, trials: trials, ignoredEvents: ignoredEvents,
             effort: effort.flatMap { (0...10).contains($0) ? $0 : nil }, feedback: text)
    }
    public var summary: PracticeSummary {
        let completed = trials.filter { $0.outcome == .hit }
        return PracticeSummary(attempted: trials.count, completed: completed.count,
            failures: trials.count - completed.count, firstClickHits: trials.filter { $0.firstClickHit == true }.count,
            totalSecondsForCompleted: PracticeRange(completed.map(\.totalSeconds)),
            firstTargetEntrySeconds: PracticeRange(trials.compactMap(\.firstTargetEntrySeconds)),
            freezeToCompletionSeconds: PracticeRange(completed.filter(\.explicitFreeze).compactMap(\.freezeToCompletionSeconds)))
    }
}

/// This is the production scorekeeper used by the window and by tests. It never
/// emits input. Every timestamp supplied here is from ONE Mac monotonic clock.
public struct PointerPracticeRun {
    public let configuration: PracticeConfiguration
    public let targets: [PracticeTarget]
    public private(set) var trials: [PracticeTrialResult] = []
    public private(set) var ignoredEvents = 0
    private var trial: Trial?
    private var nextIndex = 0
    private var effort: Int?
    private var feedback = ""
    public var currentTarget: PracticeTarget? { trial?.target }
    public var isComplete: Bool { nextIndex == targets.count && trial == nil }
    public var isActive: Bool { trial != nil }

    public init(configuration: PracticeConfiguration, targets: [PracticeTarget]? = nil) throws {
        guard configuration.region.isValid(in: configuration.screen) else { throw PracticeError.invalidRegion }
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0 else { throw PracticeError.invalidTime }
        self.configuration = configuration
        let generated = try targets ?? PointerPracticeSchedule.targets(screen: configuration.screen, region: configuration.region,
            count: configuration.stage == .warmup ? 4 : 20, seed: configuration.seed)
        guard !generated.isEmpty, generated.count <= 200,
              Set(generated.map(\.id)).count == generated.count,
              generated.allSatisfy({ $0.diameter.isFinite && $0.diameter > 0 && configuration.region.contains($0.center, inset: $0.diameter / 2) })
        else { throw PracticeError.invalidTarget }
        self.targets = generated
    }
    @discardableResult public mutating func beginNext(at time: Double, initialPointer: PointerPoint? = nil) -> Bool {
        guard trial == nil, nextIndex < targets.count, time.isFinite, time >= 0 else { return false }
        var current = Trial(target: targets[nextIndex], start: time, lastTime: time)
        if let initialPointer, current.target.contains(initialPointer) {
            current.firstEntry = time; current.inside = true; current.entries = 1
        }
        trial = current; nextIndex += 1; return true
    }
    public mutating func move(to point: PointerPoint, at time: Double) {
        guard accept(time: time), point.isFinite else { return }
        guard var current = trial else { return }
        if current.frozen { current.movementResumptions += 1; current.frozen = false }
        let inside = current.target.contains(point)
        if inside && !current.inside { current.entries += 1; if current.firstEntry == nil { current.firstEntry = time } }
        current.inside = inside; trial = current
    }
    public mutating func freeze(at time: Double, explicit: Bool = true) {
        guard accept(time: time), var current = trial else { return }
        if !current.frozen { current.freezeCount += 1 }
        if current.firstFreeze == nil { current.firstFreeze = time; current.explicitFreeze = explicit }
        current.frozen = true; trial = current
    }
    /// A second down/up belonging to the same double-click cannot complete the
    /// next target. Runs request a single left click; the real double-click task
    /// is separately verified in Finder.
    public mutating func click(at point: PointerPoint, button: PointerButton, clickCount: Int, time: Double) {
        guard accept(time: time), point.isFinite else { return }
        freeze(at: time, explicit: false)
        guard var current = trial else { return }
        let failure: PracticeClickFailure? = button != .left ? .wrongButton : (clickCount != 1 ? .extraClick : (current.target.contains(point) ? nil : .miss))
        if current.firstEntry == nil && current.target.contains(point) { current.firstEntry = time; current.entries += 1 }
        current.clicks.append(PracticeClickRecord(elapsedSeconds: time - current.start, point: point,
            button: button, clickCount: clickCount, failure: failure)); trial = current
        if failure == nil { finish(.hit, at: time) }
    }
    public mutating func tick(at time: Double) {
        guard let current = trial, time.isFinite, time >= current.lastTime,
              time - current.start >= configuration.timeoutSeconds else { return }
        finish(.timeout, at: time)
    }
    public mutating func finish(_ outcome: PracticeOutcome, at time: Double) {
        guard outcome != .hit || (trial?.clicks.isEmpty == false && trial?.clicks.last?.failure == nil),
              accept(time: time), let current = trial else { return }
        trials.append(PracticeTrialResult(target: current.target, outcome: outcome, totalSeconds: time - current.start,
            firstTargetEntrySeconds: current.firstEntry.map { $0 - current.start },
            firstFreezeSeconds: current.firstFreeze.map { $0 - current.start },
            freezeToCompletionSeconds: current.firstFreeze.map { time - $0 }, explicitFreeze: current.explicitFreeze,
            targetEntries: current.entries, freezeCount: current.freezeCount, movementResumptions: current.movementResumptions, clicks: current.clicks))
        trial = nil
    }
    public mutating func recordFeedback(effort: Int?, text: String) {
        self.effort = effort.flatMap { (0...10).contains($0) ? $0 : nil }; feedback = text
    }
    public var result: PracticeRunResult {
        PracticeRunResult(configuration: configuration, targets: targets, trials: trials, ignoredEvents: ignoredEvents,
                          effort: effort, feedback: feedback)
    }
    private mutating func accept(time: Double) -> Bool {
        guard var current = trial else { ignoredEvents += 1; return false }
        guard time.isFinite, time >= current.lastTime else { ignoredEvents += 1; return false }
        current.lastTime = time; trial = current; return true
    }
    private struct Trial {
        let target: PracticeTarget
        let start: Double
        var lastTime: Double
        var firstEntry: Double?
        var firstFreeze: Double?
        var explicitFreeze = false
        var inside = false
        var frozen = false
        var entries = 0
        var freezeCount = 0
        var movementResumptions = 0
        var clicks: [PracticeClickRecord] = []
    }
}

public enum BlindPracticePosture: String, Codable, Sendable { case original, perturbed }
public enum BlindPracticeFailure: String, Codable, Sendable { case unstable, invalidContext, predictionRejected, skipped, aborted }
public struct BlindPracticeTrialResult: Codable, Sendable {
    public let target: PracticeTarget
    /// Raw model prediction: never screen-clamped before computing the error.
    public let prediction: PointerPoint?
    public let errorPoints: Double?
    public let hit: Bool?
    public let elapsedSeconds: Double
    public let failure: BlindPracticeFailure?
    public let sampleCount: Int
    public let sampleRateHz: Double?
    public let rmsRadians: Double?
    public let maxDeviationRadians: Double?
}
public struct BlindPracticeResult: Codable, Sendable {
    public let screen: PointerScreen
    public let region: PracticeRegion
    public let calibrationID: UUID
    public let posture: BlindPracticePosture
    public let targetDiameter: Double
    public let trainingTargetsNormalized: [PointerPoint]
    public let seed: UInt64
    public let metadata: PracticeMetadata
    public let targets: [PracticeTarget]
    public let trials: [BlindPracticeTrialResult]
    public var errors: PracticeRange { PracticeRange(trials.compactMap(\.errorPoints)) }
    public var hits: Int { trials.filter { $0.hit == true }.count }
}

/// The scorekeeper can only accept ONE prediction per target. The UI reveals it
/// after lockPrediction returns true. It contains no fitting or attitude model.
public struct BlindPointerPractice {
    public let screen: PointerScreen
    public let region: PracticeRegion
    public let calibrationID: UUID
    public let posture: BlindPracticePosture
    public let targetDiameter: Double
    public let trainingTargetsNormalized: [PointerPoint]
    public let seed: UInt64
    public let metadata: PracticeMetadata
    public let targets: [PracticeTarget]
    public private(set) var trials: [BlindPracticeTrialResult] = []
    public private(set) var currentTarget: PracticeTarget?
    private var startedAt: Double = 0
    private var nextIndex = 0
    public var isComplete: Bool { nextIndex == targets.count && currentTarget == nil }
    public init(screen: PointerScreen, region: PracticeRegion, calibrationID: UUID, posture: BlindPracticePosture,
                trainingTargetsNormalized: [PointerPoint], seed: UInt64, targetDiameter: Double = 48, metadata: PracticeMetadata = .init()) throws {
        guard region.isValid(in: screen) else { throw PracticeError.invalidRegion }
        guard targetDiameter.isFinite, targetDiameter > 0, targetDiameter <= min(region.width, region.height) / 5,
              trainingTargetsNormalized.allSatisfy({ $0.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) })
        else { throw PracticeError.invalidTarget }
        self.screen = screen; self.region = region; self.calibrationID = calibrationID; self.posture = posture
        self.targetDiameter = targetDiameter; self.trainingTargetsNormalized = trainingTargetsNormalized
        self.seed = seed; self.metadata = metadata
        let training = trainingTargetsNormalized.map(screen.point(normalized:))
        var positions: [PointerPoint] = []
        for y in [0.09, 0.5, 0.91] { for x in [0.09, 0.5, 0.91] {
            // A deterministic small offset avoids the trained center, without
            // using predictions to pick easier test points.
            let candidates = [(x, y), (x + 0.065, y - 0.065), (x - 0.065, y + 0.065), (x + 0.035, y + 0.07)]
            guard let point = candidates.map({ region.point(x: $0.0, y: $0.1) }).first(where: { p in
                region.contains(p, inset: targetDiameter / 2)
                && training.allSatisfy { $0.distance(to: p) > targetDiameter }
                && positions.allSatisfy { $0.distance(to: p) > targetDiameter }
            }) else { throw PracticeError.noIndependentTargets }
            positions.append(point)
        } }
        var random = PracticeRandom(seed: seed); random.shuffle(&positions)
        targets = positions.enumerated().map { PracticeTarget(id: $0.offset + 1, center: $0.element, diameter: targetDiameter) }
    }
    @discardableResult public mutating func beginNext(at time: Double) -> Bool {
        guard currentTarget == nil, nextIndex < targets.count, time.isFinite, time >= 0 else { return false }
        currentTarget = targets[nextIndex]; nextIndex += 1; startedAt = time; return true
    }
    @discardableResult public mutating func lockPrediction(_ raw: PointerPoint, at time: Double,
        sampleCount: Int, sampleRateHz: Double, rmsRadians: Double, maxDeviationRadians: Double) -> Bool {
        guard let target = currentTarget, raw.isFinite, time.isFinite, time >= startedAt,
              sampleCount > 0, sampleRateHz.isFinite, sampleRateHz > 0,
              rmsRadians.isFinite, rmsRadians >= 0, maxDeviationRadians.isFinite, maxDeviationRadians >= 0 else { return false }
        trials.append(BlindPracticeTrialResult(target: target, prediction: raw, errorPoints: target.center.distance(to: raw),
            hit: target.contains(raw), elapsedSeconds: time - startedAt, failure: nil,
            sampleCount: sampleCount, sampleRateHz: sampleRateHz, rmsRadians: rmsRadians, maxDeviationRadians: maxDeviationRadians))
        currentTarget = nil; return true
    }
    public mutating func fail(_ reason: BlindPracticeFailure, at time: Double) {
        guard let target = currentTarget, time.isFinite, time >= startedAt else { return }
        trials.append(BlindPracticeTrialResult(target: target, prediction: nil, errorPoints: nil, hit: nil,
            elapsedSeconds: time - startedAt, failure: reason, sampleCount: 0, sampleRateHz: nil, rmsRadians: nil, maxDeviationRadians: nil))
        currentTarget = nil
    }
    public var result: BlindPracticeResult {
        BlindPracticeResult(screen: screen, region: region, calibrationID: calibrationID, posture: posture,
            targetDiameter: targetDiameter, trainingTargetsNormalized: trainingTargetsNormalized, seed: seed,
            metadata: metadata, targets: targets, trials: trials)
    }
}

public struct PointerPracticeEvidence: Codable, Sendable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let coordinateUnits: String
    public let regularRuns: [PracticeRunResult]
    public let blindRuns: [BlindPracticeResult]
    public init(regularRuns: [PracticeRunResult], blindRuns: [BlindPracticeResult]) {
        schemaVersion = 1; createdAt = Date(); coordinateUnits = "Quartz global logical points; +x right; +y down; diameters in points"
        self.regularRuns = regularRuns; self.blindRuns = blindRuns
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
