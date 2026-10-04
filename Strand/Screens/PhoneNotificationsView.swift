#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications
import StrandDesign

/// Notifications (iPhone): every notification NOOP can post on this phone, in one place.
///
/// Before this screen they were spread over three others: the Live Activities in Settings, and the
/// zone-training, battery, strain-target and illness switches in Automations. Each switch here is the
/// SAME stored preference those screens bound (moved, not copied), and each keeps the side effect it
/// had there, so nothing about when a notification fires changes.
///
/// Two reminders keep their switch where the rest of their settings live, because a switch without its
/// time picker would be half a control: the wind-down nudge (Alarms, beside the wake time it is worked
/// out from) and the morning brief (AI Coach, which writes it). They appear here as links that read
/// their state from the same source those screens do.
///
/// Wrist buzzes are not phone notifications and stay in Automations. The macOS twin is
/// `NotificationSettingsView`, which picks the Mac apps that tap the wrist; it is excluded from iOS.
struct PhoneNotificationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = false
    @AppStorage(UnitPrefs.liftLiveActivityKey) private var liftLiveActivityEnabled = true
    @AppStorage(UnitPrefs.syncLiveActivityKey) private var syncLiveActivityEnabled = true
    @AppStorage("noop.coachEnabled") private var coachEnabled = true

    /// iOS's own answer to "may NOOP notify?", re-read on appear and on every return to the app (the user
    /// changes it in the Settings app). Nil until the first read lands.
    @State private var authorization: UNAuthorizationStatus?

    /// The two reminders' switches live on their own screens; re-read on every appear, which includes
    /// coming back from those screens.
    @State private var windDownOn = WindDownNudge.isEnabled
    @State private var briefOn = CoachBriefScheduler.isEnabled

    var body: some View {
        ScreenScaffold(title: "Notifications",
                       subtitle: "Everything NOOP can notify you about on this iPhone, in one place.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                permissionCard
                trainingCard
                strapCard
                healthCard
                remindersCard
                liveActivitiesCard
            }
        }
        .task { await refreshAuthorization() }
        .onAppear {
            windDownOn = WindDownNudge.isEnabled
            briefOn = CoachBriefScheduler.isEnabled
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active { Task { await refreshAuthorization() } }
        }
    }

    // MARK: - Permission

    private var permissionCard: some View {
        NotificationsSection(icon: "bell.badge.fill", title: "Allow notifications") {
            HStack(spacing: NoopMetrics.space3) {
                StatePill(permissionTitle, tone: permissionTone, showsDot: true)
                Spacer(minLength: 0)
                switch authorization {
                case .notDetermined?:
                    Button("Allow notifications") { requestPermission() }
                        .buttonStyle(NoopButtonStyle(.secondary))
                case .denied?:
                    Button("Open iOS Settings") { openSystemSettings() }
                        .buttonStyle(NoopButtonStyle(.secondary))
                default:
                    EmptyView()
                }
            }
            if authorization == .denied {
                Text("iOS is blocking NOOP's notifications, so none of the switches below can show anything until you allow them.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionTitle: LocalizedStringKey {
        switch authorization {
        case .authorized?, .provisional?, .ephemeral?: return "Allowed"
        case .denied?: return "Off in iOS Settings"
        case .notDetermined?: return "Not asked yet"
        default: return "Checking…"
        }
    }

    private var permissionTone: StrandTone {
        switch authorization {
        case .authorized?, .provisional?, .ephemeral?: return .positive
        case .denied?: return .critical
        default: return .neutral
        }
    }

    // MARK: - Training

    private var trainingCard: some View {
        NotificationsSection(icon: "figure.run", title: "Workouts") {
            NotificationToggleRow(label: "Phone notifications",
                                  help: "Mirror each target-zone cue as a notification on this device. A new one replaces the last.",
                                  isOn: $behavior.targetZoneNotifications)
            rowDivider
            NotificationToggleRow(label: "Notify when optimal strain is reached",
                                  help: "Posts after your strap syncs and NOOP scores the day — not the exact second you cross it. At most once per day.",
                                  isOn: $behavior.strainTargetNudge)
                .onChangeCompat(of: behavior.strainTargetNudge) { on in
                    if on {
                        StrainTargetNotifier.requestAuthorization()
                        // The repo.$days sink only fires on data changes, so a target already reached
                        // today is evaluated now rather than at the next refresh (as Automations did).
                        model.evaluateStrainTarget()
                    }
                }
        }
    }

    // MARK: - Strap

    private var strapCard: some View {
        NotificationsSection(icon: "battery.25", title: "Battery alerts") {
            NotificationToggleRow(label: "Notify on low and full battery",
                                  help: "A reminder to recharge before bed when the strap drops to 15%, and a heads-up when it reaches 100%, each at most once per charge cycle.",
                                  isOn: $behavior.batteryAlerts)
                .onChangeCompat(of: behavior.batteryAlerts) { on in
                    if on { BatteryNotifier.requestAuthorization() }
                }
            if behavior.batteryAlerts {
                rowDivider
                NotificationToggleRow(label: "Predictive runtime warning",
                                      help: "An early \"recharge tonight\" heads-up when the strap has about a day of estimated runtime left, at most once per discharge cycle. Turn off to keep only the 15% warning.",
                                      isOn: $behavior.batteryPredictiveAlerts)
            }
        }
    }

    // MARK: - Health

    private var healthCard: some View {
        NotificationsSection(icon: "waveform.path.ecg", title: "Illness early-warning") {
            NotificationToggleRow(label: "Watch for early-illness signs",
                                  help: "Needs at least 14 days of history. When two or more signals drift together you get a banner on the dashboard and a notification, at most once a day.",
                                  isOn: $behavior.illnessWatch)
                .onChangeCompat(of: behavior.illnessWatch) { _ in
                    model.reevaluateIllness()
                    if behavior.illnessWatch { IllnessNotifier.requestAuthorization() }
                }
        }
    }

    // MARK: - Reminders (switch lives with the rest of their settings)

    private var remindersCard: some View {
        NotificationsSection(icon: "clock.fill", title: "Reminders") {
            NavigationLink(destination: SmartAlarmView()) {
                linkRow("Remind me to wind down", on: windDownOn)
            }
            .buttonStyle(LiquidPressStyle())
            if coachEnabled {
                rowDivider
                NavigationLink(destination: CoachView()) {
                    linkRow("Morning brief", on: briefOn)
                }
                .buttonStyle(LiquidPressStyle())
            }
        }
    }

    private func linkRow(_ title: LocalizedStringKey, on: Bool) -> some View {
        HStack {
            Text(title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(on ? "On" : "Off")
                .font(StrandFont.footnote)
                .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
    }

    // MARK: - Live Activities (moved from Settings)

    /// NOOP's Live Activities, on the Lock Screen and in the Dynamic Island. A switch only decides whether
    /// one is SHOWN: the heart rate is still measured and recorded, a session still runs, a sync still runs.
    private var liveActivitiesCard: some View {
        NotificationsSection(icon: "bell.badge", title: "Live notifications",
                             blurb: "Shown on the Lock Screen and in the Dynamic Island. A switch only hides one: NOOP still measures and records everything.") {
            NotificationToggleRow(label: "Live heart rate", help: "While the strap is connected.",
                                  isOn: $liveActivityEnabled)
            rowDivider
            NotificationToggleRow(label: "Lift Log session",
                                  help: "Your set, rest and heart rate, and the Lock Screen light-up on a double-tap.",
                                  isOn: $liftLiveActivityEnabled)
            rowDivider
            NotificationToggleRow(label: "Strap sync", help: "Progress while NOOP pulls history from the strap.",
                                  isOn: $syncLiveActivityEnabled)
        }
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 4)
    }

    @MainActor
    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            Task { @MainActor in await refreshAuthorization() }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Section card + switch row (the Automations idiom)

private struct NotificationsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var blurb: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                if let blurb {
                    Text(blurb).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 0) { content() }
            }
        }
    }
}

private struct NotificationToggleRow: View {
    let label: LocalizedStringKey
    let help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel(Text(label))
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }
}
#endif
