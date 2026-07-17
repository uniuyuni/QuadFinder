import Foundation
import Testing
@testable import QuadFinder

@MainActor
struct EnteredFolderPathTests {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
    }

    @Test func trimsWhitespaceAndStandardizesAnAbsoluteFolderPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuadFinderPath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try EnteredFolderPath.resolve("  \n\(root.path)/./  \t")

        #expect(resolved == root.standardizedFileURL)
    }

    @Test func expandsTildeToTheHomeFolder() throws {
        let resolved = try EnteredFolderPath.resolve("~")
        #expect(resolved == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    @Test func rejectsEmptyRelativeMissingAndFilePaths() throws {
        #expect(throws: EnteredFolderPathError.empty) { try EnteredFolderPath.resolve(" \n ") }
        #expect(throws: EnteredFolderPathError.notAbsolute) { try EnteredFolderPath.resolve("Documents") }
        #expect(throws: EnteredFolderPathError.notFound) {
            try EnteredFolderPath.resolve("/tmp/QuadFinder-missing-\(UUID().uuidString)")
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuadFinderPathFile-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: EnteredFolderPathError.notDirectory) { try EnteredFolderPath.resolve(file.path) }
    }

    @Test func invalidEntryKeepsTheCurrentPaneAndHistoryUnchanged() {
        let store = makeStore()
        let paneID = store.state.activePaneID
        let before = store.pane(id: paneID)!

        let succeeded = store.navigateToEnteredFolder(
            paneID: paneID,
            path: "/tmp/QuadFinder-missing-\(UUID().uuidString)"
        )

        #expect(!succeeded)
        #expect(store.pane(id: paneID)?.currentURL == before.currentURL)
        #expect(store.pane(id: paneID)?.backwardHistory == before.backwardHistory)
        #expect(store.pane(id: paneID)?.forwardHistory == before.forwardHistory)
        #expect(store.error?.title == L10n.tr("フォルダを開けません"))
    }

    @Test func validEntryNavigatesOnlyTheRequestedPaneAndCreatesBackHistory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuadFinderDestination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = makeStore()
        let firstPane = store.state.activePaneID
        store.addPane()
        let secondPane = store.state.activePaneID
        let secondBefore = store.pane(id: secondPane)?.currentURL

        let succeeded = store.navigateToEnteredFolder(paneID: firstPane, path: folder.path)

        #expect(succeeded)
        #expect(store.pane(id: firstPane)?.currentURL == folder.standardizedFileURL)
        #expect(store.pane(id: firstPane)?.backwardHistory.count == 1)
        #expect(store.pane(id: secondPane)?.currentURL == secondBefore)
    }
}
