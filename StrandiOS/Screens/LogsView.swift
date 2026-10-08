#if os(iOS)
import SwiftUI
import StrandDesign

/// More › Logs: local diagnostic records worth looking back at.
struct LogsView: View {
    var body: some View {
        ScreenScaffold(title: "Logs", subtitle: "Local records kept on this iPhone.") {
            StrandCard(padding: 20, tint: StrandPalette.accent) {
                NavigationLink(destination: BatteryLogView()) {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "battery.75")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Battery")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(minHeight: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
            }
        }
    }
}

/// More › Logs › Battery: the strap and phone battery each workout used (`WorkoutBatteryLog`).
struct BatteryLogView: View {
    @ObservedObject private var log = WorkoutBatteryLog.shared

    var body: some View {
        ScreenScaffold(title: "Battery",
                       subtitle: "How much strap and phone battery each workout used, from start to end.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if log.entries.isEmpty {
                    StrandCard(padding: 20, tint: StrandPalette.accent) {
                        Text("No workouts logged yet. Start a zone training and it appears here when it ends.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(log.entries) { entry in
                        entryCard(entry)
                    }
                    Button("Clear") { log.clear() }
                        .buttonStyle(NoopButtonStyle(.secondary))
                }
            }
        }
    }

    private func entryCard(_ e: WorkoutBatteryEntry) -> some View {
        StrandCard(padding: 18, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Text(verbatim: e.label)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(verbatim: Self.duration(e.duration))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(e.start.formatted(date: .abbreviated, time: .shortened))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                row("Strap", start: e.strapStart, end: e.strapEnd, used: e.strapUsed, perHour: e.perHour(e.strapUsed))
                row("Phone", start: e.phoneStart, end: e.phoneEnd, used: e.phoneUsed, perHour: e.perHour(e.phoneUsed))
            }
        }
    }

    private func row(_ title: LocalizedStringKey, start: Double?, end: Double?, used: Double?,
                     perHour: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: Self.summary(start: start, end: end, used: used, perHour: perHour))
                .font(StrandFont.subhead.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
        }
    }

    /// "82% → 74%  −8%  (−6.1%/h)"; "+" when the level rose (charging during the workout); a dash where a
    /// reading is missing. Numbers and symbols only.
    static func summary(start: Double?, end: Double?, used: Double?, perHour: Double?) -> String {
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "—" }
        // `used` is start − end, so a positive value is a drop.
        func sign(_ v: Double) -> String { v < 0 ? "+" : "−" }
        var s = "\(pct(start)) → \(pct(end))"
        if let used { s += "  " + sign(used) + String(format: "%.0f%%", abs(used)) }
        if let perHour { s += "  (" + sign(perHour) + String(format: "%.1f%%/h", abs(perHour)) + ")" }
        return s
    }

    /// Localized "1h 5m" / "42m".
    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? ""
    }
}
#endif
