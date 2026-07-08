import Foundation

#if DEBUG
/// Sample filesystem locations used ONLY by the `ORCH_SHOW` / `ORCH_SNAPSHOT_*` headless-screenshot
/// demo & mock data (all `#if DEBUG`, compiled out of Release). Real local paths are kept OUT of the
/// public repo: the defaults below are generic, and a developer can override them by creating
/// `App/DemoConfig.local.json` (gitignored) next to this file — see `App/DemoConfig.local.json.example`:
///
///     { "repoRoot": "/Users/you/code/orchestra", "notesRoot": "/Users/you/notes" }
///
/// The override is read from the source-relative sibling at runtime — DEBUG dev builds only (the app is
/// unsandboxed, and `#filePath` resolves to the build machine's checkout). A clean clone with no local
/// file just renders the generic defaults.
enum DemoConfig {
    /// Root of the repo the demo/mock cards pretend to live in.
    static var repoRoot: String { local["repoRoot"] ?? "~/code/orchestra" }
    /// Root of the notes dir for borrowed/freeform demo cards.
    static var notesRoot: String { local["notesRoot"] ?? "~/notes" }

    private static let local: [String: String] = {
        let sibling = (#filePath as NSString).deletingLastPathComponent + "/DemoConfig.local.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sibling)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }()
}
#endif
