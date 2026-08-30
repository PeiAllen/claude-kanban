import Foundation

enum CodexAppServerError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case handshakeFailed(String)
    case connectionClosed
    case protocolViolation(String)
    case rpcError(code: Int, message: String)
}

enum WebSocketOpcode: UInt8, Equatable, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    var isControl: Bool { rawValue >= 0x8 }
}

struct WebSocketFrame: Equatable, Sendable {
    var fin: Bool
    var opcode: WebSocketOpcode
    var payload: Data
}

enum WebSocketFrameCodec {
    static let maximumPayloadBytes = 8 * 1024 * 1024

    static func encode(_ frame: WebSocketFrame, maskKey: [UInt8]?) throws -> Data {
        if frame.opcode.isControl {
            guard frame.fin else {
                throw CodexAppServerError.protocolViolation("fragmented WebSocket control frame")
            }
            guard frame.payload.count <= 125 else {
                throw CodexAppServerError.protocolViolation("oversized WebSocket control frame")
            }
        }
        guard frame.payload.count <= maximumPayloadBytes else {
            throw CodexAppServerError.protocolViolation("oversized WebSocket payload")
        }
        if let maskKey, maskKey.count != 4 {
            throw CodexAppServerError.protocolViolation("invalid WebSocket mask length")
        }

        var bytes: [UInt8] = [(frame.fin ? 0x80 : 0) | frame.opcode.rawValue]
        let masked: UInt8 = maskKey == nil ? 0 : 0x80
        switch frame.payload.count {
        case 0..<126:
            bytes.append(masked | UInt8(frame.payload.count))
        case 126..<65_536:
            bytes.append(masked | 126)
            let length = UInt16(frame.payload.count)
            bytes.append(UInt8(length >> 8))
            bytes.append(UInt8(length & 0xFF))
        default:
            bytes.append(masked | 127)
            let length = UInt64(frame.payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        let payload = [UInt8](frame.payload)
        if let maskKey {
            bytes.append(contentsOf: maskKey)
            bytes.append(contentsOf: payload.enumerated().map { index, byte in
                byte ^ maskKey[index % 4]
            })
        } else {
            bytes.append(contentsOf: payload)
        }
        return Data(bytes)
    }

    /// Decode one frame without consuming `bytes` until the complete frame is present.
    static func decode(from bytes: inout Data, expectedMask: Bool) throws -> WebSocketFrame? {
        let source = [UInt8](bytes)
        guard source.count >= 2 else { return nil }

        let first = source[0]
        guard first & 0x70 == 0 else {
            throw CodexAppServerError.protocolViolation("unsupported WebSocket extension bits")
        }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
            throw CodexAppServerError.protocolViolation("unknown WebSocket opcode")
        }
        let fin = first & 0x80 != 0
        let masked = source[1] & 0x80 != 0
        guard masked == expectedMask else {
            throw CodexAppServerError.protocolViolation("unexpected WebSocket mask")
        }

        var index = 2
        var length = UInt64(source[1] & 0x7F)
        if length == 126 {
            guard source.count >= index + 2 else { return nil }
            length = (UInt64(source[index]) << 8) | UInt64(source[index + 1])
            index += 2
        } else if length == 127 {
            guard source.count >= index + 8 else { return nil }
            guard source[index] & 0x80 == 0 else {
                throw CodexAppServerError.protocolViolation("invalid WebSocket 64-bit length")
            }
            length = 0
            for byte in source[index..<(index + 8)] { length = (length << 8) | UInt64(byte) }
            index += 8
        }
        guard length <= UInt64(maximumPayloadBytes) else {
            throw CodexAppServerError.protocolViolation("oversized WebSocket payload")
        }

        if opcode.isControl {
            guard fin else {
                throw CodexAppServerError.protocolViolation("fragmented WebSocket control frame")
            }
            guard length <= 125 else {
                throw CodexAppServerError.protocolViolation("oversized WebSocket control frame")
            }
        }

        var mask: ArraySlice<UInt8> = []
        if masked {
            guard source.count >= index + 4 else { return nil }
            mask = source[index..<(index + 4)]
            index += 4
        }
        guard length <= UInt64(Int.max), source.count >= index + Int(length) else { return nil }

        var payload = Array(source[index..<(index + Int(length))])
        if masked {
            let key = Array(mask)
            for offset in payload.indices { payload[offset] ^= key[offset % 4] }
        }
        bytes.removeFirst(index + Int(length))
        return WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload))
    }
}

enum WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func accept(for key: String) -> String {
        SHA1.hash(Data((key + guid).utf8)).base64EncodedString()
    }

    static func randomKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
    }
}

/// Small dependency-free SHA-1 used only for the RFC 6455 HTTP upgrade check. This is protocol framing,
/// not a cryptographic trust boundary; the Unix socket's filesystem permissions are the authentication.
private enum SHA1 {
    static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        for offset in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for index in 16..<80 {
                words[index] = rotateLeft(
                    words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16],
                    by: 1
                )
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4
            for index in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch index {
                case 0..<20: (f, k) = ((b & c) | ((~b) & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temp
            }
            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
        }

        var digest = Data()
        for word in [h0, h1, h2, h3, h4] {
            digest.append(UInt8(word >> 24))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, by bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }
}

protocol CodexAppServerPeer: AnyObject, Sendable {
    func open() throws
    func send(_ message: JSONValue) throws
    func receive() throws -> JSONValue
    func shutdown()
    func close()
}

/// The narrow WebSocket-over-UDS peer required by Codex app-server clients: masked JSON text out, JSON
/// text in, ping/pong, close, and fragmented text assembly. It intentionally exposes no provider RPC methods.
final class WebSocketCodexAppServerPeer: CodexAppServerPeer, @unchecked Sendable {
    private let socketPath: String
    private let ioTimeout: TimeInterval?
    private let stateLock: NSLock
    private let shutdownDescriptor: @Sendable (Int32) -> Void
    private let writeLock = NSLock()
    private var isShutDown = false
    private var fd: Int32 = -1
    private var pending = Data()
    private var fragment = Data()
    private var fragmentOpcode: WebSocketOpcode?

