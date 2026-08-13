import OrchestraKit
import Foundation

let path = CommandLine.arguments[1]
let src = try! String(contentsOfFile: path, encoding: .utf8)
let startLine = Int(CommandLine.arguments[2])!
let endLine = Int(CommandLine.arguments[3])!
let note = CommandLine.arguments[4]

let c = DocumentComment.capture(path: "verify-doc.md", source: src, startLine: startLine, endLine: endLine)
print("headingPath:", c.headingPath)
print("excerpt:")
print(c.excerpt)
print("=== full message ===")
print(c.message(note: note))
