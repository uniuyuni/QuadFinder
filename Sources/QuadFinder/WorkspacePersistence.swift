import Foundation

protocol WorkspacePersisting: Sendable {
    func load() throws -> WorkspaceState?
    func save(_ state: WorkspaceState) throws
}

struct FileWorkspacePersistence: WorkspacePersisting {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("QuadFinder", isDirectory: true)
                .appendingPathComponent("workspace.json")
        }
    }

    func load() throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WorkspaceState.self, from: data)
    }

    func save(_ state: WorkspaceState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

struct MemoryWorkspacePersistence: WorkspacePersisting {
    final class Storage: @unchecked Sendable {
        var state: WorkspaceState?
    }

    let storage: Storage
    func load() throws -> WorkspaceState? { storage.state }
    func save(_ state: WorkspaceState) throws { storage.state = state }
}
