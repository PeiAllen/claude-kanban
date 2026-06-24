import Foundation
import OrchestraCore
import MCP

// orchestra-mcp — the MCP stdio bridge, built on the official Swift SDK. One tool per
// CommandRegistry command; each tool call relays to the daemon over the control socket.

let registry = CommandRegistry()
let socketPath = ProcessInfo.processInfo.environment["ORCHESTRA_SOCK"] ?? Config.socketPath

func logErr(_ s: String) { FileHandle.standardError.write(Data("[orchestra-mcp] \(s)\n".utf8)) }

// Bridge our JSONValue <-> the SDK's Value (both Codable).
func toMCPValue(_ jv: JSONValue) -> Value { (try? Value(jv)) ?? .null }
func argsToJSON(_ args: [String: Value]?) -> JSONValue {
    guard let args else { return .object([:]) }
    let data = (try? JSONEncoder().encode(args)) ?? Data("{}".utf8)
    return (try? JSONValue.parse(data)) ?? .object([:])
}

let server = Server(
    name: "orchestra",
    version: OrchestraVersion.current,
    capabilities: .init(tools: .init(listChanged: false))
)

// tools/list — generated from the canonical command set.
_ = await server.withMethodHandler(ListTools.self) { _ in
    let tools = registry.commands.map { cmd in
        Tool(name: cmd.name, description: cmd.summary, inputSchema: toMCPValue(cmd.params))
    }
    return ListTools.Result(tools: tools)
}

// tools/call — relay to the daemon and return the result as text content.
_ = await server.withMethodHandler(CallTool.self) { params in
    let client = ControlClient(socketPath: socketPath, source: .mcp)
    do { try client.connect() } catch {
        return CallTool.Result(
            content: [.text(text: "daemon not reachable: \(error)", annotations: nil, _meta: nil)],
            isError: true)
    }
    defer { client.close() }
    do {
        let result = try await client.call(params.name, argsToJSON(params.arguments))
        let text = String(decoding: (try? result.rawData()) ?? Data(), as: UTF8.self)
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    } catch let e as RPCError {
        return CallTool.Result(content: [.text(text: e.message, annotations: nil, _meta: nil)], isError: true)
    } catch {
        return CallTool.Result(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
    }
}

logErr("ready (socket \(socketPath))")
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
