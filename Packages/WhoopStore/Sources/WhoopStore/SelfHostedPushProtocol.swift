import Foundation

// Self-hosted push, protocol 1.0 (docs/PUSH_PROTOCOL.md): the pure half. Registry, NDJSON encoding,
// cursors, stable batch identities, acknowledgement and capability validation, and the endpoint policy.
// No GRDB, no networking, no UIKit, so all of it is covered by `swift test` without an app.
//
// Mirrors the Android client (`com.noop.push.PushProtocol`) member for member: the same registry
// order, the same canonical JSON (sorted members for whole lines and identities, registry order inside
// a natural-key fingerprint), the same SHA-256-derived version-5-shaped UUIDs. Numbers are rendered by
// each platform's own shortest round-trip formatter, which may differ in spelling (`1e-05` vs
// `1.0E-5`); receivers parse JSON numbers, and batch identity is only ever compared on one device.

/// One exported column value. SQL NULL is `.null`; booleans stay booleans on the wire.
public enum PushValue: Equatable, Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case bool(Bool)
    case null
}

/// One named member of a record's `key` or `data` object, in registry order.
public struct PushMember: Equatable, Sendable {
    public let name: String
    public let value: PushValue
    public init(_ name: String, _ value: PushValue) { self.name = name; self.value = value }
}

/// How a registry column is read from SQLite and written as JSON.
public enum PushColumnKind: Sendable { case int, double, text, bool }

public struct PushColumn: Sendable {
    public let name: String
    public let kind: PushColumnKind
    init(_ name: String, _ kind: PushColumnKind) { self.name = name; self.kind = kind }
}

/// The fixed v1 stream registry. A table that is not listed here is never exported.
public enum PushStream: String, CaseIterable, Sendable {
    case hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample, gravitySample
    case dailyMetric, sleepSession, workout, journal

    public var isAppend: Bool {
        switch self {
        case .dailyMetric, .sleepSession, .workout, .journal: return false
        default: return true
        }
    }

    public var delivery: String { isAppend ? "append" : "replace_window" }

    /// The local table, which in v1 has the same name as the stream.
    public var table: String { rawValue }

    public var keyColumns: [PushColumn] {
        switch self {
        case .hrSample, .battery, .spo2Sample, .skinTempSample, .respSample, .gravitySample:
            return [PushColumn("ts", .int)]
        case .rrInterval: return [PushColumn("ts", .int), PushColumn("rrMs", .int), PushColumn("seq", .int)]
        case .event: return [PushColumn("ts", .int), PushColumn("kind", .text)]
        case .dailyMetric: return [PushColumn("day", .text)]
        case .sleepSession: return [PushColumn("startTs", .int)]
        case .workout: return [PushColumn("startTs", .int), PushColumn("sport", .text)]
        case .journal: return [PushColumn("day", .text), PushColumn("question", .text)]
        }
    }

