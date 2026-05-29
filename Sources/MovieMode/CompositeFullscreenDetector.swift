import AppKit
import ApplicationServices
import FocusMonitorCore

@MainActor
final class CompositeFullscreenDetector: FullscreenPlaybackDetecting {
    var onEvent: ((FullscreenPlaybackEvent) -> Void)?

    private var scheduler: FullscreenScanScheduler?
    private var workspaceObserver: NSObjectProtocol?
    private var activeSession: (displayID: String, bundleIdentifier: String)?
    private let settingsStore: MovieModeSettingsStore

    init(settingsStore: MovieModeSettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        stop()

        let scheduler = FullscreenScanScheduler { [weak self] in
            self?.scan()
        }
        scheduler.start()
        self.scheduler = scheduler

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
            }
        }

        scan()
    }

    func stop() {
        scheduler?.stop()
        scheduler = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        if activeSession != nil {
            emitExitedIfNeeded()
        }
    }

    func restartIfNeeded() {
        stop()
        start()
    }

    func resetTracking() {
        activeSession = nil
    }

    func scanNow() {
        scan()
    }

    func resync() {
        resetTracking()
        scanNow()
    }

    private func scan() {
        if let match = findFullscreenMatch() {
            applyMatch(match)
        } else {
            emitExitedIfNeeded()
        }
    }

    private func findFullscreenMatch() -> (displayID: String, bundleIdentifier: String)? {
        let allowlist = MovieModeBundleAllowlist.resolvedIdentifiers(from: settingsStore.settings)
        let settings = settingsStore.settings
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]

        let match = FullscreenMatchSelector.selectBest(
            cgWindowList: windowList,
            screens: NSScreen.screens,
            allowlist: allowlist,
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            includeAccessibility: settings.useAccessibilityDetection
        )

        guard let match else {
            return nil
        }

        return (match.displayID, match.bundleIdentifier)
    }

    private func applyMatch(_ match: (displayID: String, bundleIdentifier: String)) {
        if let activeSession, activeSession.displayID == match.displayID, activeSession.bundleIdentifier == match.bundleIdentifier {
            return
        }

        emitExitedIfNeeded()
        activeSession = match
        onEvent?(
            FullscreenPlaybackEvent(
                kind: .entered,
                displayID: match.displayID,
                bundleIdentifier: match.bundleIdentifier
            )
        )
    }

    private func emitExitedIfNeeded() {
        guard let activeSession else {
            return
        }

        self.activeSession = nil
        onEvent?(
            FullscreenPlaybackEvent(
                kind: .exited,
                displayID: activeSession.displayID,
                bundleIdentifier: activeSession.bundleIdentifier
            )
        )
    }
}
