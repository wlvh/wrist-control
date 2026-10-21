import Foundation

public struct PointerSettings: Codable, Equatable {
    public var aGain: Double = 1600
    public var bGain: Double = 1600
    public var joystick = JoystickParameters()
    public init() {}
    public var isValid: Bool {
        aGain.isFinite && bGain.isFinite && (100...8000).contains(aGain) && (100...8000).contains(bGain) && joystick.isValid
    }
    public var description: String {
        "A=\(aGain)pt/rad;B=\(bGain)pt/rad;C=dead:\(joystick.deadZoneRadians),full:\(joystick.fullSpeedRadians),exponent:\(joystick.exponent),widths/s:\(joystick.maxScreenWidthsPerSecond)"
    }
}
