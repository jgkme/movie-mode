import FocusMonitorCore
import Foundation

enum MovieModeBundleAllowlist {
    static let defaultBundleIdentifiers: Set<String> =
        FullscreenMatchSelector.nativePlayerBundleIdentifiers
            .union(FullscreenMatchSelector.browserBundleIdentifiers)

    static func resolvedIdentifiers(from settings: MovieModeSettings) -> Set<String> {
        if let custom = settings.enabledBundleIdentifiers, !custom.isEmpty {
            return Set(custom)
        }

        return defaultBundleIdentifiers
    }
}
