import Foundation

/// JSON-RPC 2.0 request/response/notification, framed as newline-delimited JSON over the UDS.
struct RPCRequest: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?            // nil => notification (no response expected)
    var method: String
    var params: JSONValue?
    var source: String?    // calling client: app/cli/mcp (for activity attribution)
}

public struct RPCError: Codable, Sendable, Error {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
}

struct RPCResponse: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?
    var result: JSONValue?
    var error: RPCError?
}

/// A server→client notification (no id), used for the live event stream: `{method:"event", params:<Event>}`.
struct RPCNotification: Encodable, Sendable {
    var jsonrpc = "2.0"
    var method: String
    var params: JSONValue?
}

/// What a client decodes off the wire — either a response (`id` + `result`/`error`) or a notification
/// (`method` + `params`). One shape so the read loop doesn't have to guess-and-retry.
struct WireMessage: Decodable, Sendable {
    var id: Int?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: RPCError?
}

enum RPCCodec {
    /// Shared with the rest of the codebase (compact wire output + iso8601 dates).
    static var decoder: JSONDecoder { OrchestraJSON.decoder }

    /// Encode a value to a single NDJSON line (no embedded newlines: wire JSON is compact).
    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try OrchestraJSON.wire.encode(value)
        data.append(0x0A)   // '\n'
        return data
    }
}
