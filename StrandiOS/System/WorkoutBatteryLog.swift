#if os(iOS)
import Foundation
import Combine
import UIKit

/// One workout's battery cost: the strap's and the phone's charge when it started and when it ended.
struct WorkoutBatteryEntry: Codable, Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    var end: Date?
    /// "Zone 4", "4×4 · Zone 4", or the sport name for an ordinary workout.
    var label: String
    /// Strap state of charge, percent. The first reading seen during the workout if there was none at
    /// the start (the strap reports its battery on its own cadence, about once a minute).
    var strapStart: Double?
    /// The last strap reading seen before the workout ended.
    var strapEnd: Double?
    var phoneStart: Double?
    var phoneEnd: Double?
    /// The last moment the open session was seen running, and the phone level then. Used to close a
    /// session the app was killed in, so it ends where it was last seen, not at the next launch.
    var lastSeen: Date?
    var phoneLast: Double?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    var strapUsed: Double? {
        guard let s = strapStart, let e = strapEnd else { return nil }
        return s - e
    }

    var phoneUsed: Double? {
        guard let s = phoneStart, let e = phoneEnd else { return nil }
        return s - e
    }

    /// Percent per hour, only once at least ten minutes have passed (shorter spans divide noise).
    func perHour(_ used: Double?) -> Double? {
        guard let used, duration >= 600 else { return nil }
        return used / (duration / 3600)
    }
}

/// Records the strap and phone battery at the start and end of every workout, so the cost of a zone
/// training session can be compared across settings. Purely local: a short list in UserDefaults
/// (newest first, at most 50), shown under More › Logs › Battery. Records nothing about health.
@MainActor
final class WorkoutBatteryLog: ObservableObject {
    static let shared = WorkoutBatteryLog()

    private static let entriesKey = "noop.workoutBatteryLog.entries"
    private static let pendingKey = "noop.workoutBatteryLog.pending"
    static let maxEntries = 50

    @Published private(set) var entries: [WorkoutBatteryEntry]
    private var pending: WorkoutBatteryEntry?
    private var sinks = Set<AnyCancellable>()
    private weak var model: AppModel?

    private init() {
        entries = Self.load([WorkoutBatteryEntry].self, Self.entriesKey) ?? []
        pending = Self.load(WorkoutBatteryEntry.self, Self.pendingKey)
    }

    func attach(model: AppModel) {
        self.model = model
        UIDevice.current.isBatteryMonitoringEnabled = true
        // A session left open by a relaunch with no workout to resume is closed where it was last seen.
        if model.activeWorkout == nil, pending != nil { finish(orphaned: true) }
        model.$activeWorkout
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                // `@Published` emits in willSet; read the started workout and its zone on the next turn.
                Task { @MainActor [weak self] in
                    if active { self?.begin() } else { self?.finish() }
                }
            }
            .store(in: &sinks)
        model.live.$batteryPct
            .compactMap { $0 }
            .sink { [weak self] pct in
                Task { @MainActor [weak self] in self?.noteStrap(pct) }
            }
            .store(in: &sinks)
    }

    func clear() {
        entries = []
        Self.save(entries, Self.entriesKey)
    }

    // MARK: Session

    private func begin() {
        guard pending == nil, let model, let workout = model.activeWorkout else { return }
        let phone = Self.phonePct()
        pending = WorkoutBatteryEntry(start: workout.start, end: nil, label: Self.label(model),
                                      strapStart: model.live.batteryPct, strapEnd: model.live.batteryPct,
                                      phoneStart: phone, phoneEnd: nil, lastSeen: Date(), phoneLast: phone)
        Self.save(pending, Self.pendingKey)
    }

    private func noteStrap(_ pct: Double) {
        guard var p = pending else { return }
        if p.strapStart == nil { p.strapStart = pct }
        p.strapEnd = pct
        p.lastSeen = Date()
        if let phone = Self.phonePct() { p.phoneLast = phone }
        pending = p
        Self.save(p, Self.pendingKey)
    }

    private func finish(orphaned: Bool = false) {
        guard var p = pending else { return }
        if orphaned {
            // The workout ended while the app was not running: what is true now (the time, a phone that has
            // charged since) is not what the workout cost.
            p.end = p.lastSeen ?? p.start
            p.phoneEnd = p.phoneLast
        } else {
            p.end = Date()
            p.phoneEnd = Self.phonePct()
            if let pct = model?.live.batteryPct { p.strapEnd = pct }
        }
        entries.insert(p, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        pending = nil
        Self.save(entries, Self.entriesKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    private static func label(_ model: AppModel) -> String {
        let zone = model.behavior.targetZone
        if model.behavior.targetZoneIntervals { return "4×4 · " + String(localized: "Zone \(zone)") }
        if zone > 0 { return String(localized: "Zone \(zone)") }
        return model.activeWorkout?.sport ?? ""
    }

    private static func phonePct() -> Double? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Double(level) * 100
    }

    // MARK: Storage

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
#endif
