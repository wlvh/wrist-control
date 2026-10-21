import Foundation

/// An inert diagnostic record, deliberately Encodable only. Loading a file must
/// never activate a calibration in a new sensor reference or Mac process.
public struct CalibrationEvidence: Encodable {
    public struct Observation: Encodable {
        public let target: PointerPoint
        public let samples: [AttitudeSample]
        public let meanSample: AttitudeSample
        public let rmsRadians: Double
        public let maximumDeviationRadians: Double
    }
    public let modelVersion = PointingCalibration.modelVersion
    public let calibrationID: UUID
    public let binding: CalibrationBinding
    public let observations: [Observation]
    public let coefficients: [String: [Double]]
    public let trainingQuality: [String: Double]
    public let macBuild: String
    public let watchBuild: String
    public let sourceRevision: String
    public let independentAccuracy = "Not established by these training observations; see separate blind/visible/practice results."
    public init(model: PointingCalibration, macBuild: String, watchBuild: String, sourceRevision: String) {
        calibrationID = model.calibrationID; binding = model.binding
        observations = model.observations.map {
            Observation(target: $0.target, samples: $0.window.samples, meanSample: $0.window.meanSample,
                rmsRadians: $0.window.rmsRadians, maximumDeviationRadians: $0.window.maxDeviationRadians)
        }
        coefficients = ["horizontal": [model.horizontal.intercept, model.horizontal.heading, model.horizontal.elevation],
                        "vertical": [model.vertical.intercept, model.vertical.heading, model.vertical.elevation],
                        "fixedAnchor": [model.anchorHeading, model.anchorElevation]]
        trainingQuality = ["rmsPoints": model.quality.trainingRMSPoints,
                           "maximumPoints": model.quality.trainingMaximumPoints,
                           "conditionNumber": model.quality.conditionNumber,
                           "headingSpan": model.quality.headingSpan, "elevationSpan": model.quality.elevationSpan,
                           "minorSpreadRadians": model.quality.minorSpreadRadians]
        self.macBuild = macBuild; self.watchBuild = watchBuild; self.sourceRevision = sourceRevision
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
