import Foundation

/// Extends the authenticated 20-byte action body without changing the pair key
/// store. All traffic still uses one serialized input characteristic/counter.
public struct PointerWire {
    public static let posePayloadSize = 20 + 8 + 4 + 8 + 2 + 16 + 3
    public static let maximumInputSize = posePayloadSize + AuthenticatedLink.overhead
    public let frame: Frame
    public let cycle: UInt32
    public let sample: AttitudeSample?
    public let click: ClickRequest?
    public let sourceAge: Double
    public let revision: String?
    public init(frame: Frame, cycle: UInt32 = 0, sample: AttitudeSample? = nil, click: ClickRequest? = nil, sourceAge: Double = 0, revision: String? = nil) {
        self.frame = [.pose, .leftClick, .rightClick, .startMovement, .stopMovement].contains(frame.kind)
            ? Frame(frame.kind, session: frame.session, sequence: frame.sequence, value: Int32(bitPattern: cycle), ticket: frame.ticket) : frame
        self.cycle = cycle; self.sample = sample; self.click = click; self.sourceAge = sourceAge; self.revision = revision
    }
    public var data: Data {
        guard sourceAge.isFinite, sourceAge >= 0 else { return Data() }
        var b = Array(frame.data)
        switch frame.kind {
        case .clientInfo:
            guard let revision, revision.utf8.count == 40,
                  revision.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  frame.value > 0 else { return Data() }
            let chars = Array(revision)
            for index in stride(from: 0, to: 40, by: 2) {
                guard let byte = UInt8(String(chars[index...index+1]), radix: 16) else { return Data() }
                b.append(byte)
            }
        case .pose:
            guard let sample, sample.isValid, cycle != 0 else { return Data() }
            appendLE(sample.referenceID, to: &b); appendLE(sample.sequence, to: &b)
            appendLE(sample.watchTime.bitPattern, to: &b)
            appendLE(UInt16(max(0, min(65535, sourceAge * 1000))), to: &b)
            for v in [sample.attitude.w, sample.attitude.x, sample.attitude.y, sample.attitude.z] { appendLE(Float(v).bitPattern, to: &b) }
            b += [sample.reference.rawValue, sample.wear.wrist.rawValue, sample.wear.crown.rawValue]
        case .leftClick, .rightClick:
            guard let click, click.id != 0, click.watchTime.isFinite, click.watchTime >= 0,
                  click.cycle == cycle, cycle != 0,
                  (frame.kind == .leftClick) == (click.button == .left) else { return Data() }
            appendLE(click.id, to: &b); appendLE(click.watchTime.bitPattern, to: &b)
            appendLE(UInt16(max(0, min(65535, sourceAge * 1000))), to: &b)
        case .scroll, .setMode, .setSensitivity, .mainPage:
            appendLE(cycle, to: &b)
        default: break
        }
        return Data(b)
    }
    public init?(data: Data) {
        guard data.count >= Frame.size, let f = Frame(data: data.prefix(Frame.size)) else { return nil }
        let b = Array(data); frame = f
        if f.kind == .clientInfo {
            guard b.count == 40, f.value > 0 else { return nil }
            revision = b[20..<40].map { String(format: "%02x", $0) }.joined()
        } else { revision = nil }
        switch f.kind {
        case .clientInfo:
            cycle = 0; sourceAge = 0; sample = nil; click = nil
        case .pose:
            guard b.count == Self.posePayloadSize,
                  let reference = AttitudeReference(rawValue: b[58]),
                  let wrist = WristSide(rawValue: b[59]), let crown = CrownSide(rawValue: b[60]) else { return nil }
            let q = (0..<4).map { Double(Float(bitPattern: UInt32(readLE(b, at: 42+$0*4, count: 4)))) }
            let s = AttitudeSample(reference: reference, referenceID: readLE(b, at: 20, count: 8),
                sequence: UInt32(readLE(b, at: 28, count: 4)), watchTime: Double(bitPattern: readLE(b, at: 32, count: 8)),
                attitude: AttitudeQuaternion(w: q[0], x: q[1], y: q[2], z: q[3]), wear: WearConfiguration(wrist: wrist, crown: crown))
            guard s.isValid, f.value != 0 else { return nil }
            sample = s; click = nil; cycle = UInt32(bitPattern: f.value)
            sourceAge = Double(readLE(b, at: 40, count: 2)) / 1000
        case .leftClick, .rightClick:
            guard b.count == 38 else { return nil }
            cycle = UInt32(bitPattern: f.value); sample = nil
            let id = readLE(b, at: 20, count: 8), time = Double(bitPattern: readLE(b, at: 28, count: 8))
            guard id != 0, time.isFinite, time >= 0, cycle != 0 else { return nil }
            click = ClickRequest(id: id, button: f.kind == .leftClick ? .left : .right, watchTime: time, cycle: cycle)
            sourceAge = Double(readLE(b, at: 36, count: 2)) / 1000
        case .scroll, .setMode, .setSensitivity, .mainPage:
            guard b.count == 24 else { return nil }
            cycle = UInt32(readLE(b, at: 20, count: 4)); sourceAge = 0; sample = nil; click = nil
        default:
            guard b.count == Frame.size else { return nil }
            cycle = UInt32(bitPattern: f.value); sourceAge = 0; sample = nil; click = nil
        }
    }
}

public struct PointerStatus {
    public static let size = 20 + 4 + 3 + 4
    public let frame: Frame
    public let cycle: UInt32
    public let phase: PointerPhase
    public let mode: PointerMode
    public let scope: OutputScope
    public let doubleClickInterval: Double
    public init(frame: Frame, cycle: UInt32, phase: PointerPhase, mode: PointerMode, scope: OutputScope, doubleClickInterval: Double) {
        self.frame = frame; self.cycle = cycle; self.phase = phase; self.mode = mode; self.scope = scope; self.doubleClickInterval = doubleClickInterval
    }
    public var data: Data {
        var b = Array(frame.data); appendLE(cycle, to: &b); b += [phase.rawValue, mode.rawValue, scope.rawValue]
        appendLE(Float(doubleClickInterval).bitPattern, to: &b); return Data(b)
    }
    public init?(data: Data) {
        let b = Array(data)
        guard b.count == Self.size, let frame = Frame(data: data.prefix(20)),
              let phase = PointerPhase(rawValue: b[24]), let mode = PointerMode(rawValue: b[25]),
              let scope = OutputScope(rawValue: b[26]) else { return nil }
        let interval = Double(Float(bitPattern: UInt32(readLE(b, at: 27, count: 4))))
        guard interval.isFinite, interval > 0, interval <= 3 else { return nil }
        self.frame = frame; cycle = UInt32(readLE(b, at: 20, count: 4)); self.phase = phase; self.mode = mode
        self.scope = scope; doubleClickInterval = interval
    }
}
