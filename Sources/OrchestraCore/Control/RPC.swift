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

enum RPCCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// Encode a value to a single NDJSON line (no embedded newlines: JSONEncoder emits compact JSON).
    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)   // '\n'
        return data
    }
}
