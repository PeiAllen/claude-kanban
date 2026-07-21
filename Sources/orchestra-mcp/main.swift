import Foundation
import OrchestraKit
import MCP

// orchestra-mcp — the MCP stdio bridge, built on the official Swift SDK. One tool per
// CommandCatalog command; each tool call relays to the daemon over the control socket. The bridge
// depends on OrchestraKit only (the client-safe vocabulary + transport) — never on daemon code.

let socketPath = ProcessInfo.processInfo.environment["ORCHESTRA_SOCK"] ?? Config.socketPath

func logErr(_ s: String) { FileHandle.standardError.write(Data("[orchestra-mcp] \(s)\n".utf8)) }

// Bridge our JSONValue <-> the SDK's Value (both Codable).
func toMCPValue(_ jv: JSONValue) -> Value { (try? Value(jv)) ?? .null }
func argsToJSON(_ args: [String: Value]?) -> JSONValue {
    guard let args else { return .object([:]) }
    let data = (try? OrchestraJSON.wire.encode(args)) ?? Data("{}".utf8)
    return (try? JSONValue.parse(data)) ?? .object([:])
}

let server = Server(
    name: "orchestra",
    version: OrchestraVersion.current,
    capabilities: .init(tools: .init(listChanged: false))
)

// tools/list — generated from the canonical command vocabulary (schema only; no daemon handlers).
// `.appOnly` commands (send-keys, capture, inspect) are withheld: they are human-only primitives the
// agent's tool-use must not reach — see `CommandExposure`.
_ = await server.withMethodHandler(ListTools.self) { _ in
    let tools = CommandCatalog.mcpExposed.map { s in
        Tool(name: s.name, description: s.summary, inputSchema: toMCPValue(s.params))
    }
    return ListTools.Result(tools: tools)
}

// tools/call — relay to the daemon and return the result as text content. The image command gets
// the same human-facing marker that the CLI prints; other commands retain their structured JSON text.
_ = await server.withMethodHandler(CallTool.self) { params in
    let client = ControlClient(socketPath: socketPath, source: .mcp)
    do { try client.connect() } catch {
        return CallTool.Result(
            content: [.text(text: "daemon not reachable: \(error)", annotations: nil, _meta: nil)],
            isError: true)
    }
    defer { client.close() }
    // The `trust` tool is the ONE human-gated command: elicit a decision from the agent's own MCP
    // client (a human answers there — the agent can only trigger it) and relay to the daemon only on
    // accept. `requestElicitation` throws if the client never advertised `elicitation`; both v1
    // targets (Claude Code, Codex) do, so there is no fallback here (design §4.1).
    if params.name == "trust" {
        let path = argsToJSON(params.arguments).optString("path") ?? "this directory"
        do {
            let elicit = try await server.requestElicitation(
                message: "An agent is requesting write-trust for \(path). Approve so agents may run "
                    + "there with write access?",
                requestedSchema: .init())
            guard elicit.action == .accept else {
                return CallTool.Result(
                    content: [.text(text: "trust declined by the human", annotations: nil, _meta: nil)],
                    isError: true)
            }
        } catch {
            return CallTool.Result(
                content: [.text(text: "trust elicitation failed: \(error)", annotations: nil, _meta: nil)],
                isError: true)
        }
    }
    var args = argsToJSON(params.arguments)
    if params.name == "wait",
       args.optString("watcher") == nil,
       let selfId = ProcessInfo.processInfo.environment["ORCHESTRA_TASK_ID"],
       !selfId.isEmpty {
        let existing: [String: JSONValue]
        if case .object(let fields) = args { existing = fields } else { existing = [:] }
        var fields = existing
        fields["watcher"] = .string(selfId)
        args = .object(fields)
    }
    // Client-minted id (required wire field): inject one ONLY when the agent didn't supply it — an agent
    // that supplies+reuses an `id` across a manual retry gets idempotent dedup; one that omits it still spawns.
    if params.name == "spawn", case .object(var fields) = args, fields["id"] == nil {
        fields["id"] = .string(UUID().uuidString)
        args = .object(fields)
    }
    // `send`'s message id follows the same required-wire / stamp-if-absent contract: inject one ONLY when
    // the agent omitted it, so an agent that reuses an `id` across a manual retry gets idempotent dedup.
    if params.name == "send", case .object(var fields) = args, fields["id"] == nil {
        fields["id"] = .string(UUID().uuidString)
        args = .object(fields)
    }
    if params.name == "batch-spawn", case .object(var fields) = args,
       case .array(let items)? = fields["tasks"] {
        fields["tasks"] = .array(items.map { item in
            if case .object(var f) = item, f["id"] == nil {
                f["id"] = .string(UUID().uuidString)
                return .object(f)
            }
            return item
        })
        args = .object(fields)
    }
    do {
        let result = try await client.call(params.name, args)
        let text: String
        if params.name == "publish-image" {
            if let reference = try? result.decode(TranscriptImageReference.self) {
                text = TranscriptImageMarker.render(referenceID: reference.id, caption: reference.caption)
            } else {
                // Preserve the bridge's existing fail-open response while making a wire-contract drift
                // visible to the daemon operator instead of silently regressing to raw JSON.
                logErr("publish-image result did not match TranscriptImageReference; returning raw JSON")
                text = String(decoding: (try? result.rawData()) ?? Data(), as: UTF8.self)
            }
        } else {
            text = String(decoding: (try? result.rawData()) ?? Data(), as: UTF8.self)
        }
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
