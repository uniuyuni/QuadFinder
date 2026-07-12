import Foundation
import Testing
@testable import QuadFinder

private actor PartialHistoryOperator: FileOperating {
    let outcome: OperationOutcome
    init(outcome: OperationOutcome) { self.outcome = outcome }
    func perform(_ operation: PendingFileOperation) async throws {
        throw PartialOperationFailure(outcome: outcome, underlying: CocoaError(.fileWriteUnknown))
    }
    func perform(_ operation: PendingFileOperation,
                 progress: @escaping @Sendable (FileOperationProgress) -> Void) async throws -> OperationOutcome {
        throw PartialOperationFailure(outcome: outcome, underlying: CocoaError(.fileWriteUnknown))
    }
}

private actor StoppableHistoryOperator: FileOperating {
    let outcome: OperationOutcome
    init(outcome: OperationOutcome) { self.outcome = outcome }
    func perform(_ operation: PendingFileOperation) async throws { _ = try await perform(operation, progress: { _ in }) }
    func perform(_ operation: PendingFileOperation,
                 progress: @escaping @Sendable (FileOperationProgress) -> Void) async throws -> OperationOutcome {
        do {
            while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            throw PartialOperationFailure(outcome: outcome, underlying: error)
        }
    }
}

@Suite("Operation history") @MainActor
struct OperationHistoryTests {
    @Test func persistenceBoundAndCorruptionIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        let store = OperationHistoryStore(fileURL: journal, limit: 2)
        for index in 0..<3 {
            store.record(.init(kind: .copy, summary: "\(index)", steps: [], itemCount: 1, undoable: false))
        }
        #expect(store.entries.map(\.summary) == ["1", "2"])
        #expect(OperationHistoryStore(fileURL: journal, limit: 2).entries.count == 2)
        try Data("broken".utf8).write(to: journal)
        #expect(OperationHistoryStore(fileURL: journal).entries.isEmpty)
    }

    @Test func undoRedoMoveValidatesConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("old")
        let renamed = root.appendingPathComponent("new")
        try Data([1]).write(to: renamed)
        let store = OperationHistoryStore(fileURL: root.appendingPathComponent("journal"))
        store.record(.init(kind: .rename, summary: "rename", steps: [.moved(from: original, to: renamed)], itemCount: 1))
        try store.undo()
        #expect(FileManager.default.fileExists(atPath: original.path))
        try store.redo()
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func largeConfirmationPolicy() {
        let items = OperationHistoryEntry(kind: .copy, summary: "large", steps: [], itemCount: 20)
        let bytes = OperationHistoryEntry(kind: .copy, summary: "large", steps: [], itemCount: 1, byteCount: 100_000_000)
        #expect(LargeHistoryOperationPolicy.requiresConfirmation(items))
        #expect(LargeHistoryOperationPolicy.requiresConfirmation(bytes))
    }

    @Test func copiedItemUndoRedoUsesFingerprints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try Data("payload".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: target)
        let store = OperationHistoryStore(fileURL: root.appendingPathComponent("journal"))
        store.record(.init(kind: .copy, summary: "copy", steps: [.copied(
            source: source, target: target, sourceFingerprint: HistoryFingerprint.capture(source)!,
            targetFingerprint: HistoryFingerprint.capture(target)!)], itemCount: 1))
        try store.undo()
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try store.redo()
        #expect(try String(contentsOf: target, encoding: .utf8) == "payload")
    }

    @Test func failedUndoDoesNotToggleJournalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("missing")
        try Data([1]).write(to: source)
        let store = OperationHistoryStore(fileURL: root.appendingPathComponent("journal"))
        let fake = HistoryFingerprint.capture(source)!
        store.record(.init(kind: .copy, summary: "copy", steps: [.copied(source: source, target: target,
            sourceFingerprint: fake, targetFingerprint: fake)], itemCount: 1))
        #expect(throws: HistoryError.self) { try store.undo() }
        #expect(store.entries.last?.isUndone == false)
    }

    @Test func partialFailureCommitsOnlySuccessfulSteps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data([1]).write(to: source); try Data([1]).write(to: target)
        let step = HistoryStep.copied(source: source, target: target,
            sourceFingerprint: HistoryFingerprint.capture(source)!, targetFingerprint: HistoryFingerprint.capture(target)!)
        let outcome = OperationOutcome(completedBytes: 1, completedItems: 1, resultingURLs: [target], historySteps: [step])
        let history = OperationHistoryStore(fileURL: root.appendingPathComponent("journal"))
        let queue = FileOperationQueue(fileSystem: PartialHistoryOperator(outcome: outcome), history: history)
        let id = queue.enqueue(.init(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(),
            sourceURLs: [source], targetDirectoryURL: root))
        await queue.waitUntilIdle()
        #expect(queue.job(id: id)?.status == .failed)
        #expect(history.entries.last?.steps == [step])
    }

    @Test func userStopIsDistinctAndCommitsCompletedStepsForUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data([1]).write(to: source); try Data([1]).write(to: target)
        let step = HistoryStep.copied(source: source, target: target,
            sourceFingerprint: HistoryFingerprint.capture(source)!, targetFingerprint: HistoryFingerprint.capture(target)!)
        let outcome = OperationOutcome(completedBytes: 1, completedItems: 1, resultingURLs: [target], historySteps: [step])
        let history = OperationHistoryStore(fileURL: root.appendingPathComponent("journal"))
        let queue = FileOperationQueue(fileSystem: StoppableHistoryOperator(outcome: outcome), history: history)
        let id = queue.enqueue(.init(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: root))
        while queue.job(id: id)?.status == .queued { await Task.yield() }
        queue.stop(id)
        await queue.waitUntilIdle()
        #expect(queue.job(id: id)?.status == .stopped)
        #expect(history.entries.last?.steps == [step])
        try history.undo()
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func stoppingQueuedJobDoesNotStopOtherJobs() async {
        let outcome = OperationOutcome(completedBytes: 0, completedItems: 0, resultingURLs: [])
        let queue = FileOperationQueue(fileSystem: StoppableHistoryOperator(outcome: outcome))
        let first = queue.enqueue(.init(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [URL(fileURLWithPath: "/tmp/a")], targetDirectoryURL: URL(fileURLWithPath: "/tmp")))
        let second = queue.enqueue(.init(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [URL(fileURLWithPath: "/tmp/b")], targetDirectoryURL: URL(fileURLWithPath: "/tmp")))
        queue.stop(second)
        queue.stop(first)
        await queue.waitUntilIdle()
        #expect(queue.job(id: first)?.status == .stopped)
        #expect(queue.job(id: second)?.status == .stopped)
    }
}
