import Foundation
import Testing
@testable import QuadFinder

private enum TransferQueueStubError: Error { case failed }

private actor TransferQueueStub: FileOperating {
    let fails: Bool
    init(fails: Bool) { self.fails = fails }
    func perform(_ operation: PendingFileOperation) async throws {
        if fails { throw TransferQueueStubError.failed }
    }
}

private actor SlowTransferQueueStub: FileOperating {
    func perform(_ operation: PendingFileOperation) async throws {
        try await Task.sleep(for: .milliseconds(30))
    }
}

struct TransferPlanTests {
    private func fixture() throws -> (base: URL, source: URL, target: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (base, source, target)
    }

    private func request(kind: FileOperationKind, source: URL, target: URL, names: [String]) -> TransferPlanRequest {
        TransferPlanRequest(
            kind: kind,
            sourceURLs: names.map { source.appendingPathComponent($0) },
            targetDirectoryURL: target,
            sourceAccessBookmark: nil,
            targetAccessBookmark: nil
        )
    }

    @Test func allPoliciesMakeConflictsExplicit() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let sourceFile = value.source.appendingPathComponent("same.txt")
        let targetFile = value.target.appendingPathComponent("same.txt")
        try Data("source-new".utf8).write(to: sourceFile)
        try Data("target".utf8).write(to: targetFile)
        let newer = Date(timeIntervalSince1970: 300)
        let older = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: targetFile.path)
        let request = request(kind: .copy, source: value.source, target: value.target, names: ["same.txt"])
        let planner = TransferPlanningService()

        let missing = try await planner.makePlan(request, policy: .missingOnly)
        let newerPlan = try await planner.makePlan(request, policy: .newerOnly)
        let replace = try await planner.makePlan(request, policy: .replace)

        #expect(missing.actions.map(\.kind) == [.skip])
        #expect(missing.selectedActions.isEmpty)
        #expect(newerPlan.actions.map(\.kind) == [.replace])
        #expect(replace.actions.map(\.kind) == [.replace])
        #expect(replace.hasDestructiveActions)
    }

    @Test func autoRenamePreviewsFinderStyleAvailableName() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        try Data("source".utf8).write(to: value.source.appendingPathComponent("same.txt"))
        try Data("existing".utf8).write(to: value.target.appendingPathComponent("same.txt"))
        try Data("existing-copy".utf8).write(to: value.target.appendingPathComponent("same copy.txt"))

        let plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["same.txt"]),
            policy: .autoRename
        )

        #expect(plan.selectedActions.count == 1)
        #expect(plan.selectedActions.first?.kind == .autoRename)
        #expect(plan.selectedActions.first?.targetURL.lastPathComponent == "same copy 2.txt")
        #expect(plan.selectedActions.first?.targetFingerprint == nil)
        #expect(!plan.hasDestructiveActions)
    }

    @Test @MainActor func autoRenameCopyAndMoveProduceUndoableOutcomes() async throws {
        for kind in [FileOperationKind.copy, .move] {
            let value = try fixture()
            defer { try? FileManager.default.removeItem(at: value.base) }
            let source = value.source.appendingPathComponent("same.txt")
            let existing = value.target.appendingPathComponent("same.txt")
            try Data("source".utf8).write(to: source)
            try Data("existing".utf8).write(to: existing)
            var plan = try await TransferPlanningService().makePlan(
                request(kind: kind, source: value.source, target: value.target, names: ["same.txt"]),
                policy: .autoRename
            )
            plan.confirmationStage = 2
            let renamed = try #require(plan.selectedActions.first?.targetURL)
            let outcome = try await TransferExecutionService().execute(plan, allowsOverwrite: false, allowsDelete: false)
            #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
            #expect(try String(contentsOf: renamed, encoding: .utf8) == "source")
            let store = OperationHistoryStore(fileURL: value.base.appendingPathComponent("journal"))
            store.record(OperationHistoryEntry(kind: .transfer, summary: "auto rename", steps: outcome.historySteps, itemCount: 1))
            try store.undo()
            #expect(!FileManager.default.fileExists(atPath: renamed.path))
            #expect(FileManager.default.fileExists(atPath: source.path))
            try store.redo()
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            #expect(kind == .copy || !FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func autoRenameAdvancesPastRacingDestinationWithoutOverwrite() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        try Data("source".utf8).write(to: value.source.appendingPathComponent("same.txt"))
        try Data("existing".utf8).write(to: value.target.appendingPathComponent("same.txt"))
        var plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["same.txt"]), policy: .autoRename
        )
        plan.confirmationStage = 2
        let previewed = try #require(plan.selectedActions.first?.targetURL)
        try Data("racer".utf8).write(to: previewed)

        let outcome = try await TransferExecutionService().execute(plan, allowsOverwrite: false, allowsDelete: false)
        #expect(try String(contentsOf: previewed, encoding: .utf8) == "racer")
        let actual = try #require(outcome.resultingURLs.first)
        #expect(actual != previewed)
        #expect(try String(contentsOf: actual, encoding: .utf8) == "source")
    }

    @Test func synchronizationPreviewsTargetOnlyItemsAsTrashNotSilentDeletion() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let sourceFolder = value.source.appendingPathComponent("folder")
        let targetFolder = value.target.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: sourceFolder.appendingPathComponent("new.txt"))
        try Data("extra".utf8).write(to: targetFolder.appendingPathComponent("extra.txt"))

        let plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["folder"]),
            policy: .synchronize
        )

        #expect(plan.actions.contains { $0.kind == .copy && $0.targetURL.lastPathComponent == "new.txt" })
        #expect(plan.actions.contains { $0.kind == .trashTarget && $0.targetURL.lastPathComponent == "extra.txt" })
        #expect(plan.hasDestructiveActions)
    }

    @Test func staleSourceOrTargetIsRejectedBeforeMutation() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let sourceFile = value.source.appendingPathComponent("item.txt")
        try Data("first".utf8).write(to: sourceFile)
        var plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["item.txt"]),
            policy: .missingOnly
        )
        plan.confirmationStage = 2
        try Data("changed-size".utf8).write(to: sourceFile)

        await #expect(throws: TransferPlanError.stalePlan) {
            try await TransferExecutionService().execute(plan, allowsOverwrite: true, allowsDelete: true)
        }
        #expect(!FileManager.default.fileExists(atPath: value.target.appendingPathComponent("item.txt").path))
    }

    @Test func overwriteAndDeletionRequireExplicitSecondStageFlags() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        try Data("source".utf8).write(to: value.source.appendingPathComponent("item.txt"))
        try Data("target".utf8).write(to: value.target.appendingPathComponent("item.txt"))
        var plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["item.txt"]),
            policy: .replace
        )

        #expect(throws: TransferPlanError.confirmationRequired) {
            try TransferExecutionService.validate(plan, allowsOverwrite: true, allowsDelete: true)
        }
        plan.confirmationStage = 2
        #expect(throws: TransferPlanError.overwriteNotConfirmed) {
            try TransferExecutionService.validate(plan, allowsOverwrite: false, allowsDelete: true)
        }
    }

    @Test func moveDeletesSourceOnlyAfterSuccessfulDestinationCreation() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let sourceFile = value.source.appendingPathComponent("move.txt")
        let targetFile = value.target.appendingPathComponent("move.txt")
        try Data("payload".utf8).write(to: sourceFile)
        var plan = try await TransferPlanningService().makePlan(
            request(kind: .move, source: value.source, target: value.target, names: ["move.txt"]),
            policy: .missingOnly
        )
        #expect(plan.sourceDeleteCount == 1)
        plan.confirmationStage = 2

        _ = try await TransferExecutionService().execute(plan, allowsOverwrite: true, allowsDelete: true)

        #expect(!FileManager.default.fileExists(atPath: sourceFile.path))
        #expect(try Data(contentsOf: targetFile) == Data("payload".utf8))
    }

    @Test func mergeDirectoryChangeMakesConfirmedPlanStale() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let sourceFolder = value.source.appendingPathComponent("folder")
        let targetFolder = value.target.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        var plan = try await TransferPlanningService().makePlan(
            request(kind: .copy, source: value.source, target: value.target, names: ["folder"]),
            policy: .missingOnly
        )
        plan.confirmationStage = 2
        try Data("late".utf8).write(to: sourceFolder.appendingPathComponent("added-after-preview"))
        await #expect(throws: TransferPlanError.stalePlan) {
            try await TransferExecutionService().execute(plan, allowsOverwrite: true, allowsDelete: true)
        }
    }

    @Test func selfCopyAndFolderIntoDescendantAreRejected() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.base) }
        let file = value.source.appendingPathComponent("same.txt")
        try Data().write(to: file)
        await #expect(throws: TransferPlanError.selfCopy(file)) {
            _ = try await TransferPlanningService().makePlan(
                request(kind: .copy, source: value.source, target: value.source, names: ["same.txt"]),
                policy: .replace
            )
        }

        let folder = value.source.appendingPathComponent("folder")
        let descendant = folder.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        do {
            _ = try await TransferPlanningService().makePlan(
                TransferPlanRequest(
                    kind: .copy, sourceURLs: [folder], targetDirectoryURL: descendant,
                    sourceAccessBookmark: nil, targetAccessBookmark: nil
                ),
                policy: .missingOnly
            )
            Issue.record("フォルダ内部へのコピーが拒否されませんでした")
        } catch let error as TransferPlanError {
            guard case .sourceInsideDestination = error else {
                Issue.record("想定外のエラー: \(error)")
                return
            }
        }
    }
}

