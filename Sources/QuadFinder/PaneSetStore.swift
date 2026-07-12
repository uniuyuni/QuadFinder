import Foundation

struct NamedPaneSet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var workspace: WorkspaceState
    let createdAt: Date
}

@MainActor
final class PaneSetStore: ObservableObject {
    @Published private(set) var sets: [NamedPaneSet] = []
    @Published private(set) var loadErrors: [String] = []

    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directoryURL = base.appendingPathComponent("QuadFinder/PaneSets", isDirectory: true)
        }
        reload()
    }

    @discardableResult
    func save(name: String, workspace: WorkspaceState) throws -> NamedPaneSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let paneSet = NamedPaneSet(
            id: UUID(),
            name: trimmed.isEmpty ? "名称未設定" : trimmed,
            workspace: workspace,
            createdAt: Date()
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.quadFinder.encode(paneSet)
        try data.write(to: fileURL(for: paneSet.id), options: .atomic)
        sets.append(paneSet)
        sort()
        return paneSet
    }

    func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        sets.removeAll { $0.id == id }
    }

    func reload() {
        sets = []
        loadErrors = []
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            for file in files {
                do {
                    var paneSet = try JSONDecoder().decode(NamedPaneSet.self, from: Data(contentsOf: file))
                    paneSet.workspace.normalize()
                    sets.append(paneSet)
                } catch {
                    loadErrors.append("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            sort()
        } catch {
            loadErrors.append(error.localizedDescription)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func sort() { sets.sort { $0.createdAt < $1.createdAt } }
}

private extension JSONEncoder {
    static var quadFinder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
