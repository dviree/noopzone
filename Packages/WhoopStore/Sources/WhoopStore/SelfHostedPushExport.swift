import Foundation
import GRDB

// Self-hosted push, protocol 1.0: the read-only database projection (docs/PUSH_PROTOCOL.md).
//
// Every read is an explicit registry projection, never `SELECT *`: the columns come from
// `PushStream.keyColumns` / `dataColumns`, so a table gaining a column cannot leak into the wire format.
// A registry column this database does not have (iOS has no `workout.routePolyline`) is read as NULL,
// which the protocol's Apple-compatibility section asks for. `deviceId` scopes the query and `synced`
// is never read. Nothing here writes.

extension WhoopStore {

    /// Device ids that have rows in `stream`, in byte order.
    public func pushDeviceIds(_ stream: PushStream) throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM \(stream.table) ORDER BY deviceId")
        }
    }

    /// Up to `limit` append rows after `afterRowId` (nil = from the start), ascending by insertion rowid.
    public func pushAppendPage(_ stream: PushStream, deviceId: String, afterRowId: Int64?,
                               limit: Int = PushProtocol.maxRecords) throws -> [PushRecord] {
        precondition(stream.isAppend)
        return try syncRead { db in
            let select = try Self.pushSelectList(db, stream)
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS __rowid, \(select) FROM \(stream.table)
                WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?
                """, arguments: [deviceId, afterRowId ?? -1, limit])
            return rows.map { Self.pushRecord($0, stream) }
        }
    }

    /// The row at `rowId`, for checking a saved cursor still points at the same natural key.
    public func pushRecord(_ stream: PushStream, deviceId: String, rowId: Int64) throws -> PushRecord? {
        try syncRead { db in
            let select = try Self.pushSelectList(db, stream)
            return try Row.fetchOne(db, sql: """
                SELECT rowid AS __rowid, \(select) FROM \(stream.table) WHERE deviceId = ? AND rowid = ?
                """, arguments: [deviceId, rowId]).map { Self.pushRecord($0, stream) }
        }
    }

    /// The complete local snapshot of a replace-window stream inside `window`, in natural-key order.
    /// Fails rather than truncating when the window holds more than `PushProtocol.maxSnapshotRecords`.
    public func pushWindowRecords(_ stream: PushStream, deviceId: String,
                                  window: PushWindowBounds) throws -> [PushRecord] {
        guard let selector = stream.selectorColumn else { throw PushProtocolError("not a replace-window stream") }
        return try syncRead { db in
            let select = try Self.pushSelectList(db, stream)
            let order = stream.keyColumns.map(\.name).joined(separator: ", ")
            let start: DatabaseValueConvertible
            let end: DatabaseValueConvertible
            switch window {
            case let .days(s, e): start = s; end = e
            case let .timestamps(s, e): start = s; end = e
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT 0 AS __rowid, \(select) FROM \(stream.table)
                WHERE deviceId = ? AND \(selector) >= ? AND \(selector) < ?
                ORDER BY \(order) LIMIT ?
                """, arguments: [deviceId, start, end, PushProtocol.maxSnapshotRecords + 1])
            guard rows.count <= PushProtocol.maxSnapshotRecords else {
                throw PushProtocolError("\(stream.rawValue) window exceeds \(PushProtocol.maxSnapshotRecords) records")
            }
            return rows.map { Self.pushRecord($0, stream) }
        }
    }

    // MARK: - Projection

    static func pushSelectList(_ db: Database, _ stream: PushStream) throws -> String {
        let existing = Set(try db.columns(in: stream.table).map(\.name))
        return (stream.keyColumns + stream.dataColumns).map { col in
            existing.contains(col.name) ? col.name : "NULL AS \(col.name)"
        }.joined(separator: ", ")
    }

    static func pushRecord(_ row: Row, _ stream: PushStream) -> PushRecord {
        func member(_ col: PushColumn) -> PushMember {
            PushMember(col.name, pushValue(row[col.name] as DatabaseValue, kind: col.kind))
        }
        return PushRecord(rowId: row["__rowid"] ?? 0,
                          key: stream.keyColumns.map(member),
                          data: stream.dataColumns.map(member))
    }

    static func pushValue(_ v: DatabaseValue, kind: PushColumnKind) -> PushValue {
        switch (v.storage, kind) {
        case (.null, _): return .null
        case let (.int64(i), .int): return .int(i)
        case let (.double(d), .int): return d.rounded() == d && abs(d) < 9e18 ? .int(Int64(d)) : .double(d)
        case let (.int64(i), .double): return .double(Double(i))
        case let (.double(d), .double): return d.isFinite ? .double(d) : .null
        case let (.int64(i), .bool): return .bool(i != 0)
        case let (.double(d), .bool): return .bool(d != 0)
        case let (.string(s), .text): return .text(s)
        case let (.string(s), .int): return Int64(s).map(PushValue.int) ?? .text(s)
        case let (.string(s), .double): return Double(s).map(PushValue.double) ?? .text(s)
        case let (.string(s), .bool): return .bool(s == "1" || s.lowercased() == "true")
        case let (.int64(i), .text): return .text(String(i))
        case let (.double(d), .text): return .text(String(d))
        case (.blob, _): return .null
        }
    }
}