    init(
        socketPath: String,
        ioTimeout: TimeInterval? = nil,
        stateLock: NSLock = NSLock(),
        shutdownDescriptor: @escaping @Sendable (Int32) -> Void = shutdownFD
    ) {
        self.socketPath = socketPath
        self.ioTimeout = ioTimeout
        self.stateLock = stateLock
        self.shutdownDescriptor = shutdownDescriptor
    }

    func open() throws {
        let connected: Int32
        do { connected = try UDS.connect(path: socketPath, ioTimeout: ioTimeout) }
        catch { throw CodexAppServerError.connectionFailed(String(describing: error)) }
        let accepted = stateLock.withLock {
            guard !isShutDown else { return false }
            fd = connected
            return true
        }
        guard accepted else {
            closeFD(connected)
            throw CodexAppServerError.connectionClosed
        }
        do { try upgrade() }
        catch { close(); throw error }
    }

    func send(_ message: JSONValue) throws {
        try sendFrame(.init(fin: true, opcode: .text, payload: try message.rawData()))
    }

    func receive() throws -> JSONValue {
        while true {
            let frame = try nextFrame()
            switch frame.opcode {
            case .ping:
                try sendFrame(.init(fin: true, opcode: .pong, payload: frame.payload))
            case .pong:
                continue
            case .close:
                try? sendFrame(.init(fin: true, opcode: .close, payload: frame.payload))
                throw CodexAppServerError.connectionClosed
            case .binary:
                throw CodexAppServerError.protocolViolation("binary WebSocket message")
            case .text:
                guard fragmentOpcode == nil else {
                    throw CodexAppServerError.protocolViolation("new data frame during fragmentation")
                }
                if frame.fin { return try decodeJSON(frame.payload) }
                fragmentOpcode = .text
                fragment = frame.payload
            case .continuation:
                guard fragmentOpcode == .text else {
                    throw CodexAppServerError.protocolViolation("unexpected WebSocket continuation")
                }
                guard fragment.count + frame.payload.count <= WebSocketFrameCodec.maximumPayloadBytes else {
                    throw CodexAppServerError.protocolViolation("oversized fragmented WebSocket payload")
                }
                fragment.append(frame.payload)
                if frame.fin {
                    let complete = fragment
                    fragment = Data()
                    fragmentOpcode = nil
                    return try decodeJSON(complete)
                }
            }
        }
    }

    func shutdown() {
        stateLock.withLock {
            isShutDown = true
            if fd >= 0 { shutdownDescriptor(fd) }
        }
    }

    func close() {
        let current: Int32 = stateLock.withLock {
            let current = fd
            fd = -1
            return current
        }
        if current >= 0 { closeFD(current) }
    }

    private func upgrade() throws {
        let key = WebSocketHandshake.randomKey()
        let request = "GET / HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try writeRaw(Data(request.utf8))

        let delimiter = Data("\r\n\r\n".utf8)
        while pending.range(of: delimiter) == nil {
            guard pending.count <= 32 * 1024 else {
                throw CodexAppServerError.handshakeFailed("oversized HTTP response")
            }
            try readMore()
        }
        guard let range = pending.range(of: delimiter) else {
            throw CodexAppServerError.handshakeFailed("incomplete HTTP response")
        }
        let headerData = pending.subdata(in: pending.startIndex..<range.lowerBound)
        pending.removeSubrange(pending.startIndex..<range.upperBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw CodexAppServerError.handshakeFailed("non-UTF8 HTTP response")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.contains(" 101 ") == true || lines.first?.hasSuffix(" 101") == true else {
            throw CodexAppServerError.handshakeFailed(lines.first ?? "missing status")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        let connectionTokens = fields["connection"]?.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard fields["upgrade"]?.lowercased() == "websocket",
              connectionTokens.contains("upgrade"),
              fields["sec-websocket-accept"] == WebSocketHandshake.accept(for: key)
        else { throw CodexAppServerError.handshakeFailed("invalid WebSocket upgrade headers") }
    }

    private func nextFrame() throws -> WebSocketFrame {
        while true {
            if let frame = try WebSocketFrameCodec.decode(from: &pending, expectedMask: false) {
                return frame
            }
            try readMore()
        }
    }

    private func readMore() throws {
        let current = stateLock.withLock { fd }
        guard current >= 0 else { throw CodexAppServerError.connectionClosed }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let count = UDS.read(current, into: &buffer) else {
                throw CodexAppServerError.connectionClosed
            }
            if count == 0 { continue }
            pending.append(contentsOf: buffer[0..<count])
            return
        }
    }

    private func sendFrame(_ frame: WebSocketFrame) throws {
        var generator = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        try writeRaw(WebSocketFrameCodec.encode(frame, maskKey: mask))
    }

    private func writeRaw(_ data: Data) throws {
        try writeLock.withLock {
            let current = stateLock.withLock { fd }
            guard current >= 0, UDS.writeAll(current, data) else {
                throw CodexAppServerError.connectionClosed
            }
        }
    }

    private func decodeJSON(_ payload: Data) throws -> JSONValue {
        do { return try JSONValue.parse(payload) }
        catch { throw CodexAppServerError.protocolViolation("invalid JSON text message") }
    }
}
