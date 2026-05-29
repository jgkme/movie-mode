public struct FullscreenPlaybackEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case entered
        case exited
    }

    public var kind: Kind
    public var displayID: String
    public var bundleIdentifier: String

    public init(kind: Kind, displayID: String, bundleIdentifier: String) {
        self.kind = kind
        self.displayID = displayID
        self.bundleIdentifier = bundleIdentifier
    }
}

@MainActor
public protocol FullscreenPlaybackDetecting: AnyObject {
    var onEvent: ((FullscreenPlaybackEvent) -> Void)? { get set }
    func start()
    func stop()
    /// Clears internal fullscreen tracking without emitting an exit event.
    func resetTracking()
    /// Runs an immediate scan (for wake/display changes).
    func scanNow()
}
