import Foundation
import Testing
@testable import QuadFinder

@MainActor
struct PaneLinkTests {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
    }

    @Test func linkGroupNormalizesWhenLinkedPaneDisappears() {
        let store = makeStore()
        let first = store.state.activePaneID
        store.addPane()
        let second = store.state.activePaneID
        store.setPaneLinkGroup([first, second], followsNavigation: true, followsSelection: true)
        #expect(store.state.paneLinkGroup?.paneIDs == [first, second])

        store.closePane(second)
        #expect(store.state.paneLinkGroup == nil)
    }

    @Test func relativeNavigationSucceedsWithoutInfinitePropagation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right.appendingPathComponent("shared"), withIntermediateDirectories: true)
        let store = makeStore()
        let leftID = store.state.activePaneID
        store.navigate(paneID: leftID, to: left)
        store.addPane()
        let rightID = store.state.activePaneID
        store.navigate(paneID: rightID, to: right)
        store.setPaneLinkGroup([leftID, rightID], followsNavigation: true, followsSelection: false)

        store.navigate(paneID: leftID, to: left.appendingPathComponent("shared"))
        await store.waitForLinkPropagation()

        #expect(store.pane(id: rightID)?.currentURL == right.appendingPathComponent("shared"))
        #expect(store.pane(id: leftID)?.backwardHistory.count == 2)
        #expect(store.pane(id: rightID)?.backwardHistory.count == 2)
        #expect(store.paneNotifications[rightID] == nil)
    }

    @Test func missingRelativeChildDoesNotMoveTargetAndNotifies() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("only-left"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let store = makeStore()
        let leftID = store.state.activePaneID
        store.navigate(paneID: leftID, to: left)
        store.addPane()
        let rightID = store.state.activePaneID
        store.navigate(paneID: rightID, to: right)
        store.setPaneLinkGroup([leftID, rightID], followsNavigation: true, followsSelection: false)

        store.navigate(paneID: leftID, to: left.appendingPathComponent("only-left"))
        await store.waitForLinkPropagation()

        #expect(store.pane(id: rightID)?.currentURL == right)
        #expect(store.paneNotifications[rightID] != nil)
    }

    @Test func selectionFollowSelectsMatchingNamesAndMissingLeavesSelectionUntouched() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let leftFile = left.appendingPathComponent("same.txt")
        let rightFile = right.appendingPathComponent("same.txt")
        try Data("left".utf8).write(to: leftFile)
        try Data("right".utf8).write(to: rightFile)
        let store = makeStore()
        let leftID = store.state.activePaneID
        store.navigate(paneID: leftID, to: left)
        store.addPane()
        let rightID = store.state.activePaneID
        store.navigate(paneID: rightID, to: right)
        store.setPaneLinkGroup([leftID, rightID], followsNavigation: false, followsSelection: true)

        store.setSelection([leftFile], in: leftID)
        await store.waitForLinkPropagation()
        #expect(store.pane(id: rightID)?.selectedURLs == [rightFile])

        let missing = left.appendingPathComponent("missing.txt")
        store.setSelection([missing], in: leftID)
        await store.waitForLinkPropagation()
        #expect(store.pane(id: rightID)?.selectedURLs == [rightFile])
        #expect(store.paneNotifications[rightID] != nil)
    }
}