@MainActor
struct TransferQueueIntegrationTests {
    private func operation(receipt: ClipboardCutReceipt?) -> PendingFileOperation {
        PendingFileOperation(
            kind: .move,
            sourcePaneID: nil,
            targetPaneID: UUID(),
            sourceURLs: [URL(fileURLWithPath: "/tmp/cut-source")],
            targetDirectoryURL: URL(fileURLWithPath: "/tmp/cut-target"),
            clipboardCutReceipt: receipt
        )
    }

    @Test func successfulQueuedMoveClearsMatchingCutReceiptOnlyAfterSuccess() async {
        let receipt = ClipboardCutReceipt(
            changeCount: 10, sessionToken: "session",
            sourceURLs: [URL(fileURLWithPath: "/tmp/cut-source")]
        )
        var cleared: [ClipboardCutReceipt] = []
        let queue = FileOperationQueue(fileSystem: TransferQueueStub(fails: false)) { cleared.append($0) }
        let id = queue.enqueue(operation(receipt: receipt))

        #expect(cleared.isEmpty)
        await queue.waitUntilIdle()

        #expect(queue.job(id: id)?.status == .succeeded)
        #expect(cleared == [receipt])
    }

    @Test func failedQueuedMoveRetainsCutReceipt() async {
        let receipt = ClipboardCutReceipt(
            changeCount: 11, sessionToken: "session",
            sourceURLs: [URL(fileURLWithPath: "/tmp/cut-source")]
        )
        var cleared: [ClipboardCutReceipt] = []
        let queue = FileOperationQueue(fileSystem: TransferQueueStub(fails: true)) { cleared.append($0) }
        let id = queue.enqueue(operation(receipt: receipt))
        await queue.waitUntilIdle()

        #expect(queue.job(id: id)?.status == .failed)
        #expect(cleared.isEmpty)
    }

