import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }
}

/// One screenshot per agent, taken when you click the ?. Margin's own windows are never included.
enum ScreenCapture {
    /// Claude downsizes anything bigger than this on the long edge anyway.
    private static let maxEdgePixels: CGFloat = 1568

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (only the first time) and adds Margin to the Screen Recording list.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// JPEG of the screen under `point` (or the app's front window). Completion runs on main; nil if off/denied/failed.
    static func capture(_ mode: ScreenContext, at point: NSPoint, pid: pid_t, completion: @escaping (Data?) -> Void) {
        guard mode != .off, hasPermission else { return completion(nil) } // .smart captures like .screen; the chat decides whether to send it
        let displayID = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.displayID
        let windowID = mode == .window ? frontWindowID(of: pid) : nil

        Task.detached(priority: .userInitiated) {
            let data = try? await captureJPEG(displayID: displayID, windowID: windowID)
            DispatchQueue.main.async { completion(data) }
        }
    }

    private static func captureJPEG(displayID: CGDirectDisplayID?, windowID: CGWindowID?) async throws -> Data? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let size: CGSize

        if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        } else if let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let margin = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: margin, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        } else {
            return nil
        }

        // Up to 2x for small windows, but never past Claude's useful resolution.
        let scale = min(2, maxEdgePixels / max(size.width, size.height, 1))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }

    /// Frontmost normal window of the app (the window list is ordered front to back).
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return id
        }
        return nil
    }
}
