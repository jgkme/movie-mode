import AppKit
import ApplicationServices
import CoreGraphics

enum FullscreenMatchSelector {
    struct Candidate: Equatable {
        let displayID: String
        let bundleIdentifier: String
        let score: Int
    }

    struct Match {
        let displayID: String
        let bundleIdentifier: String
        let score: Int

        var candidate: Candidate {
            Candidate(displayID: displayID, bundleIdentifier: bundleIdentifier, score: score)
        }
    }

    static let nativePlayerBundleIdentifiers: Set<String> = [
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
    ]

    static let browserMinCoverage: CGFloat = 0.98
    static let nativePlayerMinCoverage: CGFloat = 0.90

    static func selectBest(
        cgWindowList: [[String: Any]]?,
        screens: [NSScreen],
        allowlist: Set<String>,
        frontmostBundleIdentifier: String?,
        includeAccessibility: Bool
    ) -> Match? {
        var candidates: [Candidate] = []

        if let cgWindowList {
            candidates.append(
                contentsOf: candidatesFromWindowList(
                    cgWindowList,
                    screens: screens,
                    allowlist: allowlist,
                    frontmostBundleIdentifier: frontmostBundleIdentifier
                )
            )
        }

        if includeAccessibility, AXIsProcessTrusted() {
            candidates.append(
                contentsOf: candidatesFromAccessibility(
                    screens: screens,
                    allowlist: allowlist,
                    frontmostBundleIdentifier: frontmostBundleIdentifier
                )
            )
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        return Match(displayID: best.displayID, bundleIdentifier: best.bundleIdentifier, score: best.score)
    }

    private static func candidatesFromWindowList(
        _ windowList: [[String: Any]],
        screens: [NSScreen],
        allowlist: Set<String>,
        frontmostBundleIdentifier: String?
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        for windowInfo in windowList {
            guard
                let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int,
                let app = NSRunningApplication(processIdentifier: pid_t(ownerPID)),
                let bundleID = app.bundleIdentifier,
                allowlist.contains(bundleID)
            else {
                continue
            }

            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            let windowBounds = ScreenIdentity.appKitFrame(
                fromTopLeftGlobalFrame: CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
            )

            guard let screen = matchingScreen(
                for: windowBounds,
                among: screens,
                bundleID: bundleID,
                frontmostBundleIdentifier: frontmostBundleIdentifier
            ) else {
                continue
            }

            let coverage = coverageRatio(windowBounds: windowBounds, screenFrame: screen.frame)
            guard layerIsEligible(layer, bundleID: bundleID, coverage: coverage) else {
                continue
            }

            let score = score(
                bundleID: bundleID,
                frontmostBundleIdentifier: frontmostBundleIdentifier,
                coverage: coverage,
                layer: layer,
                accessibilityConfirmed: false
            )

            candidates.append(
                Candidate(displayID: screen.movieModeScreenID, bundleIdentifier: bundleID, score: score)
            )
        }

        return candidates
    }

    private static func candidatesFromAccessibility(
        screens: [NSScreen],
        allowlist: Set<String>,
        frontmostBundleIdentifier: String?
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, allowlist.contains(bundleID) else {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement]
            else {
                continue
            }

            for window in windows where windowIsFullscreen(window) {
                guard let axFrame = windowFrame(window) else {
                    continue
                }

                let appKitFrame = ScreenIdentity.appKitFrame(fromAccessibilityFrame: axFrame)
                guard let screen = matchingScreenForAccessibility(
                    windowBounds: appKitFrame,
                    among: screens,
                    bundleID: bundleID
                ) else {
                    continue
                }

                let coverage = coverageRatio(windowBounds: appKitFrame, screenFrame: screen.frame)
                let score = score(
                    bundleID: bundleID,
                    frontmostBundleIdentifier: frontmostBundleIdentifier,
                    coverage: coverage,
                    layer: 0,
                    accessibilityConfirmed: true
                )

                candidates.append(
                    Candidate(displayID: screen.movieModeScreenID, bundleIdentifier: bundleID, score: score)
                )
            }
        }

        return candidates
    }

    private static func windowIsFullscreen(_ window: AXUIElement) -> Bool {
        for attribute in ["AXFullScreen", "AXFullscreen"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
                  let isFullscreen = value as? Bool
            else {
                continue
            }

            if isFullscreen {
                return true
            }
        }

        return false
    }

    private static func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue,
              let sizeRef = sizeValue
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func layerIsEligible(
        _ layer: Int,
        bundleID: String,
        coverage: CGFloat
    ) -> Bool {
        guard layer >= 0 && layer <= 25 else {
            return false
        }

        if nativePlayerBundleIdentifiers.contains(bundleID) {
            return coverage >= nativePlayerMinCoverage
        }

        if browserBundleIdentifiers.contains(bundleID) {
            // Maximized browser windows sit at layer 0 (~95% coverage); true fullscreen uses elevated layers.
            if layer > 0 {
                return coverage >= 0.95
            }
            return coverage >= browserMinCoverage
        }

        return layer == 0 && coverage >= browserMinCoverage
    }

    private static func matchingScreen(
        for windowBounds: CGRect,
        among screens: [NSScreen],
        bundleID: String,
        frontmostBundleIdentifier: String?
    ) -> NSScreen? {
        let minCoverage: CGFloat
        if nativePlayerBundleIdentifiers.contains(bundleID) {
            minCoverage = nativePlayerMinCoverage
        } else if browserBundleIdentifiers.contains(bundleID) {
            minCoverage = browserMinCoverage
        } else {
            minCoverage = browserMinCoverage
        }

        var bestMatch: NSScreen?
        var bestCoverage: CGFloat = 0

        for screen in screens {
            let coverage = coverageRatio(windowBounds: windowBounds, screenFrame: screen.frame)
            guard coverage >= minCoverage else {
                continue
            }

            if coverage > bestCoverage {
                bestCoverage = coverage
                bestMatch = screen
            }
        }

        return bestMatch
    }

    private static func matchingScreenForAccessibility(
        windowBounds: CGRect,
        among screens: [NSScreen],
        bundleID: String
    ) -> NSScreen? {
        if let screen = ScreenIdentity.screen(containing: windowBounds, among: screens),
           ScreenIdentity.isWindowApproximatelyFullscreen(
               windowBounds: windowBounds,
               on: screen,
               tolerance: browserBundleIdentifiers.contains(bundleID) ? 24 : 8
           ) {
            return screen
        }

        return matchingScreen(
            for: windowBounds,
            among: screens,
            bundleID: bundleID,
            frontmostBundleIdentifier: nil
        )
    }

    private static func coverageRatio(windowBounds: CGRect, screenFrame: CGRect) -> CGFloat {
        let intersection = screenFrame.intersection(windowBounds)
        guard !intersection.isNull else {
            return 0
        }

        let screenArea = screenFrame.width * screenFrame.height
        guard screenArea > 0 else {
            return 0
        }

        return (intersection.width * intersection.height) / screenArea
    }

    private static func score(
        bundleID: String,
        frontmostBundleIdentifier: String?,
        coverage: CGFloat,
        layer: Int,
        accessibilityConfirmed: Bool
    ) -> Int {
        var total = Int(coverage * 100)

        if bundleID == frontmostBundleIdentifier {
            total += 1_000
        }

        if nativePlayerBundleIdentifiers.contains(bundleID) {
            total += 500
        } else if browserBundleIdentifiers.contains(bundleID) {
            total += 100
        }

        if accessibilityConfirmed {
            total += 2_000
        }

        if layer == 0 {
            total += 10
        }

        return total
    }
}
