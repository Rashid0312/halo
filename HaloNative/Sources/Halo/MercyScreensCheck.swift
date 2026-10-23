import AppKit
import SwiftUI

/// Renders every setup step and Settings page to PNG files for review,
/// offscreen and without saving any setting.
extension NativeChecks {
    @MainActor
    static func renderMercyScreens(to directory: URL, delegate: HaloDelegate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func render<V: View>(_ view: V, size: NSSize, name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure("Could not render \(name).") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("Could not encode \(name).") }
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            print("rendered \(name).png")
        }
        for (index, step) in ["signIn", "name", "microphone", "permissions", "voice", "ready"].enumerated() {
            let view = FirstRunView(auth: delegate.auth, deepSeekKey: delegate.deepSeekKey, macTools: delegate.macTools,
                                    wake: delegate.wake, voice: delegate.voice, setHandsFree: { _ in }, finish: {},
                                    startStep: index)
            try render(view, size: NSSize(width: 560, height: 640), name: "setup-\(index + 1)-\(step)")
        }
        for page in MercySettings.Page.allCases {
            let view = MercySettings(voice: delegate.voice, wake: delegate.wake, setHandsFree: { _ in }, catalog: delegate.catalog,
                                     macTools: delegate.macTools, presentation: delegate.presentation, auth: delegate.auth,
                                     browserBridge: delegate.browserBridge, connectorAccounts: delegate.connectorAccounts,
                                     deepSeekKey: delegate.deepSeekKey, runSetup: {}, startPage: page)
            try render(view, size: NSSize(width: 960, height: 680), name: "settings-\(page.rawValue)")
        }
    }
}
