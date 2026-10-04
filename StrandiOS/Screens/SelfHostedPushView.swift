#if os(iOS)
import SwiftUI
import StrandDesign

/// Settings › Sync › Self-hosted server: the Experimental, default-off one-way copy to a server the user
/// runs (noopzonedocker). See `SelfHostedPushClient` and docs/PUSH_PROTOCOL.md.
struct SelfHostedPushView: View {
    @ObservedObject private var client = SelfHostedPushClient.shared

    @State private var endpoint = SelfHostedPushClient.shared.endpoint
    @State private var token = ""
    @State private var enabled = SelfHostedPushClient.shared.enabled
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScreenScaffold(title: "Self-hosted server",
                       subtitle: "Send a one-way copy of your data to a server you run, such as noopzonedocker on a NAS.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                StrandCard(padding: 20, tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        Toggle(isOn: $enabled) {
                            Text("Send after each sync")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(StrandPalette.accent)
                        .onChangeCompat(of: enabled) { client.enabled = $0 }

                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Server address")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            TextField("http://192.168.1.20:8700/api/noop", text: $endpoint)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Use https://, or http:// with a LAN or Tailscale IP address.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Token")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            SecureField(client.hasToken ? "Saved. Type to replace." : "NOOP_PUSH_TOKEN", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        HStack(spacing: NoopMetrics.space3) {
                            Button(testing ? "Testing…" : "Save and test connection") { saveAndTest() }
                                .buttonStyle(NoopButtonStyle(.secondary))
                                .disabled(testing)
                            Button(client.running ? "Sending…" : "Push now") {
                                save()
                                Task { await client.pushNow() }
                            }
                            .buttonStyle(NoopButtonStyle(.secondary))
                            .disabled(client.running)
                        }

                        if let testResult {
                            Text(testResult)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        status
                    }
                }

                StrandCard(padding: 20, tint: StrandPalette.accent) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Privacy").strandOverline()
                        Text("NOOP sends a one-way copy of the data stored on this iPhone. The server cannot send commands or health data back. The token is kept in the iOS Keychain on this device only. Off by default.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = client.lastError {
            Text("Last attempt failed: \(error)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
        } else if let last = client.lastSuccess {
            Text("Last sent \(last.formatted(date: .abbreviated, time: .shortened))")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func save() {
        client.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            client.setToken(token)
            token = ""
        }
    }

    private func saveAndTest() {
        save()
        testing = true
        Task {
            testResult = await client.testConnection()
            testing = false
        }
    }
}
#endif
