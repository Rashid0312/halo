// Halo's button in the Touch Bar Control Strip (where Siri's was).
//
// Protocol with Halo (main/touchbar.js):
//   stdout  "tap"                      — the button was pressed
//   stdin   "state <idle|listening|thinking|speaking|waiting>"
//                                      — swap the icon (ring when idle, orange orb when active)
//   stdin closes                       — Halo quit: exit, the button disappears
//
// Apps can only put buttons in the Control Strip through private API
// (DFRFoundation + NSTouchBarItem.addSystemTrayItem), like Pock / MTMR do.
// Everything private is looked up at runtime, so a future macOS that drops it
// makes the button not appear rather than crash.
import AppKit

let itemID = NSTouchBarItem.Identifier("app.halo.controlstrip")

typealias SetPresence = @convention(c) (CFString, Bool) -> Void
typealias ShowsCloseBox = @convention(c) (Bool) -> Void

let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
func dfrSymbol<T>(_ name: String, as type: T.Type) -> T? {
  guard let dfr, let p = dlsym(dfr, name) else { return nil }
  return unsafeBitCast(p, to: type)
}

func emit(_ line: String) {
  FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

/// Ring (idle) or glowing orange orb (active), drawn like the menu bar icon.
func icon(active: Bool) -> NSImage {
  let size = NSSize(width: 22, height: 22)
  return NSImage(size: size, flipped: false) { rect in
    let center = NSPoint(x: rect.midX, y: rect.midY)
    if active {
      let orange = NSColor(red: 1.0, green: 0.28, blue: 0.0, alpha: 1)
      let glow = NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
      orange.withAlphaComponent(0.35).setFill()
      glow.fill()
      let orb = NSBezierPath(ovalIn: NSRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13))
      orange.setFill()
      orb.fill()
    } else {
      let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
      ring.lineWidth = 2
      NSColor.white.setStroke()
      ring.stroke()
    }
    return true
  }
}

final class Helper: NSObject, NSApplicationDelegate {
  let button = NSButton(image: icon(active: false), target: nil, action: nil)
  let item = NSCustomTouchBarItem(identifier: itemID)

  func applicationDidFinishLaunching(_ notification: Notification) {
    button.target = self
    button.action = #selector(tapped)
    button.imagePosition = .imageOnly
    item.view = button

    let add = NSSelectorFromString("addSystemTrayItem:")
    guard (NSTouchBarItem.self as AnyObject).responds(to: add) else {
      FileHandle.standardError.write("addSystemTrayItem unavailable on this macOS\n".data(using: .utf8)!)
      exit(2)
    }
    _ = (NSTouchBarItem.self as AnyObject).perform(add, with: item)
    dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)?(itemID.rawValue as CFString, true)
    dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: ShowsCloseBox.self)?(true)
    emit("ready")

    listen()

    // Test hook: --tap-after <seconds> presses the button once by itself.
    if let i = CommandLine.arguments.firstIndex(of: "--tap-after"), i + 1 < CommandLine.arguments.count,
      let sec = Double(CommandLine.arguments[i + 1])
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + sec) { self.tapped() }
    }
  }

  @objc func tapped() {
    emit("tap")
  }

  func listen() {
    Thread.detachNewThread {
      while let line = readLine() {
        let parts = line.split(separator: " ")
        guard parts.first == "state", parts.count > 1 else { continue }
        let active = parts[1] != "idle"
        DispatchQueue.main.async { self.button.image = icon(active: active) }
      }
      // Halo went away.
      DispatchQueue.main.async {
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)?(itemID.rawValue as CFString, false)
        exit(0)
      }
    }
  }
}

let app = NSApplication.shared
let helper = Helper()
app.delegate = helper
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
app.run()
