import Foundation
import OrchestraCore

// orchestra-mcp — a minimal MCP stdio bridge. One tool per CommandRegistry command; each tool call
// relays to the daemon over the control socket. Newline-delimited JSON-RPC on stdin/stdout.

let registry = CommandRegistry()
let socketPath = ProcessInfo.processInfo.environment["ORCHESTRA_SOCK"] ?? Config.socketPath

func logErr(_ s: String) { FileHandle.standardError.write(Data("[orchestra-mcp] \(s)\n".utf8)) }

func emit(_ response: JSONValue) {
    if let data = try? response.rawData() {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func ok(id: JSONValue?, _ result: JSONValue) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
}
func err(id: JSONValue?, code: Int, _ message: String) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id ?? .null,
             "error": .object(["code": .int(code), "message": .string(message)])])
}

func toolsList() -> JSONValue {
    let tools = registry.commands.map { cmd in
        JSONValue.object([
            "name": .string(cmd.name),
            "description": .string(cmd.summary),
            "inputSchema": cmd.params,
        ])
    }
    return .object(["tools": .array(tools)])
}

/// Run a tool by relaying to the daemon. Returns an MCP `content` result.
func callTool(name: String, arguments: JSONValue) async -> JSONValue {
    let client = ControlClient(socketPath: socketPath, source: .mcp)
    do { try client.connect() } catch {
        return .object(["content": .array([.object(["type": .string("text"),
            "text": .string("daemon not reachable: \(error)")])]), "isError": .bool(true)])
    }
    defer { client.close() }
    do {
        let result = try await client.call(name, arguments)
        let text = String(decoding: (try? result.rawData()) ?? Data(), as: UTF8.self)
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    } catch let e as RPCError {
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(e.message)])]),
                        "isError": .bool(true)])
    } catch {
        return .object(["content": .array([.object(["type": .string("text"), "text": .string("\(error)")])]),
                        "isError": .bool(true)])
    }
}

func handle(_ req: JSONValue) async {
    let id = req["id"]
    guard let method = req["method"]?.stringValue else { return }
    switch method {
    case "initialize":
        emit(ok(id: id, .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string("orchestra"), "version": .string(OrchestraVersion.current)]),
        ])))
    case "notifications/initialized", "initialized":
        break   // notification, no response
    case "ping":
        emit(ok(id: id, .object([:])))
    case "tools/list":
        emit(ok(id: id, toolsList()))
    case "tools/call":
        let params = req["params"] ?? .object([:])
        guard let name = params["name"]?.stringValue else {
            emit(err(id: id, code: -32602, "missing tool name")); return
        }
        let arguments = params["arguments"] ?? .object([:])
        let result = await callTool(name: name, arguments: arguments)
        emit(ok(id: id, result))
    default:
        if id != nil { emit(err(id: id, code: -32601, "method not found: \(method)")) }
    }
}

logErr("ready (socket \(socketPath))")
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let req = try? JSONValue.parse(data) else { continue }
    await handle(req)
}
