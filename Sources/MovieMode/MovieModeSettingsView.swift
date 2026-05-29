import AppKit
import ApplicationServices
import FocusMonitorCore
import SwiftUI

struct MovieModeSettingsView: View {
    @ObservedObject var store: ObservableMovieModeSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            autoSection
            displayRuleSection
            detectionSection
        }
        .padding(24)
        .frame(width: 520, alignment: .topLeading)
    }

    private var autoSection: some View {
        GroupBox("Auto Movie Mode") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable auto movie mode", isOn: autoEnabledBinding)
                Text("When off, use the menu bar icon to control movie mode manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var displayRuleSection: some View {
        GroupBox("Display Rule") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Keep visible", selection: displayRuleBinding) {
                    Text("Playing display").tag(DisplayRule.playing)
                    Text("Main display").tag(DisplayRule.main)
                    Text("Watch display").tag(DisplayRule.watch)
                }
                .pickerStyle(.radioGroup)

                Toggle("Also keep Main Display visible", isOn: pinMainBinding)

                if store.settings.displayRule == .watch {
                    Picker("Watch display", selection: watchDisplayBinding) {
                        ForEach(store.availableDisplays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var detectionSection: some View {
        GroupBox("Detection") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use Accessibility for browser detection", isOn: accessibilityBinding)
                Text("Recommended for YouTube and other browsers. Uses window heuristics when off; when on, also reads browser fullscreen state (requires Accessibility permission).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var autoEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.autoMovieModeEnabled },
            set: { newValue in store.update { $0.autoMovieModeEnabled = newValue } }
        )
    }

    private var pinMainBinding: Binding<Bool> {
        Binding(
            get: { store.settings.pinMainDisplay },
            set: { newValue in store.update { $0.pinMainDisplay = newValue } }
        )
    }

    private var accessibilityBinding: Binding<Bool> {
        Binding(
            get: { store.settings.useAccessibilityDetection },
            set: { newValue in
                store.update { $0.useAccessibilityDetection = newValue }
                if newValue {
                    requestAccessibilityPermission()
                }
            }
        )
    }

    private var displayRuleBinding: Binding<DisplayRule> {
        Binding(
            get: { store.settings.displayRule },
            set: { newValue in store.update { $0.displayRule = newValue } }
        )
    }

    private var watchDisplayBinding: Binding<String> {
        Binding(
            get: { store.settings.watchDisplayID ?? store.availableDisplays.first?.id ?? "" },
            set: { newValue in store.update { $0.watchDisplayID = newValue } }
        )
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

struct DisplayOption: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class ObservableMovieModeSettingsStore: ObservableObject {
    @Published private(set) var settings: MovieModeSettings
    @Published private(set) var availableDisplays: [DisplayOption] = []

    private let defaultsStore: UserDefaultsMovieModeSettingsStore
    var onSettingsChanged: ((MovieModeSettings) -> Void)?

    init(defaultsStore: UserDefaultsMovieModeSettingsStore = UserDefaultsMovieModeSettingsStore()) {
        self.defaultsStore = defaultsStore
        self.settings = defaultsStore.settings
    }

    func refreshDisplays() {
        availableDisplays = NSScreen.screens.map { screen in
            let name = screen.localizedName
            let id = screen.movieModeScreenID
            let mainSuffix = screen == NSScreen.main ? " (Main)" : ""
            return DisplayOption(id: id, name: "\(name)\(mainSuffix)")
        }

        applyDefaultWatchDisplayIDIfNeeded()
    }

    /// Updates watch display default without running `onSettingsChanged` (avoids re-entrancy while opening Settings).
    private func applyDefaultWatchDisplayIDIfNeeded() {
        guard settings.watchDisplayID == nil,
              let mainID = NSScreen.main?.movieModeScreenID
        else {
            return
        }

        var next = settings
        next.watchDisplayID = mainID
        settings = next
        defaultsStore.settings = next
    }

    func update(_ transform: (inout MovieModeSettings) -> Void) {
        var next = settings
        transform(&next)
        settings = next
        defaultsStore.settings = next
        onSettingsChanged?(next)
    }
}
