import AppKit
import FocusMonitorCore
import SwiftUI

@main
struct MovieModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar (LSUIElement) apps cannot use the system Settings window; AppDelegate opens a custom window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let persistedSettings: UserDefaultsMovieModeSettingsStore
    let settingsStore: ObservableMovieModeSettingsStore
    private lazy var settingsWindowController = SettingsWindowController(settingsStore: settingsStore)

    private let displayProvider = AppKitDisplayProvider()
    private let shieldManager = AppKitShieldManager()
    private lazy var shieldController = DisplayShieldController(
        displayProvider: displayProvider,
        shieldManager: shieldManager
    )
    private lazy var coordinator = MovieModeCoordinator(
        displayProvider: displayProvider,
        shieldController: shieldController,
        settings: settingsStore.settings
    )
    private lazy var fullscreenDetector = CompositeFullscreenDetector(settingsStore: persistedSettings)

    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        let persisted = UserDefaultsMovieModeSettingsStore()
        self.persistedSettings = persisted
        self.settingsStore = ObservableMovieModeSettingsStore(defaultsStore: persisted)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        observeScreenChanges()
        observeWorkspaceEvents()
        configureSettings()
        configureDetector()
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fullscreenDetector.stop()
        shieldController.deactivateMovieMode()

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func configureSettings() {
        settingsStore.onSettingsChanged = { [weak self] settings in
            guard let self else {
                return
            }

            self.coordinator.updateSettings(settings)
            self.fullscreenDetector.restartIfNeeded()

            if settings.autoMovieModeEnabled {
                self.fullscreenDetector.start()
            } else {
                self.fullscreenDetector.stop()
            }

            self.updateStatusItem()
        }
    }

    private func configureDetector() {
        fullscreenDetector.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.coordinator.handleFullscreenEvent(event)
                self?.updateStatusItem()
            }
        }

        if settingsStore.settings.autoMovieModeEnabled {
            fullscreenDetector.start()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingsStore.refreshDisplays()
                self?.coordinator.handleDisplayConfigurationChanged()
                if self?.shieldController.isMovieModeActive == true,
                   self?.shieldController.activationSource == .auto {
                    // Keep session while auto-shielding; shield windows can disturb one scan cycle.
                    self?.fullscreenDetector.scanNow()
                } else {
                    self?.fullscreenDetector.resync()
                }
                self?.updateStatusItem()
            }
        }
    }

    private func observeWorkspaceEvents() {
        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settingsStore.settings.autoMovieModeEnabled else {
                    return
                }

                self.fullscreenDetector.resync()
            }
        }
        workspaceObservers.append(wakeObserver)

        let sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settingsStore.settings.autoMovieModeEnabled else {
                    return
                }

                self.fullscreenDetector.resync()
            }
        }
        workspaceObservers.append(sessionObserver)
    }

    private func syncDetectorAfterMovieModeChange() {
        if shieldController.isMovieModeActive {
            return
        }

        fullscreenDetector.resetTracking()
        if settingsStore.settings.autoMovieModeEnabled {
            fullscreenDetector.scanNow()
        }
    }

    @objc private func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        coordinator.toggleManualMovieModePreservingAutoIfActive()
        syncDetectorAfterMovieModeChange()
        updateStatusItem()
    }

    @objc private func quit() {
        fullscreenDetector.stop()
        shieldController.deactivateMovieMode()
        NSApplication.shared.terminate(nil)
    }

    @objc private func toggleAutoMovieMode() {
        settingsStore.update { $0.autoMovieModeEnabled.toggle() }
    }

    @objc private func openSettings() {
        // Defer until after the status item menu closes; opening a window from the menu action can crash.
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowController.show()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else {
            return
        }

        let image = NSImage(
            systemSymbolName: shieldController.menuBarSymbolName,
            accessibilityDescription: "MovieMode"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = statusTooltip
    }

    private var statusTooltip: String {
        var parts = [shieldController.statusText]
        if settingsStore.settings.autoMovieModeEnabled {
            parts.append("Auto on")
        }
        return parts.joined(separator: " · ")
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else {
            return
        }

        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: shieldController.statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let toggleItem = NSMenuItem(title: shieldController.toggleTitle, action: #selector(handleStatusItemClick), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let autoItem = NSMenuItem(
            title: "Auto Movie Mode",
            action: #selector(toggleAutoMovieMode),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.state = settingsStore.settings.autoMovieModeEnabled ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MovieMode", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}
