#if os(iOS)
import Foundation
import Combine
import Security
import UIKit
import WhoopStore

/// Self-hosted push (Experimental, default off): a one-way copy of the on-device data to an HTTP(S)
/// endpoint the user runs themselves, such as noopzonedocker on a NAS. Protocol 1.0, docs/PUSH_PROTOCOL.md;
/// the iPhone twin of Android's `com.noop.push` client. Issue #1314 is the scope boundary: the receiver
/// never sends data or commands back, nothing is read from it but its capability list and per-batch
/// acknowledgements, and no receiver ships in this repository.
///
/// When it runs: after a strap sync completes while NOOP is open (and within the minute the sleep mode
/// leaves for syncing), and when the user taps "Push now". It never wakes the app on its own.
@MainActor
final class SelfHostedPushClient: ObservableObject {
    static let shared = SelfHostedPushClient()

    // MARK: Settings

    enum Keys {
        static let enabled = "noop.selfHostedPush.enabled"
        static let endpoint = "noop.selfHostedPush.endpoint"
        static let sourceId = "noop.selfHostedPush.sourceId"
        static let progress = "noop.selfHostedPush.progress"
        static let lastSuccess = "noop.selfHostedPush.lastSuccess"
        static let lastError = "noop.selfHostedPush.lastError"
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled); objectWillChange.send() }
    }

    var endpoint: String {
        get { UserDefaults.standard.string(forKey: Keys.endpoint) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.endpoint); objectWillChange.send() }
    }

    var hasToken: Bool { Keychain.read() != nil }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete() } else { Keychain.write(trimmed) }
        objectWillChange.send()
    }

    /// The installation's random source id, generated once (protocol `sourceId`).
    var sourceId: String {
        if let id = UserDefaults.standard.string(forKey: Keys.sourceId) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: Keys.sourceId)
        return id
    }

    // MARK: Status

    @Published private(set) var running = false
    @Published private(set) var lastSuccess: Date? = UserDefaults.standard.object(forKey: Keys.lastSuccess) as? Date
    /// A short, safe status: an HTTP status, a receiver error code, or a transport category. Never a raw
    /// response body or exception text, which could carry the endpoint, the token or health data.
    @Published private(set) var lastError: String? = UserDefaults.standard.string(forKey: Keys.lastError)
    @Published private(set) var lastSentRecords = 0

    private var sinks = Set<AnyCancellable>()
    private weak var model: AppModel?

    /// Push after every completed strap sync while enabled.
    func attach(model: AppModel) {
        self.model = model
        model.live.$lastSyncedAt
            .compactMap { $0 }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.enabled else { return }
                Task { await self.pushNow() }
            }
            .store(in: &sinks)
    }

    // MARK: Actions

    /// "Test connection": the authenticated capability GET alone. Opens no database, sends no data.
    func testConnection() async -> String {
        switch await capabilities() {
        case .success(let caps):
            return String(localized: "Connected. The server accepts \(caps.caps.streams.count) of 12 data types.")
        case .failure(let failure):
            record(error: failure.code)
            return failure.message
        }
    }

    /// One complete push run. Safe to call repeatedly: runs never overlap.
    func pushNow() async {
        guard !running, let model else { return }
        running = true
        lastSentRecords = 0
        let task = UIApplication.shared.beginBackgroundTask(withName: "noop.selfHostedPush")
        defer {
            running = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        let negotiated: Negotiated
        switch await capabilities() {
        case .success(let n): negotiated = n
        case .failure(let f): record(error: f.code); return
        }
        guard let store = await model.repo.storeHandle() else { record(error: "database_unavailable"); return }
        do {
            for stream in negotiated.caps.streams {
                if stream.isAppend {
                    try await pushAppend(stream, store: store, negotiated)
                } else {
                    try await pushWindows(stream, store: store, negotiated)
                }
            }
            lastSuccess = Date()
            UserDefaults.standard.set(lastSuccess, forKey: Keys.lastSuccess)
            record(error: nil)
            model.live.append(log: AppModel.stamped("Self-hosted push: sent \(lastSentRecords) records"))
        } catch let failure as Failure {
            record(error: failure.code)
            model.live.append(log: AppModel.stamped("Self-hosted push stopped: \(failure.code)"))
        } catch {
            record(error: "local_error")
            model.live.append(log: AppModel.stamped("Self-hosted push stopped: local error"))
        }
    }

    private func record(error: String?) {
        lastError = error
        UserDefaults.standard.set(error, forKey: Keys.lastError)
    }

    // MARK: Capabilities

    struct Negotiated {
        let url: URL
        let token: String
        let caps: PushProtocol.Capabilities
        /// Local progress is scoped to (source, endpoint, version, receiver state); any change rebaselines.
        let namespace: String
    }

    struct Failure: Error {
        let code: String
        var message: String {
            if code.hasPrefix("http_401") || code.hasPrefix("http_403") {
                return String(localized: "The server refused the token.")
            }
            switch code {
            case "not_configured": return String(localized: "Add the server address and token first.")
            case "invalid_endpoint": return String(localized: "Use https://, or http:// with a LAN or Tailscale IP address.")
            case "offline": return String(localized: "Couldn't reach the server.")
            default: return String(localized: "Server error: \(code)")
            }
        }
    }

    private func capabilities() async -> Result<Negotiated, Failure> {
        guard let token = Keychain.read(), !endpoint.isEmpty else { return .failure(Failure(code: "not_configured")) }
        guard case .success(let url) = PushEndpointPolicy.validate(endpoint) else {
            return .failure(Failure(code: "invalid_endpoint"))
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(PushProtocol.version, forHTTPHeaderField: "NOOP-Push-Accept-Version")
        let result: (Data, Int)
        do { result = try await send(req) } catch { return .failure(Failure(code: "offline")) }
        let (data, status) = result
        guard (200..<300).contains(status) else {
            return .failure(Failure(code: PushProtocol.errorCode(data).map { "http_\(status)_\($0)" } ?? "http_\(status)"))
        }
        guard let caps = try? PushProtocol.parseCapabilities(data) else {
            return .failure(Failure(code: "invalid_capabilities"))
        }
        let namespace = PushSHA256.hex(Data("\(sourceId)\n\(url.absoluteString)\n\(caps.protocolVersion)\n\(caps.receiverStateId)".utf8))
        return .success(Negotiated(url: url, token: token, caps: caps, namespace: namespace))
    }

    // MARK: Delivery

    private func post(_ batch: PushBatch, _ n: Negotiated) async throws {
        var req = URLRequest(url: n.url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(n.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = batch.body
        let result: (Data, Int)
        do { result = try await send(req) } catch { throw Failure(code: "offline") }
        let (data, status) = result
        guard (200..<300).contains(status) else {
            throw Failure(code: PushProtocol.errorCode(data).map { "http_\(status)_\($0)" } ?? "http_\(status)")
        }
        guard PushProtocol.acknowledgementMatches(data, batch: batch) else { throw Failure(code: "invalid_ack") }
        lastSentRecords += batch.recordCount
    }

    /// Upper bound on append batches per stream per run, so one run stays inside its background time.
    /// A first baseline of a large history simply continues on the next run from the saved cursor.
    private static let maxAppendBatchesPerRun = 40

    private func pushAppend(_ stream: PushStream, store: WhoopStore, _ n: Negotiated) async throws {
        for deviceId in try await store.pushDeviceIds(stream) {
            var cursor = progress.cursor(n.namespace, deviceId, stream)
            if let saved = cursor {
                // A restore, prune or rowid rewrite invalidates insertion positions: replay from the start.
                let row = try await store.pushRecord(stream, deviceId: deviceId, rowId: saved.rowId)
                let fp = try row.map { try PushProtocol.keyFingerprint(stream: stream, deviceId: deviceId, key: $0.key) }
                if fp != saved.keySha256 { cursor = nil }
            }
            for _ in 0..<Self.maxAppendBatchesPerRun {
                let page = try await store.pushAppendPage(stream, deviceId: deviceId, afterRowId: cursor?.rowId)
                guard !page.isEmpty else { break }
                let batch = try PushProtocol.appendBatch(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                                         startCursor: cursor, records: page)
                try await post(batch, n)
                cursor = batch.endCursor
                progress.setCursor(cursor, n.namespace, deviceId, stream)
            }
        }
    }

    /// The rolling 14-day authoritative window (today plus the 13 days before), sent as the smallest
    /// span covering the days whose local snapshot changed since the last acknowledged run.
    private func pushWindows(_ stream: PushStream, store: WhoopStore, _ n: Negotiated) async throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (0..<14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let devices = Set(try await store.pushDeviceIds(stream)).union(progress.devices(n.namespace, stream))
        for deviceId in devices.sorted() {
            var hashes: [String: String] = [:]
            var changed: [Date] = []
            for day in days {
                let records = try await store.pushWindowRecords(stream, deviceId: deviceId,
                                                                window: Self.bounds(stream, from: day, to: day))
                let hash = try PushProtocol.snapshotHash(stream: stream, records: records)
                let key = Repository.dayString(day)
                hashes[key] = hash
                if progress.dayHash(n.namespace, deviceId, stream, key) != hash { changed.append(day) }
            }
            guard let first = changed.first, let last = changed.last else { continue }
            let window = Self.bounds(stream, from: first, to: last)
            let records = try await store.pushWindowRecords(stream, deviceId: deviceId, window: window)
            for batch in try PushProtocol.replaceWindowBatches(stream: stream, sourceId: sourceId, deviceId: deviceId,
                                                               window: window, records: records) {
                try await post(batch, n)
            }
            progress.replaceDayHashes(hashes, n.namespace, deviceId, stream)
            progress.addDevice(deviceId, n.namespace, stream)
        }
    }

    /// Half-open local-day bounds from the start of `from` to the end of `to`.
    static func bounds(_ stream: PushStream, from: Date, to: Date) -> PushWindowBounds {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to
        if stream.selectorColumn == "day" {
            return .days(startInclusive: Repository.dayString(start), endExclusive: Repository.dayString(end))
        }
        return .timestamps(startInclusive: Int64(start.timeIntervalSince1970),
                           endExclusive: Int64(end.timeIntervalSince1970))
    }

    // MARK: Transport

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: req)
        guard data.count <= max(PushProtocol.maxResponseBytes, 64 * 1024) else { return (Data(), -1) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// Redirects are never followed, so the bearer token can never be forwarded to another host.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: Progress

    private var progress = PushProgress()

    /// Local delivery progress, never transmitted: append cursors, per-day window hashes and the devices
    /// seen per stream, each under the destination namespace.
    struct PushProgress {
        private var store: [String: String] {
            get { UserDefaults.standard.dictionary(forKey: Keys.progress) as? [String: String] ?? [:] }
            nonmutating set { UserDefaults.standard.set(newValue, forKey: Keys.progress) }
        }

        func cursor(_ ns: String, _ device: String, _ stream: PushStream) -> PushCursor? {
            store["c|\(ns)|\(device)|\(stream.rawValue)"].flatMap { try? JSONDecoder().decode(PushCursor.self, from: Data($0.utf8)) }
        }

        func setCursor(_ c: PushCursor?, _ ns: String, _ device: String, _ stream: PushStream) {
            store["c|\(ns)|\(device)|\(stream.rawValue)"] = c.flatMap { try? JSONEncoder().encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
        }

        func dayHash(_ ns: String, _ device: String, _ stream: PushStream, _ day: String) -> String? {
            store["h|\(ns)|\(device)|\(stream.rawValue)|\(day)"]
        }

        /// Store one run's per-day hashes (the whole window) in a single write, dropping the days that have
        /// left the window so the store does not grow by a key per day forever.
        func replaceDayHashes(_ hashes: [String: String], _ ns: String, _ device: String, _ stream: PushStream) {
            let prefix = "h|\(ns)|\(device)|\(stream.rawValue)|"
            var all = store
            for key in all.keys where key.hasPrefix(prefix) && hashes[String(key.dropFirst(prefix.count))] == nil {
                all[key] = nil
            }
            for (day, hash) in hashes { all[prefix + day] = hash }
            store = all
        }

        func devices(_ ns: String, _ stream: PushStream) -> [String] {
            (store["d|\(ns)|\(stream.rawValue)"] ?? "").split(separator: "\n").map(String.init)
        }

        func addDevice(_ device: String, _ ns: String, _ stream: PushStream) {
            var all = Set(devices(ns, stream))
            all.insert(device)
            store["d|\(ns)|\(stream.rawValue)"] = all.sorted().joined(separator: "\n")
        }
    }

    // MARK: Keychain

    /// The bearer token lives only in the Keychain, this device only, never in UserDefaults or a backup.
    enum Keychain {
        private static let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "noop.selfHostedPush",
            kSecAttrAccount as String: "token",
        ]

        static func read() -> String? {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func write(_ token: String) {
            delete()
            var q = base
            q[kSecValueData as String] = Data(token.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }

        static func delete() {
            SecItemDelete(base as CFDictionary)
        }
    }
}
#endif
