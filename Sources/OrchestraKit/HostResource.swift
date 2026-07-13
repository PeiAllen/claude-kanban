import Foundation

/// A HOST resource whose exhaustion makes it impossible to bring an agent session up at all — the
/// machine, not the card, is what failed. Deliberately agent-agnostic: every backend is launched through
/// tmux, so an empty PTY pool kills Claude and Codex identically and the signatures below are tmux's /
/// libc's, never one agent's output format.
public enum HostResource: String, Codable, Sendable, CaseIterable {
    case pty              // pseudo-terminals (`kern.tty.ptmx_max`) — tmux cannot fork a window
    case process          // process table / RLIMIT_NPROC — fork() returns EAGAIN
    case fileDescriptor   // open files (EMFILE/ENFILE)

    /// Plain-language plural name, as it reads mid-sentence in the Recovery panel.
    public var displayName: String {
        switch self {
        case .pty:            return "pseudo-terminals"
        case .process:        return "process slots"
        case .fileDescriptor: return "file descriptors"
        }
    }

    /// What the owner can actually DO about it — the "and now what" half of the message.
    public var remedy: String {
        switch self {
        case .pty:
            return "Close some terminals or restart the app to reclaim them, then Try resume."
        case .process:
            return "Quit some running processes, then Try resume."
        case .fileDescriptor:
            return "Close some open files or restart the app, then Try resume."
        }
    }
}

/// What ran out, plus the pool numbers observed AT DEATH TIME. Sampled by the daemon (which runs on the
/// affected host) rather than by the client, so a remote/iOS board reports the numbers of the machine that
/// actually failed instead of its own. `max`/`free` are best-effort: a host we can't take a census of still
/// names the resource, which is the part that matters.
public struct HostResourceReport: Codable, Equatable, Sendable {
    public var resource: HostResource
    public var max: Int?
    public var free: Int?

    public init(resource: HostResource, max: Int? = nil, free: Int? = nil) {
        self.resource = resource; self.max = max; self.free = free
    }

    /// "The host is out of pseudo-terminals (511 max, 0 free)" — the lead sentence, numbers when we have
    /// them. This lives in the model (not the view) so the Mac app, the iOS app, and the CLI all say the
    /// same sentence about the same death.
    public var headline: String {
        var s = "The host is out of \(resource.displayName)"
        if let max, let free { s += " (\(max) max, \(free) free)" }
        return s + "."
    }
}

extension HostResource {
    /// Recognise a host-exhaustion failure from captured stderr / dying-pane output. Matched
    /// case-insensitively on substrings, deliberately defensively: these strings come from tmux and libc
    /// (`strerror`), so they are stable across agents, but the surrounding text is not.
    ///
    /// Returns `nil` for anything unrecognised — the caller then keeps its existing classification, so a
    /// non-resource failure is never relabelled by this.
    public static func classify(_ text: String?) -> HostResource? {
        guard let low = text?.lowercased(), !low.isEmpty else { return nil }
        // PTY first: tmux's "fork failed: Device not configured" (ENXIO) is the signature of an empty
        // ptmx pool, and it also contains the word "fork" — so it must not be read as a process failure.
        let ptySignatures = [
            "device not configured",     // ENXIO — what macOS returns from openpt with a drained pool
            "out of pty devices",
            "openpty failed",
            "can't find a free pty",
            "no ptys available",
        ]
        let fdSignatures = ["too many open files", "emfile", "enfile"]
        let procSignatures = ["resource temporarily unavailable", "eagain", "cannot fork", "fork: retry"]

        if ptySignatures.contains(where: low.contains) { return .pty }
        if fdSignatures.contains(where: low.contains) { return .fileDescriptor }
        if procSignatures.contains(where: low.contains) { return .process }
        return nil
    }
}