struct ComparisonServiceTests {
    private func makeDirectories() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (base, source, target)
    }

    @Test func comparisonUsesFixedURLsAndProducesAllNormalClassifications() async throws {
        let (base, source, target) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ text: String, _ url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        }
        try write("equal", source.appendingPathComponent("equal.txt"))
        try write("equal", target.appendingPathComponent("equal.txt"))
        try write("source", source.appendingPathComponent("different.txt"))
        try write("target-long", target.appendingPathComponent("different.txt"))
        try write("source", source.appendingPathComponent("only-source.txt"))
        try write("target", target.appendingPathComponent("only-target.txt"))
        let request = ComparisonRequest(
            sourcePaneID: UUID(), targetPaneID: UUID(), sourceURL: source, targetURL: target,
            sourceBookmark: nil, targetBookmark: nil, usesChecksums: false
        )

        let result = try await FolderComparisonService().compare(request) { _ in }
        let classified = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.name, $0.classification) })

        #expect(result.sourceURL == source)
        #expect(result.targetURL == target)
        #expect(classified["equal.txt"] == .equal)
        #expect(classified["different.txt"] == .different)
        #expect(classified["only-source.txt"] == .onlySource)
        #expect(classified["only-target.txt"] == .onlyTarget)
        #expect(ComparisonClassifier.classify(source: nil, target: nil, cloudError: "offline").0 == .error)
    }

    @Test func checksumFindsSameMetadataDifferentContent() async throws {
        let (base, source, target) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: base) }
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let sourceFile = source.appendingPathComponent("same-size.txt")
        let targetFile = target.appendingPathComponent("same-size.txt")
        try Data("AAAA".utf8).write(to: sourceFile)
        try Data("BBBB".utf8).write(to: targetFile)
        for file in [sourceFile, targetFile] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        let baseRequest = ComparisonRequest(
            sourcePaneID: UUID(), targetPaneID: UUID(), sourceURL: source, targetURL: target,
            sourceBookmark: nil, targetBookmark: nil, usesChecksums: false
        )
        let metadataOnly = try await FolderComparisonService().compare(baseRequest) { _ in }
        let checksumRequest = ComparisonRequest(
            sourcePaneID: baseRequest.sourcePaneID, targetPaneID: baseRequest.targetPaneID,
            sourceURL: source, targetURL: target, sourceBookmark: nil, targetBookmark: nil, usesChecksums: true
        )
        let checksummed = try await FolderComparisonService().compare(checksumRequest) { _ in }

        #expect(metadataOnly.entries[0].classification == .equal)
        #expect(checksummed.entries[0].classification == .different)
        #expect(checksummed.entries[0].source?.checksum != checksummed.entries[0].target?.checksum)
    }

    @Test func cancelledComparisonThrowsCancellation() async throws {
        let (base, source, target) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(repeating: 7, count: 4_000_000).write(to: source.appendingPathComponent("large.bin"))
        try Data(repeating: 7, count: 4_000_000).write(to: target.appendingPathComponent("large.bin"))
        let request = ComparisonRequest(
            sourcePaneID: UUID(), targetPaneID: UUID(), sourceURL: source, targetURL: target,
            sourceBookmark: nil, targetBookmark: nil, usesChecksums: true
        )
        let task = Task { try await FolderComparisonService().compare(request) { _ in } }
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        #expect(cancelled)
    }
}

struct SyncSafetyTests {
    private func fingerprint(_ name: String, date: Date, size: Int64 = 1) -> DirectoryEntryFingerprint {
        DirectoryEntryFingerprint(name: name, isDirectory: false, size: size, modificationDate: date, checksum: nil, cloudStatus: nil)
    }

    private func comparisonFixture() -> FolderComparisonResult {
        let sourceURL = URL(fileURLWithPath: "/tmp/sync-source")
        let targetURL = URL(fileURLWithPath: "/tmp/sync-target")
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let onlySource = fingerprint("create.txt", date: new)
        let onlyTarget = fingerprint("delete.txt", date: old)
        let newer = fingerprint("update.txt", date: new, size: 2)
        let older = fingerprint("update.txt", date: old, size: 1)
        return FolderComparisonResult(
            sourcePaneID: UUID(), targetPaneID: UUID(), sourceURL: sourceURL, targetURL: targetURL,
            sourceBookmark: nil, targetBookmark: nil, usesChecksums: false,
            sourceSnapshot: DirectorySnapshot(directoryURL: sourceURL, entries: ["create.txt": onlySource, "update.txt": newer]),
            targetSnapshot: DirectorySnapshot(directoryURL: targetURL, entries: ["delete.txt": onlyTarget, "update.txt": older]),
            entries: [
                ComparisonEntry(name: "create.txt", source: onlySource, target: nil, classification: .onlySource, message: nil),
                ComparisonEntry(name: "delete.txt", source: nil, target: onlyTarget, classification: .onlyTarget, message: nil),
                ComparisonEntry(name: "update.txt", source: newer, target: older, classification: .different, message: nil)
            ]
        )
    }