    @Test func successfulMoveDoesNotClearReceiptForDifferentSourceURLs() async {
        let receipt = ClipboardCutReceipt(
            changeCount: 13, sessionToken: "session",
            sourceURLs: [URL(fileURLWithPath: "/tmp/a-different-source")]
        )
        var cleared: [ClipboardCutReceipt] = []
        let queue = FileOperationQueue(fileSystem: TransferQueueStub(fails: false)) { cleared.append($0) }
        let id = queue.enqueue(operation(receipt: receipt))
        await queue.waitUntilIdle()

        #expect(queue.job(id: id)?.status == .succeeded)
        #expect(cleared.isEmpty)
    }

    @Test func successfulPartialMoveRetainsReceiptWhileAnySourceStillExists() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("still-here".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let receipt = ClipboardCutReceipt(changeCount: 14, sessionToken: "session", sourceURLs: [source.standardizedFileURL])
        var cleared: [ClipboardCutReceipt] = []
        let queue = FileOperationQueue(fileSystem: TransferQueueStub(fails: false)) { cleared.append($0) }
        _ = queue.enqueue(PendingFileOperation(
            kind: .move, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [source],
            targetDirectoryURL: URL(fileURLWithPath: "/tmp"), clipboardCutReceipt: receipt
        ))
        await queue.waitUntilIdle()
        #expect(cleared.isEmpty)
    }

