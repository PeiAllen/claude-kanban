import Foundation
import OrchestraCore

// orchestra — the CLI client. A thin ControlClient over the same CommandRegistry, plus the hidden
// `_report` status-channel helper and the interactive `shell` / `daemon` specials.

// A broken pipe to the agent must never take THIS process down. Claude captures our stdout for the
// statusLine + hooks; that pipe dies the instant a self-close (`archive`) kills the card's session.
// Ignoring SIGPIPE turns a write to the dead pipe into an EPIPE return instead of raising signal 13
// (the `_report` helper's stdio then swallows the EPIPE rather than raising an NSException). Set
// before any I/O; applies to every subcommand (also protects e.g. `orchestra list | head`).
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
let socketPath = ProcessInfo.processInfo.environment["ORCHESTRA_SOCK"] ?? Config.socketPath

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("orchestra: \(msg)\n".utf8))
    exit(code)
}

func printJSON(_ value: JSONValue) {
    if let data = try? OrchestraJSON.pretty.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

guard let verb = args.first else {
    print(CLIHelp.text); exit(0)
}
let rest = Array(args.dropFirst())

// --- specials handled before touching the daemon ---
switch verb {
case "-h", "--help", "help": print(CLIHelp.text); exit(0)
case "version", "--version": print("orchestra \(OrchestraVersion.current)"); exit(0)
case "_report": await ReportHelper.run(rest); exit(0)
case "daemon": DaemonCLI.run(rest); exit(0)
default: break
}

// --- everything else talks to the daemon ---
await CLIRunner.run(verb: verb, args: rest, socketPath: socketPath)
