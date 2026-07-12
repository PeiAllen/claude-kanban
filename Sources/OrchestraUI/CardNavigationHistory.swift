import Foundation

/// Session-local browser-style history for card selection. Traversal moves the cursor without
/// recording a new visit; a subsequent explicit selection truncates the abandoned forward branch.
struct CardNavigationHistory {
    private var entries: [UUID] = []
    private var cursor: Int?

    mutating func record(_ id: UUID) {
        if let cursor, entries[cursor] == id { return }
        if let cursor, cursor + 1 < entries.count {
            entries.removeSubrange((cursor + 1)..<entries.count)
        }
        entries.append(id)
        cursor = entries.count - 1
    }

    mutating func back(validIds: Set<UUID>) -> UUID? {
        move(by: -1, validIds: validIds)
    }

    mutating func forward(validIds: Set<UUID>) -> UUID? {
        move(by: 1, validIds: validIds)
    }

    private mutating func move(by step: Int, validIds: Set<UUID>) -> UUID? {
        guard let cursor else { return nil }
        var candidate = cursor + step
        while entries.indices.contains(candidate) {
            if validIds.contains(entries[candidate]) {
                self.cursor = candidate
                return entries[candidate]
            }
            candidate += step
        }
        return nil
    }
}
