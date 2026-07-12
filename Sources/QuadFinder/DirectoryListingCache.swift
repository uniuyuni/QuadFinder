import Foundation

struct DirectoryListingKey: Hashable, Sendable {
    let url: URL
    let showsHiddenFiles: Bool
}

actor DirectoryListingCache {
    static let shared = DirectoryListingCache()

    private struct CacheEntry {
        let items: [FileItem]
        let storedAt: Date
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<[FileItem], Error>
        let isFreshReload: Bool
    }

    private var cached: [DirectoryListingKey: CacheEntry] = [:]
    private var inFlight: [DirectoryListingKey: InFlightEntry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 2.0) {
        self.ttl = ttl
    }

    func entries(
        for key: DirectoryListingKey,
        bypassCache: Bool = false,
        loader: @escaping @Sendable () async throws -> [FileItem]
    ) async throws -> [FileItem] {
        if !bypassCache, let entry = cached[key], Date().timeIntervalSince(entry.storedAt) < ttl {
            return entry.items
        }
        if let existing = inFlight[key], !bypassCache || existing.isFreshReload {
            let result = try await existing.task.value
            try Task.checkCancellation()
            return result
        }
        // A fresh reload supersedes a normal in-flight generation without cancelling it.
        // Existing consumers may finish safely, but the old generation cannot overwrite cache.
        let id = UUID()
        let task = Task { try await loader() }
        inFlight[key] = InFlightEntry(id: id, task: task, isFreshReload: bypassCache)
        do {
            let result = try await task.value
            if inFlight[key]?.id == id {
                cached[key] = CacheEntry(items: result, storedAt: Date())
                inFlight[key] = nil
            }
            try Task.checkCancellation()
            return result
        } catch {
            if inFlight[key]?.id == id { inFlight[key] = nil }
            throw error
        }
    }

    func invalidate(url: URL) {
        let standardized = url.standardizedFileURL
        cached = cached.filter { $0.key.url.standardizedFileURL != standardized }
    }

    func removeAll() {
        cached.removeAll()
    }
}