    public var dataColumns: [PushColumn] {
        switch self {
        case .hrSample: return [PushColumn("bpm", .int)]
        case .rrInterval: return [PushColumn("ord", .int), PushColumn("srcChannel", .int), PushColumn("tsSuspect", .int)]
        case .event: return [PushColumn("payloadJSON", .text)]
        case .battery: return [PushColumn("soc", .double), PushColumn("mv", .int), PushColumn("charging", .bool)]
        case .spo2Sample: return [PushColumn("red", .int), PushColumn("ir", .int)]
        case .skinTempSample: return [PushColumn("raw", .int), PushColumn("aux1Raw", .int), PushColumn("aux2Raw", .int)]
        case .respSample: return [PushColumn("raw", .int)]
        case .gravitySample:
            return [PushColumn("x", .double), PushColumn("y", .double), PushColumn("z", .double),
                    PushColumn("dynAccel", .double)]
        case .dailyMetric:
            return [PushColumn("totalSleepMin", .double), PushColumn("efficiency", .double),
                    PushColumn("deepMin", .double), PushColumn("remMin", .double), PushColumn("lightMin", .double),
                    PushColumn("disturbances", .int), PushColumn("restingHr", .int), PushColumn("avgHrv", .double),
                    PushColumn("recovery", .double), PushColumn("strain", .double), PushColumn("exerciseCount", .int),
                    PushColumn("spo2Pct", .double), PushColumn("skinTempDevC", .double),
                    PushColumn("respRateBpm", .double), PushColumn("steps", .int),
                    PushColumn("activeKcalEst", .double), PushColumn("spo2Red", .int), PushColumn("spo2Ir", .int)]
        case .sleepSession:
            return [PushColumn("endTs", .int), PushColumn("efficiency", .double), PushColumn("restingHr", .int),
                    PushColumn("avgHrv", .double), PushColumn("stagesJSON", .text), PushColumn("userEdited", .bool),
                    PushColumn("startTsAdjusted", .int), PushColumn("motionJSON", .text),
                    PushColumn("sleepStateJSON", .text), PushColumn("stagingSparse", .bool)]
        case .workout:
            return [PushColumn("endTs", .int), PushColumn("source", .text), PushColumn("durationS", .double),
                    PushColumn("energyKcal", .double), PushColumn("avgHr", .int), PushColumn("maxHr", .int),
                    PushColumn("strain", .double), PushColumn("distanceM", .double), PushColumn("zonesJSON", .text),
                    PushColumn("notes", .text), PushColumn("routePolyline", .text), PushColumn("steps", .int)]
        case .journal:
            return [PushColumn("answeredYes", .bool), PushColumn("notes", .text), PushColumn("numericValue", .double)]
        }
    }

    /// The window selector of a replace-window stream: `day` (YYYY-MM-DD) or `startTs` (Unix seconds).
    public var selectorColumn: String? {
        switch self {
        case .dailyMetric, .journal: return "day"
        case .sleepSession, .workout: return "startTs"
        default: return nil
        }
    }
}

/// An append highwater: the SQLite rowid of the last accepted record plus its natural-key fingerprint.
public struct PushCursor: Equatable, Codable, Sendable {
    public let rowId: Int64
    public let keySha256: String
    public init(rowId: Int64, keySha256: String) { self.rowId = rowId; self.keySha256 = keySha256 }
}

/// One local row: its insertion position (append streams), key and data members.
public struct PushRecord: Equatable, Sendable {
    public let rowId: Int64
    public let key: [PushMember]
    public let data: [PushMember]
    public init(rowId: Int64, key: [PushMember], data: [PushMember]) {
        self.rowId = rowId; self.key = key; self.data = data
    }
}

/// The half-open window of one authoritative replacement.
public enum PushWindowBounds: Equatable, Sendable {
    case days(startInclusive: String, endExclusive: String)
    case timestamps(startInclusive: Int64, endExclusive: Int64)
}

/// One ready-to-send request: the exact decoded NDJSON entity plus what its acknowledgement must echo.
public struct PushBatch: Equatable, Sendable {
    public let batchId: String
    public let stream: PushStream
    public let deviceId: String
    public let endCursor: PushCursor?
    public let recordCount: Int
    public let body: Data
}

public struct PushProtocolError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum PushProtocol {
    public static let version = "1.0"
    public static let maxRecords = 5_000
    public static let maxBodyBytes = 4 * 1024 * 1024
    public static let maxResponseBytes = 16 * 1024
    /// Fail-closed memory bound for one mutable-window snapshot (records / encoded record bytes).
    public static let maxSnapshotRecords = 1_000
    public static let maxSnapshotBytes = 2 * 1024 * 1024
    static let uuidPlaceholder = "00000000-0000-0000-0000-000000000000"

    // MARK: - JSON

    indirect enum JSON {
        case value(PushValue)
        case object([(String, JSON)])
        case int(Int)
        case string(String)
    }

