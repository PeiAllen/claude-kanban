import Foundation

/// A phase in a terminal byte channel's lifecycle, surfaced to the UI so the terminal can show a
/// connecting / failed / closed banner instead of a dead black rectangle.
enum TerminalChannelEvent: Equatable {
    case connecting
    case connected
    case failed(String)
    case closed
}

/// The transport seam beneath the iOS terminal: a bidirectional byte channel with a PTY size.
///
/// `SSHPTYChannel` is the real implementation — a SwiftTerm view ⇄ an SSH exec channel that runs the
/// tmux attach recipe on the Mac (no daemon byte-proxy; the design's "iOS terminals over SSH PTY").
/// The seam is why T2 (phone-owned shell) and T4 (agent takeover) can reuse the *exact same*
/// `IOSTerminalView` with a differently-parameterised channel, and why previews/diagnostics can use a
/// `LoopbackChannel` with no network.
///
/// `@MainActor`: a terminal channel drives a `UIView` (SwiftTerm) and its callbacks feed that view, so
/// the whole seam is main-actor. Implementations that do off-main I/O (SSH) hop back to the main actor
/// before invoking the callbacks.
@MainActor
protocol TerminalByteChannel: AnyObject {
    /// Bytes arriving FROM the remote PTY → feed into the terminal emulator.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Lifecycle transitions → drive the status banner.
    var onEvent: ((TerminalChannelEvent) -> Void)? { get set }
    /// Open the channel at an initial PTY size. Idempotent: a second call while already open/opening is
    /// a no-op (this is what makes reconnect reuse one channel rather than stack clients).
    func start(cols: Int, rows: Int)
    /// Bytes typed by the user → write to the remote PTY.
    func send(_ bytes: [UInt8])
    /// The terminal view resized → tell the remote PTY (SSH window-change → SIGWINCH).
    func resize(cols: Int, rows: Int)
    /// Tear down (view disappeared / app backgrounded / target changed).
    func close()
}

/// A zero-network channel that just prints a fixed banner and locally echoes typed bytes. Used when no
/// SSH endpoint is configured (so the terminal explains itself instead of hanging), and as a rendering
/// harness for previews/screenshots that need a live SwiftTerm view without a Mac.
@MainActor
final class LoopbackChannel: TerminalByteChannel {
    var onOutput: (([UInt8]) -> Void)?
    var onEvent: ((TerminalChannelEvent) -> Void)?
    private let banner: String
    private var started = false

    init(banner: String) { self.banner = banner }

    func start(cols: Int, rows: Int) {
        guard !started else { return }
        started = true
        onEvent?(.connected)
        onOutput?(Array(banner.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }
    func send(_ bytes: [UInt8]) {
        // Echo so the view is visibly alive; CR → CRLF so Return advances a line.
        onOutput?(bytes.flatMap { $0 == 0x0d ? [0x0d, 0x0a] : [$0] })
    }
    func resize(cols: Int, rows: Int) {}
    func close() { started = false }
}
