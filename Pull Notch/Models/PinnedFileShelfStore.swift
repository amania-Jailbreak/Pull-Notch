import Foundation
import Observation

struct PinnedFileItem: Identifiable, Equatable {
    let id: UUID
    let url: URL?
    let displayName: String
    let parentPath: String
    let addedAt: Date
    let modificationDate: Date?
    let isAvailable: Bool
}

struct PinnedFileAddResult: Equatable {
    let addedCount: Int
    let duplicateCount: Int
    let rejectedCount: Int

    var acceptedCount: Int { addedCount + duplicateCount }
}

@MainActor
@Observable
final class PinnedFileShelfStore {
    static let maximumItemCount = 12

    private struct Record: Codable, Equatable {
        let id: UUID
        var bookmarkData: Data
        var displayName: String
        var parentPath: String
        let addedAt: Date
    }

    private struct PersistedShelf: Codable, Equatable {
        let version: Int
        var records: [Record]
        var selectedID: UUID?
    }

    private enum Key {
        static let shelf = "PullNotch.pinnedFileShelf.v1"
        static let legacyBookmark = "PullNotch.pinnedFileBookmark"
    }

    private(set) var items: [PinnedFileItem] = []
    private(set) var selectedID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var records: [Record] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreOrMigrate()
    }

    var selectedItem: PinnedFileItem? {
        guard let selectedID else { return items.first }
        return items.first(where: { $0.id == selectedID }) ?? items.first
    }

    @discardableResult
    func add(_ urls: [URL]) -> PinnedFileAddResult {
        var addedCount = 0
        var duplicateCount = 0
        var rejectedCount = 0
        var lastAcceptedID: UUID?

        for url in urls where url.isFileURL {
            let identity = Self.identity(for: url)
            if let existingIndex = items.firstIndex(where: { item in
                guard let existingURL = item.url else {
                    return Self.cachedIdentity(name: item.displayName, parentPath: item.parentPath) == identity
                }
                return Self.identity(for: existingURL) == identity
            }) {
                duplicateCount += 1
                lastAcceptedID = items[existingIndex].id
                continue
            }

            guard records.count < Self.maximumItemCount,
                  let bookmarkData = try? url.bookmarkData()
            else {
                rejectedCount += 1
                continue
            }

            let record = Record(
                id: UUID(),
                bookmarkData: bookmarkData,
                displayName: url.lastPathComponent,
                parentPath: url.deletingLastPathComponent().path,
                addedAt: .now
            )
            records.append(record)
            addedCount += 1
            lastAcceptedID = record.id
        }

        rejectedCount += urls.filter { !$0.isFileURL }.count
        if let lastAcceptedID {
            selectedID = lastAcceptedID
        }
        rebuildItems(refreshBookmarks: true)
        persist()
        return PinnedFileAddResult(
            addedCount: addedCount,
            duplicateCount: duplicateCount,
            rejectedCount: rejectedCount
        )
    }

    func select(id: UUID) {
        guard records.contains(where: { $0.id == id }), selectedID != id else { return }
        selectedID = id
        persist()
    }

    func move(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = records.firstIndex(where: { $0.id == id }),
              let targetIndex = records.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        let record = records.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        records.insert(record, at: adjustedTarget)
        rebuildItems(refreshBookmarks: false)
        persist()
    }

    func remove(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)

        if selectedID == id {
            if records.isEmpty {
                selectedID = nil
            } else {
                selectedID = records[min(index, records.count - 1)].id
            }
        }

        rebuildItems(refreshBookmarks: false)
        persist()
    }

    func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
        items.removeAll()
        selectedID = nil
        persist()
    }

    func refresh() {
        rebuildItems(refreshBookmarks: true)
        persist()
    }

    private func restoreOrMigrate() {
        if let data = defaults.data(forKey: Key.shelf),
           let shelf = try? JSONDecoder().decode(PersistedShelf.self, from: data),
           shelf.version == 1 {
            records = Array(shelf.records.prefix(Self.maximumItemCount))
            selectedID = shelf.selectedID
            normalizeSelection()
            rebuildItems(refreshBookmarks: true)
            persist()
            return
        }

        guard let legacyBookmark = defaults.data(forKey: Key.legacyBookmark) else {
            rebuildItems(refreshBookmarks: false)
            return
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: legacyBookmark,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        let bookmarkData = (isStale ? try? url.bookmarkData() : nil) ?? legacyBookmark
        let record = Record(
            id: UUID(),
            bookmarkData: bookmarkData,
            displayName: url.lastPathComponent,
            parentPath: url.deletingLastPathComponent().path,
            addedAt: .now
        )
        records = [record]
        selectedID = record.id
        rebuildItems(refreshBookmarks: true)
        if persist() {
            defaults.removeObject(forKey: Key.legacyBookmark)
        }
    }

    private func rebuildItems(refreshBookmarks: Bool) {
        var rebuiltItems: [PinnedFileItem] = []
        for index in records.indices {
            var record = records[index]
            var isStale = false
            let resolvedURL = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                bookmarkDataIsStale: &isStale
            )

            if refreshBookmarks, isStale, let resolvedURL,
               let refreshedData = try? resolvedURL.bookmarkData() {
                record.bookmarkData = refreshedData
            }
            if let resolvedURL {
                record.displayName = resolvedURL.lastPathComponent
                record.parentPath = resolvedURL.deletingLastPathComponent().path
            }
            records[index] = record

            let isAvailable = resolvedURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            let modificationDate = resolvedURL.flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }

            rebuiltItems.append(PinnedFileItem(
                id: record.id,
                url: resolvedURL,
                displayName: record.displayName,
                parentPath: record.parentPath,
                addedAt: record.addedAt,
                modificationDate: modificationDate,
                isAvailable: isAvailable
            ))
        }
        items = rebuiltItems
        normalizeSelection()
    }

    private func normalizeSelection() {
        if let selectedID, records.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = records.first?.id
    }

    @discardableResult
    private func persist() -> Bool {
        let shelf = PersistedShelf(version: 1, records: records, selectedID: selectedID)
        guard let data = try? JSONEncoder().encode(shelf) else { return false }
        defaults.set(data, forKey: Key.shelf)
        return true
    }

    private static func identity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func cachedIdentity(name: String, parentPath: String) -> String {
        URL(fileURLWithPath: parentPath)
            .appendingPathComponent(name)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
