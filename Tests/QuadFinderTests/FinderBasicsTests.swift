import Foundation
import Testing
@testable import QuadFinder

@Suite("Finder basic operations")
struct FinderBasicsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func renameRejectsExistingDestinationWithoutMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        #expect(throws: FinderActionError.self) {
            _ = try FinderActionService().rename(source, to: destination.lastPathComponent)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "destination")
    }

    @Test func duplicateNeverOverwritesAndSelectsNextAvailableName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("report.txt")
        let firstCopy = directory.appendingPathComponent("report のコピー.txt")
        try Data("original".utf8).write(to: source)
        try Data("keep".utf8).write(to: firstCopy)

        let result = try FinderActionService().duplicate(source)

        #expect(result.lastPathComponent == "report のコピー 2.txt")
        #expect(try String(contentsOf: firstCopy, encoding: .utf8) == "keep")
        #expect(try String(contentsOf: result, encoding: .utf8) == "original")
    }

    @Test func invalidRenameDoesNotAlterSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data().write(to: source)

        #expect(throws: FinderActionError.self) {
            _ = try FinderActionService().rename(source, to: "../unsafe")
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func pasteUsesActivePaneAndDoesNotGuessSourceBookmark() throws {
        let target = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        let source = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let conflictingTarget = target.appendingPathComponent(source.lastPathComponent)
        try Data("existing".utf8).write(to: conflictingTarget)

        let storage = MemoryWorkspacePersistence.Storage()
        storage.state = .initial(homeURL: target)
        let persistence = MemoryWorkspacePersistence(storage: storage)
        let workspace = WorkspaceStore(persistence: persistence)
        FinderClipboard.shared.write(urls: [source], cut: true)
        workspace.preparePasteFromClipboard()

        #expect(workspace.pendingDrop == nil)
        #expect(workspace.transferPlanner?.request.sourceURLs == [source.standardizedFileURL])
        #expect(workspace.transferPlanner?.request.targetDirectoryURL == target.standardizedFileURL)
        #expect(workspace.transferPlanner?.request.sourceAccessBookmark == nil)
        #expect(workspace.transferPlanner?.request.kind == .move)
    }
}
