// Mercy on the Touch Bar.
//
// Collapsed: a button with Mercy's pixel black hole in the Control Strip (where
//            Siri's was), claimed back whenever something else takes the slot.
// Expanded:  a full-width strip (like the volume slider takeover) with the
//            animated orb, your words while you talk, and her answer.
//
// Protocol with Mercy (main/touchbar.js):
//   stdout  "ready"                        — the button is in the Control Strip
//           "strip ok" | "strip unavailable" — whether the full-width strip works here
//           "tap"                          — the face was tapped (talk / interrupt)
//           "close"                        — the strip was closed with its ✕
//   stdin   "state <idle|listening|thinking|speaking|waiting|followup>"
//           "expand" | "collapse"
//           "you <text>"                   — what you're saying (live)
//           "mercy <text>"                  — her answer so far
//           "level <0..1>"                 — her voice level (mouth)
//   stdin closes                           — Mercy quit: exit, the button disappears
//
// Control Strip buttons and the takeover strip are private API
// (DFRFoundation, NSTouchBarItem.addSystemTrayItem,
// NSTouchBar.presentSystemModalTouchBar) — looked up at runtime, so a macOS
// that drops them just loses the feature instead of crashing.
import AppKit

let trayID = NSTouchBarItem.Identifier("app.mercy.controlstrip")
let faceID = NSTouchBarItem.Identifier("app.mercy.strip.face")
let textID = NSTouchBarItem.Identifier("app.mercy.strip.text")

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

