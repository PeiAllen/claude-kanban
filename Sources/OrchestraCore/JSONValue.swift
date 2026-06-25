import Foundation

/// A minimal JSON value used as the transport-agnostic currency between the control plane and the
/// `CommandRegistry`. Codable both ways; converts to/from any Codable model.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: conversions

    /// Build a JSONValue from any Encodable model.
    public init(encodable: some Encodable) throws {
        let data = try OrchestraJSON.wire.encode(encodable)
        self = try OrchestraJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// Decode this JSONValue into a Codable type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try OrchestraJSON.wire.encode(self)
        return try OrchestraJSON.decoder.decode(T.self, from: data)
    }

    public func rawData() throws -> Data { try OrchestraJSON.wire.encode(self) }

    public static func parse(_ data: Data) throws -> JSONValue {
        try OrchestraJSON.decoder.decode(JSONValue.self, from: data)
    }

    // MARK: accessors

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var doubleValue: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Required string param.
    public func string(_ key: String) throws -> String {
        guard let s = self[key]?.stringValue else { throw OrchestraError.invalidParams("missing string '\(key)'") }
        return s
    }
    public func optString(_ key: String) -> String? { self[key]?.stringValue }
    public func optInt(_ key: String) -> Int? { self[key]?.intValue }

    public static func ok() -> JSONValue { .object(["ok": .bool(true)]) }
}
