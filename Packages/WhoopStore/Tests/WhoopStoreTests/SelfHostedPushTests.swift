import XCTest
import GRDB
@testable import WhoopStore

/// Self-hosted push, protocol 1.0 (docs/PUSH_PROTOCOL.md): encoding, identities, cursors, response
/// validation, the endpoint policy and the read-only database projection.
final class SelfHostedPushTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"

    private func hr(_ rowId: Int64, _ ts: Int64, _ bpm: Int64) -> PushRecord {
        PushRecord(rowId: rowId, key: [PushMember("ts", .int(ts))], data: [PushMember("bpm", .int(bpm))])
    }

    private func lines(_ body: Data) -> [[String: Any]] {
        String(decoding: body, as: UTF8.self).split(separator: "\n").map {
            try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    // MARK: - SHA-256

    func testSHA256KnownVectors() {
        XCTAssertEqual(PushSHA256.hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(PushSHA256.hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PushSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        var split = PushSHA256()
        split.update(Data("ab".utf8))
        split.update(Data("c".utf8))
        XCTAssertEqual(PushSHA256.hex(of: split.finalize()), PushSHA256.hex(Data("abc".utf8)))
    }

    // MARK: - Append

    func testAppendBatchIsTheDocumentedNDJSON() throws {
        let batch = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "strap",
                                                 startCursor: nil, records: [hr(5, 1723939201, 61), hr(9, 1723939202, 62)])
        let text = String(decoding: batch.body, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        let docs = lines(batch.body)
        XCTAssertEqual(docs.count, 3)
        let header = docs[0]
        XCTAssertEqual(header["type"] as? String, "batch")
        XCTAssertEqual(header["protocolVersion"] as? String, "1.0")
        XCTAssertEqual(header["delivery"] as? String, "append")
        XCTAssertEqual(header["stream"] as? String, "hrSample")
        XCTAssertEqual(header["recordCount"] as? Int, 2)
        XCTAssertEqual(header["batchId"] as? String, batch.batchId)
        XCTAssertTrue(header["startCursor"] is NSNull)
        let end = header["endCursor"] as? [String: Any]
        XCTAssertEqual(end?["rowId"] as? Int, 9)
        XCTAssertEqual(batch.endCursor?.rowId, 9)
        XCTAssertEqual(docs[1]["type"] as? String, "record")
        XCTAssertEqual((docs[1]["key"] as? [String: Any])?["ts"] as? Int, 1723939201)
        XCTAssertEqual((docs[2]["data"] as? [String: Any])?["bpm"] as? Int, 62)
        // Canonical: members sorted, compact.
        XCTAssertTrue(text.contains(#"{"data":{"bpm":61},"key":{"ts":1723939201},"type":"record"}"#), text)
    }

    func testBatchIdIsStableAndContentAddressed() throws {
        let a = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "strap",
                                             startCursor: nil, records: [hr(1, 10, 60)])
        let b = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "strap",
                                             startCursor: nil, records: [hr(1, 10, 60)])
        let c = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "strap",
                                             startCursor: nil, records: [hr(1, 10, 61)])
        XCTAssertEqual(a.batchId, b.batchId)
        XCTAssertEqual(a.body, b.body)
        XCTAssertNotEqual(a.batchId, c.batchId)
        XCTAssertNotNil(UUID(uuidString: a.batchId))
        XCTAssertEqual(a.batchId, a.batchId.lowercased())
    }

    func testCursorFingerprintIsStreamDeviceAndCompactKey() throws {
        let fp = try PushProtocol.keyFingerprint(stream: .rrInterval, deviceId: "d",
                                                 key: [PushMember("ts", .int(1)), PushMember("rrMs", .int(800)),
                                                       PushMember("seq", .int(0))])
        XCTAssertEqual(fp, PushSHA256.hex(Data("rrInterval\nd\n{\"ts\":1,\"rrMs\":800,\"seq\":0}".utf8)))
    }

    func testAppendRejectsOutOfOrderAndRegistryMismatch() {
        XCTAssertThrowsError(try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "d",
                                                          startCursor: nil, records: [hr(2, 1, 60), hr(1, 2, 60)]))
        let wrong = PushRecord(rowId: 1, key: [PushMember("ts", .int(1))], data: [PushMember("bpmX", .int(1))])
        XCTAssertThrowsError(try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "d",
                                                          startCursor: nil, records: [wrong]))
        XCTAssertThrowsError(try PushProtocol.appendBatch(stream: .hrSample, sourceId: "NOT-A-UUID", deviceId: "d",
                                                          startCursor: nil, records: [hr(1, 1, 60)]))
    }

    func testAppendBatchStopsAtTheRecordBound() throws {
        let records = (1...5_100).map { hr(Int64($0), Int64($0), 60) }
        let batch = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "d",
                                                 startCursor: nil, records: records)
        XCTAssertEqual(batch.recordCount, 5_000)
        XCTAssertEqual(batch.endCursor?.rowId, 5_000)
    }

    // MARK: - Replace window

    private func day(_ d: String, recovery: Double?) -> PushRecord {
        PushRecord(rowId: 0, key: [PushMember("day", .text(d))],
                   data: PushStream.dailyMetric.dataColumns.map {
                       PushMember($0.name, $0.name == "recovery" ? (recovery.map(PushValue.double) ?? .null) : .null)
                   })
    }

    func testReplaceWindowHeaderAndSorting() throws {
        let parts = try PushProtocol.replaceWindowBatches(
            stream: .dailyMetric, sourceId: source, deviceId: "d",
            window: .days(startInclusive: "2026-08-05", endExclusive: "2026-08-19"),
            records: [day("2026-08-07", recovery: 70), day("2026-08-06", recovery: 55.5)])
        XCTAssertEqual(parts.count, 1)
        let docs = lines(parts[0].body)
        let window = docs[0]["window"] as? [String: Any]
        XCTAssertEqual(docs[0]["delivery"] as? String, "replace_window")
        XCTAssertEqual(window?["selector"] as? String, "day")
        XCTAssertEqual(window?["startInclusive"] as? String, "2026-08-05")
        XCTAssertEqual(window?["endExclusive"] as? String, "2026-08-19")
        XCTAssertEqual(window?["part"] as? Int, 1)
        XCTAssertEqual(window?["parts"] as? Int, 1)
        XCTAssertTrue(docs[0]["endCursor"] is NSNull)
        XCTAssertEqual((docs[1]["key"] as? [String: Any])?["day"] as? String, "2026-08-06")
        XCTAssertEqual((docs[1]["data"] as? [String: Any])?["recovery"] as? Double, 55.5)
        XCTAssertTrue((docs[2]["data"] as? [String: Any])?["strain"] is NSNull)
    }

    func testEmptyWindowIsOneZeroRecordPart() throws {
        let parts = try PushProtocol.replaceWindowBatches(stream: .sleepSession, sourceId: source, deviceId: "d",
                                                          window: .timestamps(startInclusive: 100, endExclusive: 200),
                                                          records: [])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].recordCount, 0)
        let window = lines(parts[0].body)[0]["window"] as? [String: Any]
        XCTAssertEqual(window?["selector"] as? String, "startTs")
        XCTAssertEqual(window?["startInclusive"] as? Int, 100)
    }

    func testDuplicateKeyIsRejected() {
        XCTAssertThrowsError(try PushProtocol.replaceWindowBatches(
            stream: .dailyMetric, sourceId: source, deviceId: "d",
            window: .days(startInclusive: "2026-08-05", endExclusive: "2026-08-06"),
            records: [day("2026-08-05", recovery: 1), day("2026-08-05", recovery: 2)]))
    }

    func testSnapshotHashIgnoresOrderButNotContent() throws {
        let a = try PushProtocol.snapshotHash(stream: .dailyMetric, records: [day("2026-01-01", recovery: 1),
                                                                             day("2026-01-02", recovery: 2)])
        let b = try PushProtocol.snapshotHash(stream: .dailyMetric, records: [day("2026-01-02", recovery: 2),
                                                                             day("2026-01-01", recovery: 1)])
        let c = try PushProtocol.snapshotHash(stream: .dailyMetric, records: [day("2026-01-01", recovery: 1)])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Responses

    func testAcknowledgementMustMatchExactly() throws {
        let batch = try PushProtocol.appendBatch(stream: .hrSample, sourceId: source, deviceId: "d",
                                                 startCursor: nil, records: [hr(3, 1, 60)])
        let cursor = batch.endCursor!
        func ack(_ extra: [String: Any] = [:]) -> Data {
            var obj: [String: Any] = ["protocolVersion": "1.0", "batchId": batch.batchId, "stream": "hrSample",
                                      "deviceId": "d", "acceptedRows": 1, "status": "accepted",
                                      "endCursor": ["rowId": 3, "keySha256": cursor.keySha256]]
            for (k, v) in extra { obj[k] = v }
            return try! JSONSerialization.data(withJSONObject: obj)
        }
        XCTAssertTrue(PushProtocol.acknowledgementMatches(ack(), batch: batch))
        XCTAssertFalse(PushProtocol.acknowledgementMatches(ack(["acceptedRows": 0]), batch: batch))
        XCTAssertFalse(PushProtocol.acknowledgementMatches(ack(["status": "partial"]), batch: batch))
        XCTAssertFalse(PushProtocol.acknowledgementMatches(ack(["endCursor": NSNull()]), batch: batch))
        XCTAssertFalse(PushProtocol.acknowledgementMatches(Data("nope".utf8), batch: batch))
    }

    func testCapabilitiesAreValidatedAndIntersected() throws {
        let doc = #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["dailyMetric","hrSample"],"extensions":["appleDaily"]}"#
        let caps = try PushProtocol.parseCapabilities(Data(doc.utf8))
        XCTAssertEqual(caps.streams, [.hrSample, .dailyMetric])
        XCTAssertThrowsError(try PushProtocol.parseCapabilities(Data(
            #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["mystery"]}"#.utf8)))
        XCTAssertThrowsError(try PushProtocol.parseCapabilities(Data(
            #"{"type":"capabilities","protocolVersion":"2.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":[]}"#.utf8)))
    }

    func testErrorCodeIsTheOnlyThingKeptFromAnErrorBody() {
        XCTAssertEqual(PushProtocol.errorCode(Data(#"{"type":"error","code":"registry_mismatch"}"#.utf8)),
                       "registry_mismatch")
        XCTAssertNil(PushProtocol.errorCode(Data(#"{"code":"Bad Code!"}"#.utf8)))
        XCTAssertNil(PushProtocol.errorCode(Data("<html>".utf8)))
    }

    // MARK: - Endpoint policy

    func testEndpointPolicy() {
        func ok(_ s: String) -> Bool { if case .success = PushEndpointPolicy.validate(s) { return true }; return false }
        XCTAssertTrue(ok("https://nas.example.com/api/noop"))
        XCTAssertTrue(ok("http://192.168.1.20:8700/api/noop"))
        XCTAssertTrue(ok("http://10.0.0.5:8700/api/noop"))
        XCTAssertTrue(ok("http://100.101.102.103:8700/api/noop"))   // Tailscale
        XCTAssertTrue(ok("http://[fd00::1]:8700/api/noop"))
        XCTAssertFalse(ok("http://nas.local:8700/api/noop"))
        XCTAssertFalse(ok("http://8.8.8.8/api/noop"))
        XCTAssertFalse(ok("ftp://192.168.1.2/x"))
        XCTAssertFalse(ok("https://user:pw@nas.example.com/x"))
    }

    // MARK: - Database projection

    func testProjectionReadsRegistryColumnsByRowidAndWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 200, 61)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('d', 100, 60)")   // backfilled later
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('other', 1, 50)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-08-06', 70)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, recovery) VALUES ('d', '2026-08-20', 10)")
            try db.execute(sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source) VALUES ('d', 500, 900, 'run', 'manual')")
        }
        let page = try await store.pushAppendPage(.hrSample, deviceId: "d", afterRowId: nil)
        XCTAssertEqual(page.map { $0.key[0].value }, [.int(200), .int(100)], "insertion order, not timestamp order")
        let rest = try await store.pushAppendPage(.hrSample, deviceId: "d", afterRowId: page[0].rowId)
        XCTAssertEqual(rest.count, 1)
        let again = try await store.pushRecord(.hrSample, deviceId: "d", rowId: page[1].rowId)
        XCTAssertEqual(again, page[1])
        let devices = try await store.pushDeviceIds(.hrSample)
        XCTAssertEqual(devices, ["d", "other"])

        let days = try await store.pushWindowRecords(.dailyMetric, deviceId: "d",
                                                     window: .days(startInclusive: "2026-08-05", endExclusive: "2026-08-19"))
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].data.first { $0.name == "recovery" }?.value, .double(70))

        let workouts = try await store.pushWindowRecords(.workout, deviceId: "d",
                                                         window: .timestamps(startInclusive: 0, endExclusive: 1000))
        XCTAssertEqual(workouts.count, 1)
        // iOS has no routePolyline column: exported as null rather than omitted.
        XCTAssertEqual(workouts[0].data.first { $0.name == "routePolyline" }?.value, .null)
        XCTAssertEqual(workouts[0].data.map(\.name), PushStream.workout.dataColumns.map(\.name))

        // Every v1 stream projects against the real schema.
        for stream in PushStream.allCases {
            _ = try await store.pushDeviceIds(stream)
            if stream.isAppend { _ = try await store.pushAppendPage(stream, deviceId: "d", afterRowId: nil) }
        }
    }
}