func hex(_ v: Int) -> NSColor {
  NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// Mercy's pixel black hole — same rules as renderer/shared/pixel-orb.js.
let C = (
  core: hex(0x08031c), star1: hex(0x2a1a8a), star2: hex(0x4d2da6), star3: hex(0x7a3fc8),
  rim: hex(0xa64bf0), cyan: hex(0x55e3f2), spark: hex(0xffd3ef), magenta: hex(0xe041e6), dust: hex(0x3b1f4d)
)
let frameSeconds: [String: Double] = ["idle": 0.22, "listening": 0.11, "thinking": 0.09, "speaking": 0.10, "waiting": 0.30, "followup": 0.16]
let dirs: [(Double, Double)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]
let labelLight = hex(0xffb08a) // text color while listening / waiting (Mercy orange, light)

/// One frame of the orb as [(x, y, color)] on a grid×grid pixel grid.
func orbCells(phase: Int, state: String, level: Double, grid: Int = 24, scale: Double = 1) -> [(Int, Int, NSColor)] {
  var cells: [Int: (Int, Int, NSColor)] = [:]
  func put(_ x: Double, _ y: Double, _ color: NSColor) {
    let xi = Int(x.rounded()), yi = Int(y.rounded())
    if xi >= 0, yi >= 0, xi < grid, yi < grid { cells[yi * grid + xi] = (xi, yi, color) }
  }
  let rand = { Double.random(in: 0..<1) }
  let c = Double(grid - 1) / 2

  var size = [0, 1, 2, 1][phase % 4]
  if state == "speaking" { size = level > 0.55 ? 2 : level > 0.2 ? 1 : 0 }
  if state == "listening" { size = max(size, 1) }
  let outer = [8.0, 8.5, 9.6][size] * scale
  let rimW = [1.0, 1.0, 2.0][size]
  let cyanFull = size > 0 || state == "listening"

  for y in 0..<grid {
    for x in 0..<grid {
      let dx = Double(x) - c, dy = Double(y) - c
      let d = (dx * dx + dy * dy).squareRoot()
      if d >= outer { continue }
      if d >= outer - rimW {
        let glint = !cyanFull && (abs(dx) < 1.2 || abs(dy) < 1.2 || abs(abs(dx) - abs(dy)) < 1)
        put(Double(x), Double(y), glint ? C.cyan : C.rim)
      } else if cyanFull, d >= outer - rimW - 1 {
        put(Double(x), Double(y), C.cyan)
      } else {
        put(Double(x), Double(y), C.core)
      }
    }
  }

  let inner = outer - rimW - (cyanFull ? 1 : 0) - 1.5
  for _ in 0..<(4 + Int(rand() * 3)) {
    let a = rand() * .pi * 2, r = rand().squareRoot() * inner
    let color = [C.star1, C.star2, C.star3][Int(rand() * 3)]
    let x = c + cos(a) * r, y = c + sin(a) * r
    put(x, y, color)
    if rand() < 0.3 { put(x + 1, y + 1, color) }
  }

  let edge = outer + 0.5, maxR = Double(grid) / 2 - 0.5
  func streak() {
    let (ux, uy) = dirs[Int(rand() * 4)]
    let start = edge + 1 + rand() * 2
    for i in 0..<(2 + Int(rand() * 3)) where start + Double(i) <= maxR {
      put(c + ux * (start + Double(i)), c + uy * (start + Double(i)), C.spark)
    }
  }
  func burst() {
    for (ux, uy) in dirs[4...] {
      for i in 0..<3 {
        let r = edge * 0.72 + 1 + Double(i)
        if r <= maxR { put(c + ux * r, c + uy * r, C.spark) }
      }
    }
  }
  func mote() {
    let a = rand() * .pi * 2, r = edge + 1 + rand() * max(0, maxR - edge - 1)
    put(c + cos(a) * r, c + sin(a) * r, C.magenta)
  }
  func dust(_ close: Bool) {
    let a = rand() * .pi * 2, r = close ? edge + rand() * 1.5 : edge + 1 + rand() * 3
    let x = c + cos(a) * r, y = c + sin(a) * r
    put(x, y, C.dust)
    put(x + 1, y, C.dust)
    if rand() < 0.5 { put(x, y + 1, C.dust) }
  }

  switch state {
  case "listening":
    for _ in 0..<3 { dust(true) }
    if rand() < 0.5 { mote() }
  case "thinking":
    streak(); mote()
    if rand() < 0.35 { burst() }
  case "speaking":
    if level > 0.5 { burst() }
    if level > 0.15 || rand() < 0.4 { streak() }
    mote()
  case "waiting":
    if rand() < 0.3 { mote() }
  default:
    if rand() < 0.35 { streak() }
    if rand() < 0.6 { mote() }
    if rand() < 0.5 { dust(false) }
  }
  return Array(cells.values)
}

/// Mercy's animated pixel orb (Control Strip button and strip).
final class OrbView: NSView {
  var state = "idle" { didSet { if state != oldValue { schedule() } } }
  var level: Double = 0
  var onTap: (() -> Void)?
  private var phase = 0
  private var cells: [(Int, Int, NSColor)] = []
  private var timer: Timer?

  override init(frame: NSRect) {
    super.init(frame: frame)
    allowedTouchTypes = [.direct]
    schedule()
  }
  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 30) }
  override var isFlipped: Bool { true } // grid rows go down, like the JS version

  override func touchesBegan(with event: NSEvent) { onTap?() }

  private func schedule() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: frameSeconds[state] ?? 0.2, repeats: true) { [weak self] _ in self?.step() }
    step()
  }

  private func step() {
    phase = (phase + 1) % 4
    // The Touch Bar is 30 pt tall at 2× → a 20-cell grid makes every cell exactly
    // 3 hardware pixels (crisp); the orb is scaled to that grid.
    cells = orbCells(phase: phase, state: state, level: level, grid: OrbView.grid, scale: 0.95)
    needsDisplay = true
  }

  static let grid = 20

  override func draw(_ dirty: NSRect) {
    let grid = Double(OrbView.grid)
    let px = bounds.height / grid // 1.5 pt = 3 hardware pixels
    let ox = ((bounds.width - px * grid) / 2).rounded()
    for (x, y, color) in cells {
      color.setFill()
      NSRect(x: ox + Double(x) * px, y: Double(y) * px, width: px, height: px).fill()
    }
  }
}