    @Test func previewModesProduceExpectedCreateOverwriteDeleteActions() {
        let result = comparisonFixture()
        let missing = SyncPreviewBuilder.make(from: result, mode: .missingOnly, allowsOverwrite: false, allowsDelete: false)
        let update = SyncPreviewBuilder.make(from: result, mode: .oneWayUpdate, allowsOverwrite: true, allowsDelete: false)
        let mirror = SyncPreviewBuilder.make(from: result, mode: .oneWayMirror, allowsOverwrite: true, allowsDelete: true)

        #expect(missing.actions.map(\.kind) == [.create])
        #expect(update.actions.map(\.kind) == [.create, .overwrite])
        #expect(mirror.createCount == 1)
        #expect(mirror.overwriteCount == 1)
        #expect(mirror.deleteCount == 1)
    }

    @Test func safetyFlagsSecondConfirmationAndStaleSnapshotAreRejected() throws {
        let result = comparisonFixture()
        let mirror = SyncPreviewBuilder.make(from: result, mode: .oneWayMirror, allowsOverwrite: false, allowsDelete: false)
        var secondStage = SyncExecutionPlan(
            mode: mirror.mode, sourceSnapshot: mirror.sourceSnapshot, targetSnapshot: mirror.targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil, actions: mirror.actions,
            allowsOverwrite: false, allowsDelete: false, confirmationStage: 2
        )
        #expect(throws: SyncSafetyError.overwriteNotEnabled) {
            try SyncSafetyValidator.validate(secondStage, currentSource: mirror.sourceSnapshot, currentTarget: mirror.targetSnapshot)
        }
        let deleteOnly = SyncExecutionPlan(
            mode: .oneWayMirror, sourceSnapshot: mirror.sourceSnapshot, targetSnapshot: mirror.targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil,
            actions: mirror.actions.filter { $0.kind == .delete },
            allowsOverwrite: false, allowsDelete: false, confirmationStage: 2
        )
        #expect(throws: SyncSafetyError.deleteNotEnabled) {
            try SyncSafetyValidator.validate(deleteOnly, currentSource: mirror.sourceSnapshot, currentTarget: mirror.targetSnapshot)
        }
        secondStage = SyncExecutionPlan(
            mode: .missingOnly, sourceSnapshot: mirror.sourceSnapshot, targetSnapshot: mirror.targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil, actions: [],
            allowsOverwrite: false, allowsDelete: false, confirmationStage: 1
        )
        #expect(throws: SyncSafetyError.secondConfirmationRequired) {
            try SyncSafetyValidator.validate(secondStage, currentSource: mirror.sourceSnapshot, currentTarget: mirror.targetSnapshot)
        }
        let confirmedEmpty = SyncExecutionPlan(
            mode: .missingOnly, sourceSnapshot: mirror.sourceSnapshot, targetSnapshot: mirror.targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil, actions: [],
            allowsOverwrite: false, allowsDelete: false, confirmationStage: 2
        )
        let changed = DirectorySnapshot(directoryURL: mirror.targetSnapshot.directoryURL, entries: [:])
        #expect(throws: SyncSafetyError.staleSnapshot) {
            try SyncSafetyValidator.validate(confirmedEmpty, currentSource: mirror.sourceSnapshot, currentTarget: changed)
        }
    }

    @MainActor
    @Test func synchronizationCannotBeConfirmedWithoutPreview() {
        let controller = ComparisonController()
        #expect(throws: SyncSafetyError.previewRequired) { try controller.confirmedPlan() }
    }

    @MainActor
    @Test func createOnlySyncRunsThroughSharedQueue() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("create.txt")
        try Data("sync".utf8).write(to: sourceFile)
        let sourceSnapshot = try await FileSystemService.snapshot(source, usesChecksum: false)
        let targetSnapshot = try await FileSystemService.snapshot(target, usesChecksum: false)
        let plan = SyncExecutionPlan(
            mode: .missingOnly, sourceSnapshot: sourceSnapshot, targetSnapshot: targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil,
            actions: [SyncAction(kind: .create, sourceURL: sourceFile, targetURL: target.appendingPathComponent("create.txt"))],
            allowsOverwrite: false, allowsDelete: false, confirmationStage: 2
        )
        let queue = FileOperationQueue()
        queue.enqueue(PendingFileOperation(
            kind: .sync, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [sourceFile],
            targetDirectoryURL: target, syncPlan: plan
        ))
        await queue.waitUntilIdle()

        #expect(queue.jobs[0].status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("create.txt").path))

        let staleQueue = FileOperationQueue()
        staleQueue.enqueue(PendingFileOperation(
            kind: .sync, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [sourceFile],
            targetDirectoryURL: target, syncPlan: plan
        ))
        await staleQueue.waitUntilIdle()
        #expect(staleQueue.jobs[0].status == .failed)
        #expect(staleQueue.jobs[0].errorMessage?.contains("再比較") == true)
    }

    @MainActor
    @Test func syncCreateOverwriteDeleteOutcomeUndoesInReverseOrder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let createSource = source.appendingPathComponent("create")
        let replaceSource = source.appendingPathComponent("replace")
        let replaceTarget = target.appendingPathComponent("replace")
        let deleteTarget = target.appendingPathComponent("delete")
        try Data("create".utf8).write(to: createSource)
        try Data("new".utf8).write(to: replaceSource)
        try Data("old".utf8).write(to: replaceTarget)
        try Data("delete".utf8).write(to: deleteTarget)
        let sourceSnapshot = try await FileSystemService.snapshot(source, usesChecksum: false)
        let targetSnapshot = try await FileSystemService.snapshot(target, usesChecksum: false)
        let plan = SyncExecutionPlan(mode: .oneWayMirror, sourceSnapshot: sourceSnapshot, targetSnapshot: targetSnapshot,
            sourceBookmark: nil, targetBookmark: nil, actions: [
                .init(kind: .create, sourceURL: createSource, targetURL: target.appendingPathComponent("create")),
                .init(kind: .overwrite, sourceURL: replaceSource, targetURL: replaceTarget),
                .init(kind: .delete, sourceURL: nil, targetURL: deleteTarget)],
            allowsOverwrite: true, allowsDelete: true, confirmationStage: 2)
        let operation = PendingFileOperation(kind: .sync, sourcePaneID: nil, targetPaneID: UUID(),
            sourceURLs: [createSource, replaceSource], targetDirectoryURL: target, syncPlan: plan)
        let outcome = try await FileSystemService().perform(operation) { _ in }
        #expect(outcome.historySteps.count == 3)
        let store = OperationHistoryStore(fileURL: base.appendingPathComponent("journal"))
        store.record(.init(kind: .sync, summary: "sync", steps: outcome.historySteps, itemCount: 3))
        try store.undo()
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("create").path))
        #expect(try String(contentsOf: replaceTarget, encoding: .utf8) == "old")
        #expect(try String(contentsOf: deleteTarget, encoding: .utf8) == "delete")
        try store.redo()
        #expect(try String(contentsOf: replaceTarget, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: deleteTarget.path))
    }
}