    static func render(_ json: JSON, sorted: Bool, into out: inout String) throws {
        switch json {
        case .value(let v): try renderValue(v, into: &out)
        case .int(let i): out += String(i)
        case .string(let s): quote(s, into: &out)
        case .object(let members):
            let ordered = sorted ? members.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) } : members
            out += "{"
            for (i, (name, item)) in ordered.enumerated() {
                if i > 0 { out += "," }
                quote(name, into: &out)
                out += ":"
                try render(item, sorted: sorted, into: &out)
            }
            out += "}"
        }
    }

    static func renderValue(_ v: PushValue, into out: inout String) throws {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .text(let s): quote(s, into: &out)
        case .double(let d):
            guard d.isFinite else { throw PushProtocolError("non-finite number is not valid JSON") }
            out += "\(d)"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    static func canonical(_ json: JSON) throws -> String {
        var out = ""
        try render(json, sorted: true, into: &out)
        return out
    }

    static func object(_ members: [PushMember]) -> JSON {
        .object(members.map { ($0.name, .value($0.value)) })
    }

    static func line(_ json: JSON) throws -> Data {
        Data((try canonical(json) + "\n").utf8)
    }

    static func recordLine(_ record: PushRecord) throws -> Data {
        try line(.object([("data", object(record.data)), ("key", object(record.key)), ("type", .string("record"))]))
    }

    // MARK: - Validation

    static func validate(_ record: PushRecord, for stream: PushStream) throws {
        guard record.key.map(\.name) == stream.keyColumns.map(\.name) else {
            throw PushProtocolError("\(stream.rawValue) key does not match registry")
        }
        guard record.data.map(\.name) == stream.dataColumns.map(\.name) else {
            throw PushProtocolError("\(stream.rawValue) data does not match registry")
        }
    }

    static func validateUUID(_ value: String, _ name: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw PushProtocolError("\(name) must be a lowercase canonical UUID")
        }
    }

    // MARK: - Cursors and identities

    /// SHA-256(stream LF deviceId LF compact natural key in registry order), lowercase hex.
    public static func keyFingerprint(stream: PushStream, deviceId: String, key: [PushMember]) throws -> String {
        guard key.map(\.name) == stream.keyColumns.map(\.name) else {
            throw PushProtocolError("\(stream.rawValue) key does not match registry")
        }
        var compact = ""
        try render(object(key), sorted: false, into: &compact)
        return PushSHA256.hex(Data("\(stream.rawValue)\n\(deviceId)\n\(compact)".utf8))
    }

    static func cursor(for record: PushRecord, stream: PushStream, deviceId: String) throws -> PushCursor {
        PushCursor(rowId: record.rowId, keySha256: try keyFingerprint(stream: stream, deviceId: deviceId, key: record.key))
    }

    static func cursorJSON(_ c: PushCursor?) -> JSON {
        guard let c else { return .value(.null) }
        return .object([("keySha256", .string(c.keySha256)), ("rowId", .value(.int(c.rowId)))])
    }

    /// A version-5-shaped UUID from SHA-256(canonical identity, LF, record lines): the same rows under the
    /// same header always get the same id, so a retry repeats the identical batch.
    static func stableUUID(_ identity: JSON, lines: [Data]) throws -> String {
        var hasher = PushSHA256()
        hasher.update(Data(try canonical(identity).utf8))
        hasher.update(Data([0x0a]))
        for l in lines { hasher.update(l) }
        var b = Array(hasher.finalize().prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    // MARK: - Append batches

    static func appendIdentity(sourceId: String, stream: PushStream, deviceId: String,
                               start: PushCursor?, end: PushCursor, count: Int) -> [(String, JSON)] {
        [("delivery", .string("append")), ("deviceId", .string(deviceId)), ("endCursor", cursorJSON(end)),
         ("protocolVersion", .string(version)), ("recordCount", .int(count)), ("sourceId", .string(sourceId)),
         ("startCursor", cursorJSON(start)), ("stream", .string(stream.rawValue)), ("type", .string("batch"))]
    }

    /// One append batch from `records` (strictly ascending rowids, all after `startCursor`). Takes as many
    /// leading records as fit both bounds; the caller resumes from the returned `endCursor`.
    public static func appendBatch(stream: PushStream, sourceId: String, deviceId: String,
                                   startCursor: PushCursor?, records: [PushRecord]) throws -> PushBatch {
        guard stream.isAppend else { throw PushProtocolError("\(stream.rawValue) is not an append stream") }
        try validateUUID(sourceId, "sourceId")
        guard !records.isEmpty else { throw PushProtocolError("append batch must contain a record") }
        for (a, b) in zip(records, records.dropFirst()) where a.rowId >= b.rowId {
            throw PushProtocolError("append records must be strictly ordered by rowid")
        }
        if let start = startCursor, records[0].rowId <= start.rowId {
            throw PushProtocolError("append records must follow the start cursor")
        }
        var lines: [Data] = []
        var bytes = 0
        var last: PushCursor?
        for record in records.prefix(maxRecords) {
            try validate(record, for: stream)
            let l = try recordLine(record)
            let end = try cursor(for: record, stream: stream, deviceId: deviceId)
            let header = try line(.object(appendIdentity(sourceId: sourceId, stream: stream, deviceId: deviceId,
                                                         start: startCursor, end: end, count: lines.count + 1)
                                          + [("batchId", .string(uuidPlaceholder))]))
            if header.count + bytes + l.count > maxBodyBytes { break }
            lines.append(l)
            bytes += l.count
            last = end
        }
        guard let end = last else { throw PushProtocolError("first append record exceeds the 4 MiB batch limit") }
        let identity = appendIdentity(sourceId: sourceId, stream: stream, deviceId: deviceId,
                                      start: startCursor, end: end, count: lines.count)
        let batchId = try stableUUID(.object(identity), lines: lines)
        var body = try line(.object(identity + [("batchId", .string(batchId))]))
        for l in lines { body.append(l) }
        return PushBatch(batchId: batchId, stream: stream, deviceId: deviceId, endCursor: end,
                         recordCount: lines.count, body: body)
    }

    // MARK: - Replace-window batches

    static func boundsJSON(_ stream: PushStream, _ w: PushWindowBounds) -> [(String, JSON)] {
        switch w {
        case let .days(s, e):
            return [("endExclusive", .string(e)), ("selector", .string(stream.selectorColumn ?? "day")),
                    ("startInclusive", .string(s))]
        case let .timestamps(s, e):
            return [("endExclusive", .value(.int(e))), ("selector", .string(stream.selectorColumn ?? "startTs")),
                    ("startInclusive", .value(.int(s)))]
        }
    }

    static func mutableIdentity(sourceId: String, stream: PushStream, deviceId: String, window: PushWindowBounds,
                                replacementId: String, part: Int, parts: Int, count: Int) -> [(String, JSON)] {
        [("delivery", .string("replace_window")), ("deviceId", .string(deviceId)), ("endCursor", .value(.null)),
         ("protocolVersion", .string(version)), ("recordCount", .int(count)), ("sourceId", .string(sourceId)),
         ("startCursor", .value(.null)), ("stream", .string(stream.rawValue)), ("type", .string("batch")),
         ("window", .object(boundsJSON(stream, window) + [("part", .int(part)), ("parts", .int(parts)),
                                                         ("replacementId", .string(replacementId))]))]
    }

    /// Every bounded part of one authoritative replacement of `window`. `records` must be the complete
    /// local snapshot of that window; an empty snapshot yields one zero-record part (a deletion).
    public static func replaceWindowBatches(stream: PushStream, sourceId: String, deviceId: String,
                                            window: PushWindowBounds, records: [PushRecord]) throws -> [PushBatch] {
        guard !stream.isAppend else { throw PushProtocolError("\(stream.rawValue) is not a replace-window stream") }
        try validateUUID(sourceId, "sourceId")
        var seen = Set<String>()
        var lines: [Data] = []
        for r in sortedByKey(records) {
            try validate(r, for: stream)
            var k = ""
            try render(object(r.key), sorted: false, into: &k)
            guard seen.insert(k).inserted else { throw PushProtocolError("replace_window contains a duplicate key") }
            lines.append(try recordLine(r))
        }
        let replacementIdentity: JSON = .object([
            ("deviceId", .string(deviceId)), ("delivery", .string("replace_window")),
            ("protocolVersion", .string(version)), ("sourceId", .string(sourceId)),
            ("stream", .string(stream.rawValue)), ("window", .object(boundsJSON(stream, window)))])
        let replacementId = try stableUUID(replacementIdentity, lines: lines)

        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        for l in lines {
            let header = try line(.object(mutableIdentity(sourceId: sourceId, stream: stream, deviceId: deviceId,
                                                          window: window, replacementId: replacementId,
                                                          part: Int(Int32.max), parts: Int(Int32.max),
                                                          count: current.count + 1)
                                          + [("batchId", .string(uuidPlaceholder))]))
            if current.count + 1 > maxRecords || header.count + currentBytes + l.count > maxBodyBytes {
                guard !current.isEmpty else {
                    throw PushProtocolError("replace_window record exceeds the 4 MiB batch limit")
                }
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(l)
            currentBytes += l.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        return try chunks.enumerated().map { index, partLines in
            let identity = mutableIdentity(sourceId: sourceId, stream: stream, deviceId: deviceId, window: window,
                                           replacementId: replacementId, part: index + 1, parts: chunks.count,
                                           count: partLines.count)
            let batchId = try stableUUID(.object(identity), lines: partLines)
            var body = try line(.object(identity + [("batchId", .string(batchId))]))
            for l in partLines { body.append(l) }
            return PushBatch(batchId: batchId, stream: stream, deviceId: deviceId, endCursor: nil,
                             recordCount: partLines.count, body: body)
        }
    }

    /// Natural-key order: integers numerically, text by unsigned UTF-8 bytes (SQLite BINARY).
    static func sortedByKey(_ records: [PushRecord]) -> [PushRecord] {
        records.sorted { a, b in
            for (x, y) in zip(a.key, b.key) {
                switch (x.value, y.value) {
                case let (.int(p), .int(q)) where p != q: return p < q
                case let (.text(p), .text(q)) where p != q: return p.utf8.lexicographicallyPrecedes(q.utf8)
                default: continue
                }
            }
            return false
        }
    }

    /// Local, never-transmitted content hash of one day's snapshot: lets an unchanged day skip its upload.
    public static func snapshotHash(stream: PushStream, records: [PushRecord]) throws -> String {
        var hasher = PushSHA256()
        hasher.update(Data("noop-push-day-hash\n\(version)\n\(stream.rawValue)\n".utf8))
        let lines = try records.map { r -> Data in try validate(r, for: stream); return try recordLine(r) }
        for l in lines.sorted(by: { $0.lexicographicallyPrecedes($1) }) { hasher.update(l) }
        return PushSHA256.hex(of: hasher.finalize())
    }

    // MARK: - Responses

    /// A validated capability document: the negotiated version, the receiver's continuity id and the
    /// intersection of its stream list with the compiled v1 registry.
    public struct Capabilities: Equatable, Sendable {
        public let protocolVersion: String
        public let receiverStateId: String
        public let streams: [PushStream]
    }

    public static func parseCapabilities(_ data: Data) throws -> Capabilities {
        guard data.count <= maxResponseBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushProtocolError("invalid capabilities")
        }
        guard obj["type"] as? String == "capabilities" else { throw PushProtocolError("invalid capabilities type") }
        guard obj["protocolVersion"] as? String == version else { throw PushProtocolError("unsupported version") }
        guard let state = obj["receiverStateId"] as? String,
              let uuid = UUID(uuidString: state), uuid.uuidString.lowercased() == state.lowercased() else {
            throw PushProtocolError("invalid receiverStateId")
        }
        guard let names = obj["streams"] as? [String], Set(names).count == names.count else {
            throw PushProtocolError("invalid stream list")
        }
        var streams: [PushStream] = []
        for n in names {
            guard let s = PushStream(rawValue: n) else { throw PushProtocolError("unknown stream \(n)") }
            streams.append(s)
        }
        return Capabilities(protocolVersion: version, receiverStateId: state.lowercased(),
                            streams: PushStream.allCases.filter(streams.contains))
    }

    /// True only when a 2xx body is exactly the acknowledgement of `batch` (no partial success).
    public static func acknowledgementMatches(_ data: Data, batch: PushBatch) -> Bool {
        guard data.count <= maxResponseBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard obj["protocolVersion"] as? String == version,
              obj["batchId"] as? String == batch.batchId,
              obj["stream"] as? String == batch.stream.rawValue,
              obj["deviceId"] as? String == batch.deviceId,
              obj["status"] as? String == "accepted",
              let accepted = obj["acceptedRows"] as? NSNumber, accepted.intValue == batch.recordCount,
              obj.keys.contains("endCursor") else { return false }
        switch (obj["endCursor"], batch.endCursor) {
        case (is NSNull, nil): return true
        case let (raw as [String: Any], expected?):
            return (raw["rowId"] as? NSNumber)?.int64Value == expected.rowId
                && raw["keySha256"] as? String == expected.keySha256
        default: return false
        }
    }

    /// The receiver's machine-readable error code, if the body carries a valid one. Nothing else from an
    /// error body is ever kept.
    public static func errorCode(_ data: Data) -> String? {
        guard data.count <= maxResponseBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String, (1...64).contains(code.count),
              let first = code.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
              code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return nil }
        return code
    }
}

// MARK: - Endpoint policy

public enum PushEndpointPolicy {
    public enum Rejection: Error, Equatable { case invalidURL, unsupportedScheme, cleartextHostname, cleartextPublicAddress }

    /// HTTPS anywhere; plain HTTP only to a numeric loopback, RFC 1918, link-local, IPv6 ULA or Tailscale
    /// (100.64.0.0/10) address. Returns the normalized URL (lowercased scheme and host, no fragment).
    public static func validate(_ raw: String) -> Result<URL, Rejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty, comps.user == nil, comps.password == nil else {
            return .failure(.invalidURL)
        }
        comps.scheme = scheme
        comps.host = host.lowercased()
        comps.fragment = nil
        guard let url = comps.url else { return .failure(.invalidURL) }
        switch scheme {
        case "https": return .success(url)
        case "http":
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            if let v4 = ipv4(bare) {
                return isPrivateV4(v4) ? .success(url) : .failure(.cleartextPublicAddress)
            }
            if bare.contains(":") {
                return isPrivateV6(bare) ? .success(url) : .failure(.cleartextPublicAddress)
            }
            return .failure(.cleartextHostname)
        default: return .failure(.unsupportedScheme)
        }
    }

    static func ipv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    static func isPrivateV4(_ a: [UInt8]) -> Bool {
        a[0] == 127 || a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168)
            || (a[0] == 169 && a[1] == 254) || (a[0] == 100 && (64...127).contains(a[1]))
    }

    static func isPrivateV6(_ s: String) -> Bool {
        if s == "::1" { return true }
        guard let first = s.split(separator: ":").first, let head = UInt16(first, radix: 16) else { return false }
        return (head & 0xfe00) == 0xfc00 || (head & 0xffc0) == 0xfe80
    }
}

// MARK: - SHA-256 (portable; CryptoKit is not available to the Linux package build)

public struct PushSHA256 {
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    public init() {}

    public mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(buffer[offset..<offset + 64])
            offset += 64
        }
        buffer.removeFirst(offset)
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var offset = 0
        while offset < tail.count {
            compress(tail[offset..<offset + 64])
            offset += 64
        }
        buffer = []
        return h.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) } }
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for i in 0..<16 {
            w[i] = UInt32(block[base + i * 4]) << 24 | UInt32(block[base + i * 4 + 1]) << 16
                | UInt32(block[base + i * 4 + 2]) << 8 | UInt32(block[base + i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ PushSHA256.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    public static func hex(of digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(_ data: Data) -> String {
        var s = PushSHA256()
        s.update(data)
        return hex(of: s.finalize())
    }
}
