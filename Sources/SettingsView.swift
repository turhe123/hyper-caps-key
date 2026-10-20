import ServiceManagement
import SwiftUI

/// The Settings window: source key, tap behaviour, launch at login, permission status and test pad.
struct SettingsView: View {
    @EnvironmentObject private var engine: HyperEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Hyper Key") {
                Toggle("Enabled", isOn: $engine.enabled)
                Picker("Source key", selection: $engine.sourceKey) {
                    ForEach(SourceKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Hyper applies", selection: $engine.mode) {
                    ForEach(HyperMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Quick tap action", selection: $engine.tapAction) {
                    ForEach(TapAction.allCases) { Text($0.title).tag($0) }
                }
                .disabled(engine.mode == .latch)
                if engine.mode == .latch {
                    note("In latch mode a quick tap arms Hyper for the next key press instead.")
                }
                if engine.usingFallback {
                    note("Caps Lock could not be remapped, so Right Command is acting as Hyper.")
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                if let loginError { note(loginError) }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: engine.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(engine.trusted ? .green : .orange)
                    Text(engine.trusted ? "Accessibility access granted" : "Accessibility access needed")
                    Spacer()
                    if !engine.trusted {
                        Button("Grant…") { engine.requestAccessibility() }
                    }
                }
                if !engine.trusted {
                    note("Hyper stays off until HyperCapsKey is allowed in System Settings › Privacy & Security › Accessibility.")
                }
            }

            Section("Test Pad") {
                TestPadView()
            }

            Section {
                HStack {
                    Spacer()
                    Button("Support / Donate ❤️") { openDonationPage() }
                        .controlSize(.large)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Shows the last key event's code and modifier flags while visible; cleared when closed.
struct TestPadView: View {
    @EnvironmentObject private var engine: HyperEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let event = engine.lastEvent {
                LabeledContent("Event", value: event.kind)
                LabeledContent("Key code", value: "\(event.keyCode)")
                LabeledContent("Flags", value: event.flags)
                    .foregroundStyle(event.flags.contains("⌃ ⌥ ⇧ ⌘") ? Color.accentColor : .primary)
            } else {
                Text(engine.running ? "Press any key combination to see it here." : "Enable Hyper to use the test pad.")
                    .foregroundStyle(.secondary)
            }
            Text("Only key codes are shown — typed characters are never recorded. Secure input fields such as password boxes may block Hyper while they have focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { engine.testPadVisible = true }
        .onDisappear { engine.testPadVisible = false }
    }
}
