import AppKit

enum ScreenIdentity {
    static func screenID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }

        let frame = screen.frame
        return "\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
    }

    static func screen(containing windowBounds: CGRect, among screens: [NSScreen]) -> NSScreen? {
        var bestMatch: NSScreen?
        var bestArea: CGFloat = 0

        for screen in screens {
            let intersection = screen.frame.intersection(windowBounds)
            guard !intersection.isNull else {
                continue
            }

            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestMatch = screen
            }
        }

        return bestMatch
    }

    static func appKitFrame(fromTopLeftGlobalFrame frame: CGRect) -> CGRect {
        // CGWindow and Accessibility use a top-left origin; AppKit screen frames use bottom-left.
        let desktopMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? frame.maxY
        return CGRect(
            x: frame.origin.x,
            y: desktopMaxY - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    static func appKitFrame(fromAccessibilityFrame axFrame: CGRect) -> CGRect {
        appKitFrame(fromTopLeftGlobalFrame: axFrame)
    }

    static func isWindowApproximatelyFullscreen(windowBounds: CGRect, on screen: NSScreen, tolerance: CGFloat = 4) -> Bool {
        let screenFrame = screen.frame
        return abs(windowBounds.origin.x - screenFrame.origin.x) <= tolerance
            && abs(windowBounds.origin.y - screenFrame.origin.y) <= tolerance
            && abs(windowBounds.width - screenFrame.width) <= tolerance
            && abs(windowBounds.height - screenFrame.height) <= tolerance
    }
}

private extension NSScreen {
    var focusMonitorScreenID: String {
        ScreenIdentity.screenID(for: self)
    }
}

extension NSScreen {
    var movieModeScreenID: String {
        ScreenIdentity.screenID(for: self)
    }
}
