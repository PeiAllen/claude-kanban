import Foundation
import OrchestraKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The live host-resource probe: "can this machine start a terminal AT ALL right now, and if not, what
/// ran out?" Sits behind the same seam for every agent — the resources it measures are consumed by tmux,
/// not by Claude or Codex, so a drained PTY pool kills both identically.
///
/// Two independent signals, used for two different jobs:
///  • `probe()` DECIDES (is the pool actually empty?) — a real `posix_openpt`, judged on errno alone.
///  • `ptyPool()` COUNTS (how many, out of how many?) — for the numbers in the message only.
///
/// The split is deliberate and measured: the `/dev/ttys*` census can overshoot `kern.tty.ptmx_max` by a
/// dozen or so entries (devfs nodes outlive their pty briefly), so "free <= 0" is a good *number* but a
/// bad *verdict*. The syscall is the verdict.
///
/// EVERYTHING HERE FAILS OPEN. A probe that cannot run must never be read as "exhausted" — that would
/// refuse every spawn on the board. This is not hypothetical: inside a seatbelt sandbox, opening
/// `/dev/ptmx` is denied with EPERM while the pool is in fact ~90% free, so only the specific
/// exhaustion errnos below count as a verdict and every other outcome means "no opinion".
///
/// No subprocess is used, by design: when the host is out of processes or fds, shelling out to `sysctl`
/// or `lsof` is exactly the thing that cannot work. libc only.
public enum HostResources {

    /// The definitive question: try to actually obtain a pseudo-terminal. Returns the exhausted resource,
    /// or `nil` for "no opinion" (got one, or the probe was blocked/unavailable — see FAILS OPEN above).
    /// The pty is released immediately, so the probe leaves the pool exactly as it found it.
    public static func probe() -> HostResource? {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        if fd >= 0 { close(fd); return nil }   // got one ⇒ the host can still start a terminal
        switch errno {
        case ENXIO:          return .pty              // measured: macOS returns ENXIO on a drained ptmx pool
        case EMFILE, ENFILE: return .fileDescriptor
        case EAGAIN:         return .process
        default:             return nil               // EPERM (sandbox), ENOENT, … ⇒ no opinion, never block
        }
    }

    /// A census of the PTY pool for the *message*: `(max: 511, free: 3)`. Never a verdict (see above).
    /// `free` is clamped at 0 — the census can overshoot the cap, and "-16 free" is not a thing to show a
    /// human. `nil` when the host doesn't answer (unknown platform, unreadable `/dev`), in which case the
    /// message simply names the resource without numbers.
    public static func ptyPool() -> (max: Int, free: Int)? {
        guard let max = ptmxMax(), let used = allocatedPtys() else { return nil }
        return (max: max, free: Swift.max(0, max - used))
    }

    /// Attach the live numbers to a resource we've already identified.
    public static func report(_ resource: HostResource) -> HostResourceReport {
        guard resource == .pty, let pool = ptyPool() else { return HostResourceReport(resource: resource) }
        return HostResourceReport(resource: resource, max: pool.max, free: pool.free)
    }

    /// THE classifier used across the daemon's death paths. Evidence first (an explicit "fork failed:
    /// Device not configured" from tmux is proof), then the live probe — because the evidence is often
    /// *silent* about the real cause. That fallback is the whole point: in the incident this fixes, a
    /// PTY-starved spawn died with `ENOENT: Bun could not find a file`, which names no resource at all and
    /// matches no signature. Only asking the host "can you give me a terminal?" reveals what really failed.
    ///
    /// `nil` ⇒ not a host-resource failure; the caller keeps its existing classification.
    public static func diagnose(evidence: String?) -> HostResourceReport? {
        if let named = HostResource.classify(evidence) { return report(named) }
        if let probed = probe() { return report(probed) }
        return nil
    }

    // MARK: - platform census

    /// `kern.tty.ptmx_max` (511 on stock macOS) via `sysctlbyname` — no subprocess.
    private static func ptmxMax() -> Int? {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.tty.ptmx_max", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
        #else
        guard let s = try? String(contentsOfFile: "/proc/sys/kernel/pty/max", encoding: .utf8),
              let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { return nil }
        return n
        #endif
        }

    /// How many pseudo-terminals are currently allocated. Measured to track allocation exactly and in real
    /// time on macOS: devfs materialises `/dev/ttysNNN` when a pty is granted and drops it when released.
    private static func allocatedPtys() -> Int? {
        #if canImport(Darwin)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return nil }
        return entries.filter { $0.hasPrefix("ttys") }.count
        #else
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/pts") else { return nil }
        return entries.filter { Int($0) != nil }.count
        #endif
    }
}
