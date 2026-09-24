import Foundation

public enum BLEIDs {
    public static let service = "7C430100-9BD7-4D97-AB7F-41FBBE733001"
    public static let input = "7C430101-9BD7-4D97-AB7F-41FBBE733001"
    public static let status = "7C430102-9BD7-4D97-AB7F-41FBBE733001"
    public static let diagnostics = "7C430103-9BD7-4D97-AB7F-41FBBE733001"
}

public enum MessageKind: UInt8, CaseIterable {
    case hello = 1, ready, scroll, mark, idle, ack, rejected, exportRequest
    case challenge, authenticate, setControl
}

/// A 20-byte action body. Version 2 actions travel inside an authenticated packet.
/// A session is an isolation boundary, NOT authentication.
public struct Frame: Equatable {
    public static let version: UInt8 = 2
    public static let size = 20
    public let kind: MessageKind
    public let session: UInt64
    public let sequence: UInt32
    public let value: Int32
    public let ticket: UInt16

    public init(_ kind: MessageKind, session: UInt64 = 0, sequence: UInt32 = 0,
                value: Int32 = 0, ticket: UInt16 = 0) {
        self.kind = kind; self.session = session; self.sequence = sequence
        self.value = value; self.ticket = ticket
    }

    public var data: Data {
        var bytes: [UInt8] = [Self.version, kind.rawValue]
        appendLE(session, to: &bytes); appendLE(sequence, to: &bytes)
        appendLE(UInt32(bitPattern: value), to: &bytes); appendLE(ticket, to: &bytes)
        return Data(bytes)
    }

    public func acknowledges(_ pending: Frame) -> Bool {
        (kind == .ack || kind == .rejected) && session == pending.session && sequence == pending.sequence
    }

    public init?(data: Data) {
        let b = Array(data)
        guard b.count == Self.size, b[0] == Self.version, let k = MessageKind(rawValue: b[1]) else { return nil }
        kind = k; session = readLE(b, at: 2, count: 8)
        sequence = UInt32(readLE(b, at: 10, count: 4))
        value = Int32(bitPattern: UInt32(readLE(b, at: 14, count: 4)))
        ticket = UInt16(readLE(b, at: 18, count: 2))
    }
}

func appendLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for i in 0..<MemoryLayout<T>.size { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
}

func readLE(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
    (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
}

/// Fixed-point points, preserving sub-point movement rather than truncating every event.
public struct LinearScroll {
    public static let scale = 1024.0
    public static let pointsPerUnit = 180.0
    private var remainder = 0.0
    public init() {}
    public mutating func reset() { remainder = 0 }
    public mutating func convert(delta: Double) -> Int32? {
        guard delta.isFinite, abs(delta) <= 4 else { reset(); return nil }
        let amount = delta * Self.pointsPerUnit * Self.scale + remainder
        let whole = amount.rounded(.towardZero)
        remainder = amount - whole
        return Int32(whole)
    }
    public static func points(_ value: Int32) -> Double { Double(value) / scale }
}
