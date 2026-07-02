import Foundation
import Testing
@testable import OrchestraCore

@Suite("RemoteCommands — ssh multiplexing argv")
struct RemoteCommandsTests {
    @Test("master args set up -M/-S/-N/-L and batch-mode, with identity when given")
    func master() {
        let a = RemoteCommands.sshMasterArgs(
            target: "me@box", identityFile: "~/.ssh/id", controlPath: "/tmp/o/c",
            localSocketPath: "/tmp/o/s", remoteSocketPath: "/home/me/.local/share/orchestra/orchestrad.sock")
        #expect(a.first == "ssh")
        #expect(a.contains("-M"))
        #expect(a.contains("-N"))
        #expect(!a.contains("-f"))                                     // app-owned, not detached
        #expect(a.contains("-S")); #expect(a.contains("/tmp/o/c"))
        #expect(a.contains("-L"))
        #expect(a.contains("/tmp/o/s:/home/me/.local/share/orchestra/orchestrad.sock"))
        #expect(a.contains("-i")); #expect(a.contains("~/.ssh/id"))
        #expect(a.last == "me@box")                                    // target is the final positional
        #expect(a.contains("BatchMode=yes"))                           // key-only auth
        #expect(a.contains("ExitOnForwardFailure=yes"))                // fail fast if -L can't bind
    }

    @Test("no -i when identity omitted")
    func noIdentity() {
        let a = RemoteCommands.sshMasterArgs(target: "me@box", identityFile: nil, controlPath: "/tmp/c",
                                             localSocketPath: "/tmp/s", remoteSocketPath: "/r.sock")
        #expect(!a.contains("-i"))
    }

    @Test("exit args target the same control socket")
    func exit() {
        let a = RemoteCommands.sshExitArgs(target: "me@box", controlPath: "/tmp/c")
        #expect(a.contains("-S")); #expect(a.contains("/tmp/c"))
        #expect(a.contains("-O")); #expect(a.contains("exit"))
        #expect(a.last == "me@box")
    }

    @Test("remote tmux attach rides the control socket with a tty and runs the script")
    func remoteAttach() {
        let (exe, args) = RemoteCommands.remoteTmuxAttach(
            target: "me@box", controlPath: "/tmp/c", script: "tmux -L orchestra attach")
        #expect(exe.hasSuffix("ssh"))
        #expect(args.contains("-S")); #expect(args.contains("/tmp/c"))
        #expect(args.contains("-tt"))                                  // force a pty for tmux
        #expect(args.contains("me@box"))
        #expect(args.contains { $0.contains("tmux -L orchestra attach") })
    }

    @Test("socketPathFits rejects paths at/over the sun_path cap")
    func fits() {
        #expect(RemoteCommands.socketPathFits("/tmp/orch-abcd1234/s"))
        #expect(!RemoteCommands.socketPathFits(String(repeating: "x", count: 120)))
    }
}
