import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Daemon-owned, session-scoped storage for transcript image bytes. The store never hands a filesystem
/// path to a caller: consumers receive only an opaque reference and bounded Base64 payload.
public actor MediaStore {
    public static let defaultMaxFileBytes = 4 * 1024 * 1024
    public static let defaultMaxSessionBytes = 50 * 1024 * 1024

    private struct StoredImage: Codable, Sendable {
        let reference: TranscriptImageReference
        let byteCount: Int
    }

    private struct Index: Codable, Sendable {
        var records: [StoredImage] = []
    }

    private enum ImageFormat: Sendable {
        case png
        case jpeg

        var mimeType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            }
        }
    }

    private let root: URL
    private let maxFileBytes: Int
    private let maxSessionBytes: Int
    private let fileManager: FileManager

    public init(root: String, maxFileBytes: Int = MediaStore.defaultMaxFileBytes,
                maxSessionBytes: Int = MediaStore.defaultMaxSessionBytes,
                fileManager: FileManager = .default) {
        self.root = URL(fileURLWithPath: root, isDirectory: true)
        self.maxFileBytes = maxFileBytes
        self.maxSessionBytes = maxSessionBytes
        self.fileManager = fileManager
    }

    public func publish(cardId: UUID, sessionEpoch: Int, sourcePath: String,
                        caption: String?) throws -> TranscriptImageReference {
        guard sessionEpoch > 0 else {
            throw OrchestraError.invalidParams("image session epoch must be positive")
        }
        let source = try readValidatedSource(at: sourcePath)
        let directory = epochDirectory(cardId: cardId, epoch: sessionEpoch)
        var index = try loadIndex(in: directory)
        try validate(index: index, cardId: cardId, sessionEpoch: sessionEpoch)

        let bytesInSession = index.records.reduce(0) { $0 + $1.byteCount }
        guard source.data.count <= maxSessionBytes - bytesInSession else {
            throw OrchestraError.invalidParams("image publish exceeds the 50 MiB card-session limit")
        }

        let id = UUID()
        let reference = TranscriptImageReference(
            id: id,
            cardId: cardId,
            sessionEpoch: sessionEpoch,
            caption: safeCaption(caption),
            mimeType: source.format.mimeType,
            filename: "\(id.uuidString.lowercased()).\(source.format.fileExtension)"
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let assetURL = directory.appendingPathComponent(reference.filename)
        try writeAtomically(source.data, to: assetURL)

        index.records.append(StoredImage(reference: reference, byteCount: source.data.count))
        do {
            try writeIndex(index, in: directory)
        } catch {
            try? fileManager.removeItem(at: assetURL)
            throw error
        }
        return reference
    }

    public func payload(cardId: UUID, sessionEpoch: Int,
                        referenceID: UUID) throws -> TranscriptImagePayload {
        let directory = epochDirectory(cardId: cardId, epoch: sessionEpoch)
        let index = try loadIndex(in: directory)
        guard let stored = index.records.first(where: { $0.reference.id == referenceID }),
              isValid(stored.reference, cardId: cardId, sessionEpoch: sessionEpoch),
              stored.byteCount >= 0, stored.byteCount <= maxFileBytes
        else {
            throw OrchestraError.imageExpired
        }

        let assetURL = directory.appendingPathComponent(stored.reference.filename)
        guard let data = try? Data(contentsOf: assetURL),
              data.count == stored.byteCount,
              data.count <= maxFileBytes,
              format(of: data)?.mimeType == stored.reference.mimeType
        else {
            throw OrchestraError.imageExpired
        }
        return TranscriptImagePayload(reference: stored.reference, dataBase64: data.base64EncodedString())
    }

    public func removePriorEpochs(cardId: UUID, keeping epoch: Int) {
        let cardDirectory = cardDirectory(for: cardId)
        for child in contents(of: cardDirectory) where child.lastPathComponent != String(epoch) {
            try? fileManager.removeItem(at: child)
        }
    }

    public func removeCard(_ cardId: UUID) {
        try? fileManager.removeItem(at: cardDirectory(for: cardId))
    }

    /// Retain media only for known, non-archived cards at their durable current epoch.
    public func reconcile(activeCards: [UUID: Int]) {
        for cardDirectory in contents(of: root) {
            guard let cardId = UUID(uuidString: cardDirectory.lastPathComponent),
                  let currentEpoch = activeCards[cardId]
            else {
                try? fileManager.removeItem(at: cardDirectory)
                continue
            }
            for epochDirectory in contents(of: cardDirectory)
            where epochDirectory.lastPathComponent != String(currentEpoch) {
                try? fileManager.removeItem(at: epochDirectory)
            }
        }
    }

    private func readValidatedSource(at path: String) throws -> (data: Data, format: ImageFormat) {
        guard (path as NSString).isAbsolutePath else {
            throw OrchestraError.invalidParams("image source path must be absolute")
        }
        var before = stat()
        guard lstat(path, &before) == 0, isRegular(before) else {
            throw OrchestraError.invalidParams("image source must be a regular file, not a symlink")
        }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw OrchestraError.invalidParams("image source cannot be opened safely")
        }
        defer { _ = close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0, isRegular(opened), opened.st_size >= 0,
              opened.st_size <= off_t(maxFileBytes)
        else {
            throw OrchestraError.invalidParams("image source must be a regular file no larger than 4 MiB")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        } catch {
            throw OrchestraError.invalidParams("image source could not be read")
        }
        guard data.count <= maxFileBytes, let format = format(of: data) else {
            throw OrchestraError.invalidParams("image source must be a PNG or JPEG no larger than 4 MiB")
        }
        return (data, format)
    }

    private func cardDirectory(for cardId: UUID) -> URL {
        root.appendingPathComponent(cardId.uuidString.lowercased(), isDirectory: true)
    }

    private func epochDirectory(cardId: UUID, epoch: Int) -> URL {
        cardDirectory(for: cardId).appendingPathComponent(String(epoch), isDirectory: true)
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    private func loadIndex(in directory: URL) throws -> Index {
        let url = indexURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return Index() }
        do {
            return try OrchestraJSON.decoder.decode(Index.self, from: Data(contentsOf: url))
        } catch {
            throw OrchestraError.io("transcript image index is unreadable")
        }
    }

    private func writeIndex(_ index: Index, in directory: URL) throws {
        try writeAtomically(OrchestraJSON.pretty.encode(index), to: indexURL(in: directory))
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func validate(index: Index, cardId: UUID, sessionEpoch: Int) throws {
        var ids = Set<UUID>()
        for stored in index.records {
            guard stored.byteCount >= 0, stored.byteCount <= maxFileBytes,
                  ids.insert(stored.reference.id).inserted,
                  isValid(stored.reference, cardId: cardId, sessionEpoch: sessionEpoch)
            else {
                throw OrchestraError.io("transcript image index is invalid")
            }
        }
    }

    private func isValid(_ reference: TranscriptImageReference, cardId: UUID, sessionEpoch: Int) -> Bool {
        guard reference.cardId == cardId, reference.sessionEpoch == sessionEpoch else { return false }
        let expectedExtension: String
        switch reference.mimeType {
        case "image/png": expectedExtension = "png"
        case "image/jpeg": expectedExtension = "jpg"
        default: return false
        }
        return reference.filename == "\(reference.id.uuidString.lowercased()).\(expectedExtension)"
    }

    private func contents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func format(of data: Data) -> ImageFormat? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= png.count, Array(data.prefix(png.count)) == png { return .png }
        if data.count >= 3, Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF] { return .jpeg }
        return nil
    }

    private func safeCaption(_ caption: String?) -> String {
        let raw: String = caption ?? ""
        let withoutControls = raw.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let text = String(String.UnicodeScalarView(withoutControls)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(120)).isEmpty ? "image" : String(text.prefix(120))
    }

    private func isRegular(_ status: stat) -> Bool {
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }
}