private actor CacheLoadCounter {
    private var loads = 0
    func load() async throws -> [FileItem] {
        loads += 1
        try await Task.sleep(for: .milliseconds(50))
        return []
    }
    func count() -> Int { loads }
}

private actor CloudChecksumCounter {
    private var reads = 0
    func read() -> String { reads += 1; return "digest" }
    func count() -> Int { reads }
}

struct DirectoryCacheTests {
    @Test func inFlightLoadIsDeduplicatedAndConsumerCancellationDoesNotCancelOthers() async throws {
        let cache = DirectoryListingCache()
        let counter = CacheLoadCounter()
        let key = DirectoryListingKey(url: URL(fileURLWithPath: "/tmp/cache-test"), showsHiddenFiles: false)
        let first = Task { try await cache.entries(for: key) { try await counter.load() } }
        try await Task.sleep(for: .milliseconds(5))
        let second = Task { try await cache.entries(for: key) { try await counter.load() } }
        first.cancel()
        _ = try? await first.value
        _ = try await second.value

        #expect(await counter.count() == 1)
    }

    @Test func bypassAndTTLProduceFreshListingsWithoutOldGenerationOverwrite() async throws {
        let cache = DirectoryListingCache(ttl: 0.03)
        let key = DirectoryListingKey(url: URL(fileURLWithPath: "/tmp/cache-fresh"), showsHiddenFiles: false)
        let counter = CacheLoadCounter()

        _ = try await cache.entries(for: key) { try await counter.load() }
        _ = try await cache.entries(for: key) { try await counter.load() }
        #expect(await counter.count() == 1)

        _ = try await cache.entries(for: key, bypassCache: true) { try await counter.load() }
        #expect(await counter.count() == 2)

        try await Task.sleep(for: .milliseconds(40))
        _ = try await cache.entries(for: key) { try await counter.load() }
        #expect(await counter.count() == 3)

        await cache.invalidate(url: key.url)
        _ = try await cache.entries(for: key) { try await counter.load() }
        #expect(await counter.count() == 4)
    }