final class Helper: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
  let trayFace = OrbView(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
  let stripFace = OrbView(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
  let tray = NSCustomTouchBarItem(identifier: trayID)
  let strip = NSTouchBar()
  let label = NSTextField(labelWithString: "")
  var expanded = false
  var stripWorks = false
  var state = "idle"
  var you = ""
  var answer = ""
  var visibility: NSKeyValueObservation?

  func applicationDidFinishLaunching(_ notification: Notification) {
    trayFace.onTap = { emit("tap") }
    stripFace.onTap = { emit("tap") }
    tray.view = trayFace

    let add = NSSelectorFromString("addSystemTrayItem:")
    guard (NSTouchBarItem.self as AnyObject).responds(to: add) else {
      FileHandle.standardError.write("addSystemTrayItem unavailable on this macOS\n".data(using: .utf8)!)
      exit(2)
    }
    _ = (NSTouchBarItem.self as AnyObject).perform(add, with: tray)
    dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)?(trayID.rawValue as CFString, true)
    dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: ShowsCloseBox.self)?(true)
    // The Control Strip has one slot for app buttons: when something else takes
    // it (Now Playing as soon as music or a video plays), Mercy's button is gone
    // for good. Claim it back every few seconds, and right after wake / unlock.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pin() }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.pin() }
    DistributedNotificationCenter.default().addObserver(
      forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.pin() }

    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.textColor = .white
    label.lineBreakMode = .byTruncatingHead // keep the newest words visible
    label.cell?.truncatesLastVisibleLine = true
    strip.delegate = self
    strip.defaultItemIdentifiers = [faceID, textID]
    stripWorks = (NSTouchBar.self as AnyObject).responds(to: NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
    // The ✕ the system puts on the strip: tell Mercy it was closed.
    visibility = strip.observe(\.isVisible, options: [.new]) { [weak self] bar, _ in
      guard let self, self.expanded, !bar.isVisible else { return }
      self.expanded = false
      emit("close")
    }
    emit("ready")
    emit(stripWorks ? "strip ok" : "strip unavailable")
    render()
    listen()

    // Test hook: --tap-after <seconds> presses the button once by itself.
    if let i = CommandLine.arguments.firstIndex(of: "--tap-after"), i + 1 < CommandLine.arguments.count,
      let sec = Double(CommandLine.arguments[i + 1])
    {
      DispatchQueue.main.asyncAfter(deadline: .now() + sec) { emit("tap") }
    }
  }

  func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    let item = NSCustomTouchBarItem(identifier: id)
    if id == faceID {
      item.view = stripFace
    } else {
      // A fixed-size box (a bare text field collapses to nothing); 520 pt fits
      // next to the close button and the Control Strip.
      let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 30))
      box.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 520), box.heightAnchor.constraint(equalToConstant: 30)])
      label.frame = NSRect(x: 0, y: 4, width: 520, height: 22)
      label.autoresizingMask = [.width]
      box.addSubview(label)
      item.view = box
    }
    return item
  }

  func pin() {
    guard !expanded else { return } // the strip owns the Touch Bar right now
    dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)?(trayID.rawValue as CFString, true)
  }

  func expand() {
    guard stripWorks, !expanded else { return }
    expanded = true
    _ = (NSTouchBar.self as AnyObject).perform(
      NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"), with: strip, with: trayID.rawValue)
  }

  func collapse() {
    guard expanded else { return }
    expanded = false
    let dismiss = NSSelectorFromString("dismissSystemModalTouchBar:")
    if (NSTouchBar.self as AnyObject).responds(to: dismiss) {
      _ = (NSTouchBar.self as AnyObject).perform(dismiss, with: strip)
    }
  }

  /// What the strip says, by state.
  func render() {
    trayFace.state = state
    stripFace.state = state
    switch state {
    case "listening":
      label.textColor = labelLight
      label.stringValue = you.isEmpty ? "Listening…" : "“\(you)”"
    case "thinking":
      label.textColor = NSColor.white.withAlphaComponent(0.7)
      label.stringValue = answer.isEmpty ? (you.isEmpty ? "Thinking…" : "“\(you)”  ·  thinking…") : answer
    case "waiting":
      label.textColor = labelLight
      label.stringValue = "Needs your OK — say yes or no"
    case "followup":
      label.textColor = NSColor.white.withAlphaComponent(0.7)
      label.stringValue = answer.isEmpty ? "Still listening…" : "\(answer)   · still listening…"
    default:
      label.textColor = .white
      label.stringValue = answer
    }
  }

  func handle(_ line: String) {
    let space = line.firstIndex(of: " ")
    let cmd = space.map { String(line[..<$0]) } ?? line
    let arg = space.map { String(line[line.index(after: $0)...]) } ?? ""
    switch cmd {
    case "state":
      if arg == "listening", state != "listening" { you = ""; answer = "" }
      state = arg
    case "expand": expand()
    case "collapse": collapse()
    case "you": you = arg
    case "mercy": answer = arg
    case "level":
      let v = Double(arg) ?? 0
      trayFace.level = v
      stripFace.level = v
      return
    default: return
    }
    render()
  }

  func listen() {
    Thread.detachNewThread {
      while let line = readLine() {
        DispatchQueue.main.async { self.handle(line) }
      }
      DispatchQueue.main.async {
        self.collapse()
        dfrSymbol("DFRElementSetControlStripPresenceForIdentifier", as: SetPresence.self)?(trayID.rawValue as CFString, false)
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
