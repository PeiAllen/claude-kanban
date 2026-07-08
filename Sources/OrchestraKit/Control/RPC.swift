import Foundation

/// JSON-RPC 2.0 request/response/notification, framed as newline-delimited JSON over the UDS.
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?            // nil => notification (no response expected)
    public var method: String
    public var params: JSONValue?
    public var source: String?    // calling client: app/cli/mcp (for activity attribution)
    public var clientId: String?  // D3: stable per-install client identity; nil for anonymous CLI/MCP.
                                  // Optional + additive: omitted from the wire when nil (encodeIfPresent),
                                  // decodes to nil when absent. Server tracks connection→clientId so D4
                                  // attributes ownership + detects disconnect.
    public init(id: Int? = nil, method: String, params: JSONValue? = nil, source: String? = nil,
                clientId: String? = nil) {
        self.id = id; self.method = method; self.params = params; self.source = source
        self.clientId = clientId
    }
}

public struct RPCError: Codable, Sendable, Error {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
}

public struct RPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var result: JSONValue?
    public var error: RPCError?
    public init(id: Int? = nil, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}

/// A server→client notification (no id), used for the live event stream: `{method:"event", params:<Event>}`.
public struct RPCNotification: Encodable, Sendable {
    public var jsonrpc = "2.0"
    public var method: String
    public var params: JSONValue?
    public init(method: String, params: JSONValue? = nil) { self.method = method; self.params = params }
}

/// What a client decodes off the wire — either a response (`id` + `result`/`error`) or a notification
/// (`method` + `params`). One shape so the read loop doesn't have to guess-and-retry.
public struct WireMessage: Decodable, Sendable {
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?
}

public enum RPCCodec {
    /// Shared with the rest of the codebase (compact wire output + iso8601 dates).
    public static var decoder: JSONDecoder { OrchestraJSON.decoder }

    /// Encode a value to a single NDJSON line (no embedded newlines: wire JSON is compact).
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try OrchestraJSON.wire.encode(value)
        data.append(0x0A)   // '\n'
        return data
    }
}
