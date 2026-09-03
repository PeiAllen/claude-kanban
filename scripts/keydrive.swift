// keydrive — background UI driver for Orchestra keyboard tests.
//
//   swift keydrive.swift windowid <pid>            → prints that pid's largest on-screen window id
//   swift keydrive.swift keys <pid> <tok> <tok>…   → posts key events to that pid WITHOUT activating it
//
// Key tokens: a single char (a,j,/,: …) or a name (cr, esc, space, left, right, up, down). Prefix
// with modifiers + "-":
//   C- control, M- command, S- shift. e.g.  C-l  M-w  S-h  S-;  (":" is S-;).
// Events are delivered via CGEvent.postToPid, so the target need not be frontmost (non-intrusive).
import AppKit
import CoreGraphics

// US-ANSI virtual keycodes for the keys these tests use.
let vk: [Character: CGKeyCode] = [
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,
    "r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,
    "/":44,";":41,".":47,",":43,"1":18,"2":19,"3":20,
]
let named: [String: CGKeyCode] = [
    "cr":36,"return":36,"esc":53,"escape":53,"space":49,"tab":48,
    "left":123,"right":124,"down":125,"up":126,
]

func keycode(_ base: String) -> CGKeyCode? {
    if let n = named[base.lowercased()] { return n }
    if base.count == 1, let c = base.lowercased().first, let code = vk[c] { return code }
    return nil
}

func post(pid: pid_t, token: String) {
    var flags: CGEventFlags = []
    var body = token
    while let dash = body.firstIndex(of: "-"), body.distance(from: body.startIndex, to: dash) == 1 {
        switch body.first {
        case "C": flags.insert(.maskControl)
        case "M": flags.insert(.maskCommand)
        case "S": flags.insert(.maskShift)
        default: break
        }
        body = String(body[body.index(after: dash)...])
    }
    guard let code = keycode(body) else { FileHandle.standardError.write("skip token \(token)\n".data(using: .utf8)!); return }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.postToPid(pid)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: keydrive windowid <owner> | keys <pid> <tok>…"); exit(2) }

switch args[1] {
case "windowid":
    // Filter by owner PID so we target OUR isolated instance, never the user's live app (same name).
    guard args.count > 2, let pid = Int(args[2]) else { print("windowid needs a pid"); exit(2) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
        .sorted { (a, b) in
            let ab = (a[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            let bb = (b[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            return (ab["Width"] ?? 0) * (ab["Height"] ?? 0) > (bb["Width"] ?? 0) * (bb["Height"] ?? 0)
        }
    if let id = matches.first?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
case "keys":
    guard args.count >= 3, let pid = pid_t(args[2]) else { exit(2) }
    for token in args.dropFirst(3) {
        post(pid: pid, token: token)
        usleep(120_000)   // 120ms between keys so the UI settles for the screenshot
    }
default:
    exit(2)
}
