import Foundation

/// Loads a per-adapter OFFLINE model table from a vendored, PR-updated JSON resource
/// (`Resources/<name>.json`, `.copy`-bundled). No network fetch — build or runtime (D7 / §6).
/// The table is the source of truth for each model's context window + capability flags; edit the
/// JSON in a PR to add or adjust a model. Decoded once per resource name and cached.
enum ModelCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [AgentModel]] = [:]

    /// Decode `Bundle.module`'s `<resource>.json` as `[AgentModel]`. Returns `[]` if the resource is
    /// absent or unreadable (callers keep their own fallback), never throws into launch paths.
    static func load(_ resource: String) -> [AgentModel] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[resource] { return hit }
        let models = decode(resource)
        cache[resource] = models
        return models
    }

    private static func decode(_ resource: String) -> [AgentModel] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([AgentModel].self, from: data)
        else { return [] }
        return models
    }
}
