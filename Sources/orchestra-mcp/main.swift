import Foundation
import OrchestraCore

// Placeholder — the MCP bridge is fleshed out in the control-plane layer.
FileHandle.standardError.write(Data("orchestra-mcp \(OrchestraVersion.current)\n".utf8))
