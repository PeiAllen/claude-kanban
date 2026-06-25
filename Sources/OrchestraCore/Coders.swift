import Foundation

/// The codebase's two JSON shapes, in one place so the date strategy / formatting can't drift
/// between the store, the wire, the CLI, and the JSONValue bridge.
public enum OrchestraJSON {
    /// Compact, single-line output — for NDJSON wire frames and `JSONValue` <-> model bridging.
    public static let wire: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Human-facing pretty output — for on-disk files (tasks.json / config.json) and CLI printing.
    /// `withoutEscapingSlashes` keeps file paths readable.
    public static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// The one decoder — iso8601 dates, matching both encoders above.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
