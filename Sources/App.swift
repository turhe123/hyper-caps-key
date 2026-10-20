import AppKit
import SwiftUI

/// Opens the developer's donation page.
func openDonationPage() {
    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
}

/// App entry point: a menu bar item plus a Settings window, both driven by one `HyperEngine`.
@main
struct HyperCapsKeyApp: App {
    @StateObject private var engine = HyperEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(engine)
        } label: {
            Image(systemName: engine.hyperActive ? "keyboard.fill" : "keyboard")
        }
        Settings {
            SettingsView().environmentObject(engine)
        }
    }
}

/// The menu bar dropdown. Shows only a Grant item when Accessibility is missing.
struct MenuContent: View {
    @EnvironmentObject private var engine: HyperEngine

    var body: some View {
        if engine.trusted {
            Toggle("Enabled", isOn: $engine.enabled)
            Picker("Quick tap action", selection: $engine.tapAction) {
                ForEach(TapAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        } else {
            Button("Grant Accessibility…") { engine.requestAccessibility() }
        }
        Divider()
        SettingsLink { Text("Open Settings…") }
            .keyboardShortcut(",")
        Button("Support / Donate ❤️") { openDonationPage() }
        Divider()
        Button("Quit HyperCapsKey") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