    @Test func freshReloadSupersedesNormalInFlightForCachedGeneration() async throws {
        let cache = DirectoryListingCache(ttl: 10)
        let key = DirectoryListingKey(url: URL(fileURLWithPath: "/tmp/cache-generation"), showsHiddenFiles: false)
        let item: @Sendable (String) -> FileItem = { name in
            FileItem(
                url: key.url.appendingPathComponent(name), isDirectory: false, size: 1,
                modificationDate: nil, isUbiquitous: false, cloudDownloadStatus: nil
            )
        }
        let old = Task {
            try await cache.entries(for: key) {
                try await Task.sleep(for: .milliseconds(80))
                return [item("old")]
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        let fresh = try await cache.entries(for: key, bypassCache: true) { [item("fresh")] }
        _ = try await old.value
        let cached = try await cache.entries(for: key) { [item("unexpected") ] }

        #expect(fresh.first?.name == "fresh")
        #expect(cached.first?.name == "fresh")
    }

    @Test func unavailableCloudItemNeverInvokesChecksumReader() async throws {
        let counter = CloudChecksumCounter()
        let checksum = try await CloudChecksumPolicy.checksumIfAvailable(
            isDirectory: false,
            isUbiquitous: true,
            downloadStatus: URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue
        ) { await counter.read() }

        #expect(checksum == nil)
        #expect(await counter.count() == 0)
    }

    @Test func comparisonProgressIsCoalescedAndAlwaysEndsAtOne() {
        let coalescer = ComparisonProgressCoalescer(total: 1_000, stride: 100)
        let emitted = (1...1_000).compactMap { coalescer.progress(after: $0) }

        #expect(emitted.count == 10)
        #expect(emitted.last == 1.0)
        #expect(ComparisonProgressCoalescer(total: 0).progress(after: 0) == 1.0)
    }
}

@MainActor
struct Phase3StateMigrationTests {
    @Test func migratesV2StateToV3DefaultsAndNormalizesPair() throws {
        let state = WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp"))
        let encoded = try JSONEncoder().encode(state)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 2
        object.removeValue(forKey: "paneLinkGroup")
        if var modules = object["moduleSettings"] as? [String: Any] {
            modules.removeValue(forKey: "comparison")
            object["moduleSettings"] = modules
        }
        let v2Data = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(WorkspaceState.self, from: v2Data)

        #expect(migrated.version == 3)
        #expect(migrated.paneLinkGroup == nil)
        #expect(migrated.moduleSettings.comparison.context == .active)
        #expect(!migrated.moduleSettings.comparison.isVisible)
    }

    @Test func pairContextPersistsAndInvalidPairNormalizes() {
        let store = WorkspaceStore(persistence: MemoryWorkspacePersistence(storage: .init()))
        store.addPane()
        let target = store.state.activePaneID
        store.activatePane(number: 1)
        store.setComparisonTarget(target)
        #expect(store.comparisonPair?.1 == target)
        store.closePane(target)
        #expect(store.state.moduleSettings.comparison.context == .active)
    }

    @Test func linkAndPairContextsRoundTripInV3JSON() throws {
        var state = WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp/one"))
        let second = PaneState(currentURL: URL(fileURLWithPath: "/tmp/two"))
        state.panes.append(second)
        state.slots[.topRight] = second.id
        state.layout = .vertical
        state.paneLinkGroup = PaneLinkGroup(
            paneIDs: [state.activePaneID, second.id],
            followsRelativeNavigation: true,
            followsSelection: false
        )
        state.moduleSettings.comparison.context = .pair(state.activePaneID, second.id)

        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))

        #expect(restored.paneLinkGroup == state.paneLinkGroup)
        #expect(restored.moduleSettings.comparison.context == state.moduleSettings.comparison.context)
        #expect(restored.version == 3)
    }

    @Test func productUsesSingleWindowScopePolicy() {
        #expect(WorkspaceStore.windowScopePolicy == .singleWindow)
    }
}
