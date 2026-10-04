import SwiftUI
import StrandDesign

/// Settings › Broadcast heart rate: both ways of sharing the live heart rate with a treadmill, bike,
/// Zwift, Peloton or a Garmin, in one place. Moved here from Data Sources, which is about bringing data
/// IN; these send it OUT.
///
/// - From this phone: NOOP advertises itself as a standard Bluetooth heart-rate sensor
///   (0x180D / 0x2A37) carrying the live strap HR it receives. Local Bluetooth only. As before, the
///   broadcaster belongs to the screen showing it: it runs while this section is on screen and the
///   toggle is on, and releases the radio when the screen goes away.
/// - From the strap: the strap's own reversible broadcast setting, applied on each connect.
struct BroadcastHeartRateSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    @AppStorage(HrBroadcaster.defaultsKey) private var broadcastHrEnabled = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var strapBroadcastHrEnabled = false

    // The broadcaster's diagnostic sink forwards to THIS box, which `onAppear` points at `live`, so the
    // broadcast-out lifecycle lines reach the same exported strap log the WHOOP path writes. Every line is
    // prefixed "HR-out: " inside HrBroadcaster; privacy-safe (statuses + a subscriber COUNT only).
    private final class LogSink { weak var live: LiveState? }
    private let broadcastLogSink: LogSink
    @StateObject private var hrBroadcaster: HrBroadcaster

    init() {
        let sink = LogSink()
        self.broadcastLogSink = sink
        _hrBroadcaster = StateObject(wrappedValue: HrBroadcaster(log: { [weak sink] line in
            // HrBroadcaster is @MainActor, so it only calls this from the main actor.
            MainActor.assumeIsolated { sink?.live?.append(log: line) }
        }))
    }

    var body: some View {
        NoopCard(padding: 18, tint: DomainTheme.effort.color) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space2 + 2) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DomainTheme.effort.color)
                        .frame(width: 30, height: 30)
                        .background(DomainTheme.effort.color.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Broadcast heart rate").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    statusPill
                }
                Text("Re-share your live strap heart rate over Bluetooth as a standard heart-rate sensor, so a gym treadmill, bike, Zwift, Peloton or any fitness app nearby can read it. Local Bluetooth only. Nothing leaves \(Platform.deviceNounPhrase). Off by default.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $broadcastHrEnabled) {
                Text("Broadcast HR from this phone")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(DomainTheme.effort.color)
            .accessibilityLabel("Broadcast heart rate as a Bluetooth sensor")
            .onChangeCompat(of: broadcastHrEnabled) { on in
                if on { hrBroadcaster.start() } else { hrBroadcaster.stop() }
            }
            Text("Acts as a standard Bluetooth heart-rate strap. Pair NOOP from your treadmill, bike or app to see your strap's heart rate there.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // FI-2 (#490) — the 4.0-vs-5.0 explainer. Broadcast works for BOTH strap generations because it
            // re-shares whatever LIVE heart rate NOOP already has off the strap; it doesn't depend on the
            // 5/MG-only deep-data path. The honest distinction is WHERE that live HR comes from (4.0 = the
            // strap's standard HR characteristic; 5/MG = PPG-derived once connected), not whether broadcast
            // works at all. Stated plainly so a 4.0 owner knows this is for them too.
            generationExplainer

            // Honest live status only while it's on: a warning note if the radio can't run, else either
            // who's reading it or that we're waiting (never a fabricated "connected").
            if broadcastHrEnabled {
                if let note = hrBroadcaster.statusNote {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if hrBroadcaster.subscriberCount > 0 {
                    let n = hrBroadcaster.subscriberCount
                    // Whole-phrase variants per count so translators never see a stitched plural.
                    Text(n == 1 ? "1 device reading your heart rate"
                                : "\(n) devices reading your heart rate")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else if let hr = live.heartRate {
                    Text("Sharing \(hr) bpm. Waiting for a device to pair.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("No live heart rate yet. Open Live to pair your strap.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 4)

            Toggle(isOn: $strapBroadcastHrEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Broadcast heart rate from the strap")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Broadcasts the strap's own live heart rate over Bluetooth.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
            .accessibilityLabel("Broadcast heart rate from the strap")
            .onChangeCompat(of: strapBroadcastHrEnabled) { model.ble.setBroadcastHr($0) }
            }
        }
        .onAppear {
            broadcastLogSink.live = live
            // Bind the broadcaster to the live HR once, and resume broadcasting if the user left it on.
            hrBroadcaster.bind(to: live)
            if broadcastHrEnabled { hrBroadcaster.start() }
        }
        .onDisappear {
            // A foreground convenience tied to this section's owned object: release the radio when the
            // screen goes away; revisiting (or toggling back on) restarts it.
            hrBroadcaster.stop()
        }
    }

    /// Real broadcast state once it's on: advertising vs starting up.
    @ViewBuilder
    private var statusPill: some View {
        if broadcastHrEnabled {
            StatePill(hrBroadcaster.advertising ? "Broadcasting" : "Starting…",
                      tone: hrBroadcaster.advertising ? .positive : .warning,
                      pulsing: !hrBroadcaster.advertising)
        } else {
            StatePill("Off", tone: .neutral, showsDot: false)
        }
    }

    /// FI-2 (#490) — a compact, honest "works with both strap generations" explainer under the broadcast
    /// toggle. Two short lines (4.0 / 5.0·MG) frame WHERE the live HR comes from on each, so a WHOOP 4.0
    /// owner knows broadcast is for them and a 5/MG owner understands the PPG-derived source — without
    /// over-promising. Plain copy, no claim that either generation is "better".
    private var generationExplainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            generationRow(title: "WHOOP 4.0",
                          detail: String(localized: "Broadcasts the strap's own live heart rate over Bluetooth."))
            generationRow(title: "WHOOP 5.0 & MG",
                          detail: String(localized: "Broadcasts the live heart rate NOOP derives from the strap once connected."))
        }
        .padding(.top, 2)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DomainTheme.effort.color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func generationRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DomainTheme.effort.color)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }
}
