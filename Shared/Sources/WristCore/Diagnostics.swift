import Foundation

public struct DiagnosticEvent: Codable {
    public let uptime: Double
    public let event: String
    public let session: String?
    public let sequence: UInt32?
    public let detail: String
}

/// Main-thread confined by both apps. Bounded memory; no page contents/device IDs.
public final class Journal {
    public let source: String
    public let started = ISO8601DateFormatter().string(from: Date())
    public private(set) var events: [DiagnosticEvent] = []
    public private(set) var discarded = 0
    public static let capacity = 4000
    public init(source: String) { self.source = source }
    public func record(_ event: String, frame: Frame? = nil, detail: String = "") {
        if events.count == Self.capacity { events.removeFirst(500); discarded += 500 }
        events.append(DiagnosticEvent(uptime: ProcessInfo.processInfo.systemUptime, event: event,
                                      session: frame.map { String($0.session, radix: 16) },
                                      sequence: frame?.sequence, detail: String(detail.prefix(300))))
    }
    public func snapshot() -> Data {
        struct Snapshot: Encodable {
            let schema = 1
            let source: String
            let started: String
            let os: String
            let clock = "uptime_seconds_local_to_this_device; never subtract across devices"
            let discarded: Int
            let events: [DiagnosticEvent]
        }
        return (try? JSONEncoder().encode(Snapshot(source: source, started: started,
             os: ProcessInfo.processInfo.operatingSystemVersionString, discarded: discarded, events: events))) ?? Data()
    }
    public func persist() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = dir.appendingPathComponent("WristControl", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try snapshot().write(to: folder.appendingPathComponent("\(source)-latest.json"), options: .atomic)
        } catch { /* Export remains available from the in-memory snapshot. */ }
    }
}

/// Separate GATT characteristic, used only while the user requests diagnostic export.
public struct DiagnosticChunk {
    public static let headerSize = 11
    public let session: UInt64
    public let index: UInt16
    public let final: Bool
    public let payload: Data
    public init(session: UInt64, index: UInt16, final: Bool, payload: Data) {
        self.session = session; self.index = index; self.final = final; self.payload = payload
    }
    public var data: Data {
        var bytes: [UInt8] = []
        appendLE(session, to: &bytes); appendLE(index, to: &bytes); bytes.append(final ? 1 : 0)
        return Data(bytes) + payload
    }
    public init?(data: Data) {
        let b = Array(data)
        guard b.count >= Self.headerSize, b[10] <= 1 else { return nil }
        session = readLE(b, at: 0, count: 8); index = UInt16(readLE(b, at: 8, count: 2))
        final = b[10] == 1; payload = data.dropFirst(Self.headerSize)
    }
}

public struct DiagnosticAssembler {
    public private(set) var bytes = Data()
    private var nextIndex: UInt32 = 0
    public let session: UInt64
    public private(set) var complete = false
    public init(session: UInt64) { self.session = session }
    public mutating func append(_ chunk: DiagnosticChunk) -> Bool {
        guard !complete, chunk.session == session, UInt32(chunk.index) == nextIndex,
              bytes.count + chunk.payload.count <= 1_000_000 else { return false }
        bytes.append(chunk.payload); nextIndex += 1; complete = chunk.final
        return true
    }
}
