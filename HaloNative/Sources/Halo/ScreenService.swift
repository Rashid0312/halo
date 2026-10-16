import AppKit
import ScreenCaptureKit
import ApplicationServices
import Observation

@MainActor @Observable
final class ScreenService {
    private(set) var allowed = CGPreflightScreenCaptureAccess()
    func refreshAccess() { allowed = CGPreflightScreenCaptureAccess() }

    struct Capture {
        let data: Data
        let width: Int
        let height: Int
        let scope: String
        let frame: CGRect
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func capture(appID: String?, displayIndex: Int?) async throws -> Capture {
        refreshAccess()
        guard allowed else {
            throw Failure("macOS denied Screen Recording to this Halo process. Check Halo's Screen & System Audio Recording entry; an older enabled build may need to be re-added.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let frame: CGRect
        let scope: String
        if let appID {
            guard appID != Bundle.main.bundleIdentifier,
                  let window = content.windows.first(where: {
                      $0.owningApplication?.bundleIdentifier == appID && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
                  }) else { throw Failure("No on-screen window found for that app. Use running_apps and inspect_ui to identify it first.") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            frame = window.frame
            scope = "Window of \(window.owningApplication?.applicationName ?? appID)"
        } else {
            let screens = NSScreen.screens
            let screen: NSScreen?
            if let displayIndex { screen = screens.indices.contains(displayIndex) ? screens[displayIndex] : nil }
            else { screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first }
            guard let screen, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { throw Failure("That display is not available.") }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            frame = display.frame
            scope = "Display: \(screen.localizedName), excluding Halo"
        }
        return try await capture(filter: filter, frame: frame, scope: scope)
    }

    // Integration check captures only its disposable child window, never the desktop.
    func captureTestWindow(pid: pid_t) async throws -> Capture {
        guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording permission is not available to this process.") }
        for _ in 0..<100 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 }) {
                return try await capture(filter: SCContentFilter(desktopIndependentWindow: window), frame: window.frame, scope: "Disposable test window")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Disposable screen-test window not found.")
    }

    private func capture(filter: SCContentFilter, frame: CGRect, scope: String) async throws -> Capture {
        let config = SCStreamConfiguration()
        let scale = min(2.0, 1600.0 / max(frame.width, frame.height))
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        return try Self.encode(image: image, scope: scope, frame: frame)
    }

    static func encode(image: CGImage, scope: String, frame: CGRect) throws -> Capture {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              data.count <= 4 * 1024 * 1024 else { throw Failure("The captured image could not be encoded within the image limit.") }
        return Capture(data: data, width: image.width, height: image.height, scope: scope, frame: frame)
    }
}