    @Test func cancelledQueuedMoveRetainsCutReceipt() async {
        let receipt = ClipboardCutReceipt(
            changeCount: 12, sessionToken: "session",
            sourceURLs: [URL(fileURLWithPath: "/tmp/cut-source")]
        )
        var cleared: [ClipboardCutReceipt] = []
        let queue = FileOperationQueue(fileSystem: SlowTransferQueueStub()) { cleared.append($0) }
        _ = queue.enqueue(operation(receipt: nil))
        let cancelledID = queue.enqueue(operation(receipt: receipt))
        queue.cancel(cancelledID)
        await queue.waitUntilIdle()

        #expect(queue.job(id: cancelledID)?.status == .cancelled)
        #expect(cleared.isEmpty)
    }

    @Test func confirmedTransferPlanExecutesThroughWindowQueue() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let sourceDirectory = base.appendingPathComponent("source")
        let targetDirectory = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("queued.txt")
        try Data("queued".utf8).write(to: source)
        let request = TransferPlanRequest(
            kind: .copy, sourceURLs: [source], targetDirectoryURL: targetDirectory,
            sourceAccessBookmark: nil, targetAccessBookmark: nil
        )
        var plan = try await TransferPlanningService().makePlan(request, policy: .missingOnly)
        plan.confirmationStage = 2
        let queue = FileOperationQueue(fileSystem: FileSystemService())
        let id = queue.enqueue(PendingFileOperation(
            kind: .copy, sourcePaneID: nil, targetPaneID: UUID(), sourceURLs: [source],
            targetDirectoryURL: targetDirectory, transferPlan: plan
        ))

        await queue.waitUntilIdle()

        #expect(queue.job(id: id)?.status == .succeeded)
        #expect(try String(contentsOf: targetDirectory.appendingPathComponent("queued.txt"), encoding: .utf8) == "queued")
    }

    @MainActor
    @Test func replaceOutcomeCanUndoAndRedo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = base.appendingPathComponent("source")
        let targetDirectory = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = sourceDirectory.appendingPathComponent("same.txt")
        let target = targetDirectory.appendingPathComponent("same.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)
        var plan = try await TransferPlanningService().makePlan(
            TransferPlanRequest(kind: .copy, sourceURLs: [source], targetDirectoryURL: targetDirectory,
                                sourceAccessBookmark: nil, targetAccessBookmark: nil), policy: .replace)
        plan.confirmationStage = 2
        let outcome = try await TransferExecutionService().execute(plan, allowsOverwrite: true, allowsDelete: true)
        #expect(outcome.historySteps.count == 1)
        let store = OperationHistoryStore(fileURL: base.appendingPathComponent("journal"))
        store.record(OperationHistoryEntry(kind: .transfer, summary: "replace", steps: outcome.historySteps, itemCount: 1))
        try store.undo()
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        try store.redo()
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test func clipboardReceiptRejectsChangeCountOrSourceChanges() {
        let clipboard = FinderClipboard.shared
        let first = URL(fileURLWithPath: "/tmp/quadfinder-cut-first")
        let second = URL(fileURLWithPath: "/tmp/quadfinder-cut-second")
        clipboard.write(urls: [first], cut: true)
        let receipt = clipboard.cutReceiptIfCurrent()
        #expect(receipt != nil)

        clipboard.write(urls: [second], cut: true)

        #expect(receipt.map { clipboard.clearCutMarker(ifMatches: $0) } == false)
        #expect(clipboard.read().isCut)
    }
}
