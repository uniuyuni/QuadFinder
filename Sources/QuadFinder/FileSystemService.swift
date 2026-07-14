import AppKit
import Darwin
import Foundation

struct FileCloneStrategy: @unchecked Sendable {
    var canClone: @Sendable (URL, URL) -> Bool
    var clone: @Sendable (URL, URL) -> Bool

    static let system = FileCloneStrategy(canClone: { source, destination in
        guard let sourceValues = try? source.resourceValues(forKeys: [.volumeIdentifierKey, .volumeSupportsFileCloningKey]),
              let destinationValues = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey, .volumeSupportsFileCloningKey]),
              sourceValues.volumeIdentifier != nil,
              String(describing: sourceValues.volumeIdentifier) == String(describing: destinationValues.volumeIdentifier) else { return false }
        return sourceValues.volumeSupportsFileCloning == true && destinationValues.volumeSupportsFileCloning == true
    }, clone: { source, destination in
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        if result == 0 { return true }
        // A failed implementation is not allowed to leave an object which
        // would prevent the verified streaming fallback.
        try? FileManager.default.removeItem(at: destination)
        return false
    })
}

protocol FileOperating: Sendable {
    func perform(_ operation: PendingFileOperation) async throws
    func perform(
        _ operation: PendingFileOperation,
        progress: @escaping @Sendable (FileOperationProgress) -> Void
    ) async throws -> OperationOutcome
}

struct FileOperationProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int
    let currentURL: URL?

    var fractionCompleted: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalItems > 0 ? min(1, Double(completedItems) / Double(totalItems)) : 1
    }
}

struct OperationOutcome: Equatable, Sendable {
    let completedBytes: Int64
    let completedItems: Int
    let resultingURLs: [URL]
    let historySteps: [HistoryStep]

    init(completedBytes: Int64, completedItems: Int, resultingURLs: [URL], historySteps: [HistoryStep] = []) {
        self.completedBytes = completedBytes; self.completedItems = completedItems
        self.resultingURLs = resultingURLs; self.historySteps = historySteps
    }
}

struct PartialOperationFailure: LocalizedError, @unchecked Sendable {
    let outcome: OperationOutcome
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

extension FileOperating {
    func perform(
        _ operation: PendingFileOperation,
        progress: @escaping @Sendable (FileOperationProgress) -> Void
    ) async throws -> OperationOutcome {
        try await perform(operation)
        return OperationOutcome(completedBytes: 0, completedItems: operation.sourceURLs.count, resultingURLs: [])
    }
}

enum FileSystemError: LocalizedError {
    case destinationConflict(URL)
    case destinationNotDirectory(URL)
    case sourceInsideDestination(URL)
    case noSources
    case sourceUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .destinationConflict(let url): L10n.format("同名の項目が既に存在します: %@", url.path)
        case .destinationNotDirectory(let url): L10n.format("コピー先がフォルダではありません: %@", url.path)
        case .sourceInsideDestination(let url): L10n.format("フォルダをその内部へコピーまたは移動できません: %@", url.path)
        case .noSources: L10n.tr("操作対象がありません。")
        case .sourceUnavailable(let url): L10n.format("操作元が見つかりません: %@", url.path)
        }
    }
}

struct FileSystemService: FileOperating, Sendable {
    let listingCache: DirectoryListingCache
    let cloneStrategy: FileCloneStrategy

    init(listingCache: DirectoryListingCache = .shared, cloneStrategy: FileCloneStrategy = .system) {
        self.listingCache = listingCache
        self.cloneStrategy = cloneStrategy
    }

    func listDirectory(_ url: URL, showsHiddenFiles: Bool, bypassCache: Bool = false) async throws -> [FileItem] {
        let key = DirectoryListingKey(url: url.standardizedFileURL, showsHiddenFiles: showsHiddenFiles)
        return try await listingCache.entries(for: key, bypassCache: bypassCache) {
            try await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isSymbolicLinkKey,
                .isPackageKey, .totalFileSizeKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: showsHiddenFiles ? [] : [.skipsHiddenFiles]
            )
            try Task.checkCancellation()
            var items: [FileItem] = []
            var packagesNeedingSize: [Int] = []
            items.reserveCapacity(urls.count)
            for itemURL in urls {
                let values = try itemURL.resourceValues(forKeys: keys)
                let size: Int64?
                if values.isPackage == true {
                    size = values.totalFileSize.map(Int64.init)
                } else {
                    size = values.fileSize.map(Int64.init)
                }
                items.append(FileItem(
                    url: itemURL,
                    isDirectory: values.isDirectory == true,
                    size: size,
                    modificationDate: values.contentModificationDate,
                    isUbiquitous: values.isUbiquitousItem == true,
                    cloudDownloadStatus: values.ubiquitousItemDownloadingStatus?.rawValue,
                    isSymbolicLink: values.isSymbolicLink == true,
                    isPackage: values.isPackage == true
                ))
                if values.isPackage == true, size == nil { packagesNeedingSize.append(items.count - 1) }
            }
            // Real .app bundles commonly have no totalFileSize resource value.
            // Resolve those with the cached, symlink-safe folder calculator.
            // Four concurrent enumerations keep large application directories
            // responsive without creating an unbounded disk-I/O storm.
            for start in stride(from: 0, to: packagesNeedingSize.count, by: 4) {
                let batch = Array(packagesNeedingSize[start..<min(start + 4, packagesNeedingSize.count)])
                await withTaskGroup(of: (Int, Int64?).self) { group in
                    for index in batch {
                        let packageURL = items[index].url
                        group.addTask {
                            let result = try? await FolderSizeCalculator().calculate(urls: [packageURL])
                            return (index, result?.logicalBytes)
                        }
                    }
                    for await (index, size) in group { items[index] = items[index].replacingSize(size) }
                }
            }
            return items.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            }.value
        }
    }

    func invalidateListing(for url: URL) async { await listingCache.invalidate(url: url) }

    func perform(_ operation: PendingFileOperation) async throws {
        _ = try await perform(operation, progress: { _ in })
    }

    func perform(
        _ operation: PendingFileOperation,
        progress: @escaping @Sendable (FileOperationProgress) -> Void
    ) async throws -> OperationOutcome {
        let cloneStrategy = cloneStrategy
        let worker = Task.detached(priority: .userInitiated) {
            var scopes = SecurityScopeSession()
            try scopes.add(bookmark: operation.sourceAccessBookmark, requestedURLs: operation.sourceURLs)
            try scopes.add(bookmark: operation.targetAccessBookmark, requestedURLs: [operation.targetDirectoryURL])
            defer { scopes.stop() }
            if let transferPlan = operation.transferPlan {
                return try await TransferExecutionService().execute(
                    transferPlan, allowsOverwrite: true, allowsDelete: true, progress: progress
                )
            }
            if let syncPlan = operation.syncPlan {
                return try await Self.executeSync(syncPlan, progress: progress)
            }
            guard !operation.sourceURLs.isEmpty else { throw FileSystemError.noSources }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: operation.targetDirectoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FileSystemError.destinationNotDirectory(operation.targetDirectoryURL)
            }
            let canonicalTargetDirectory = operation.targetDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
            var planned: [(source: URL, target: URL)] = []
            var plannedTargets = Set<URL>()
            for source in operation.sourceURLs {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw FileSystemError.sourceUnavailable(source)
                }
                let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
                let target = canonicalTargetDirectory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
                if target.path.hasPrefix(canonicalSource.path + "/") {
                    throw FileSystemError.sourceInsideDestination(source)
                }
                guard plannedTargets.insert(target).inserted,
                      !FileManager.default.fileExists(atPath: target.path) else {
                    throw FileSystemError.destinationConflict(target)
                }
                planned.append((source, target))
            }
            let totals = try Self.measure(planned.map(\.source))
            var completedBytes: Int64 = 0
            var completedItems = 0
            var outcomeSteps: [HistoryStep] = []
            var resultingURLs: [URL] = []
            progress(.init(completedBytes: 0, totalBytes: totals.bytes, completedItems: 0, totalItems: totals.items, currentURL: planned.first?.source))
            // Validate every known conflict before mutating the file system.
            for item in planned {
              do {
                try Task.checkCancellation()
                switch operation.kind {
                case .copy:
                    try Self.copyRecursively(item.source, to: item.target, cloneStrategy: cloneStrategy) { bytes, items, current in
                        completedBytes += bytes
                        completedItems += items
                        progress(.init(completedBytes: completedBytes, totalBytes: totals.bytes, completedItems: completedItems, totalItems: totals.items, currentURL: current))
                    }
                    guard let sourceFP = HistoryFingerprint.capture(item.source), let targetFP = HistoryFingerprint.capture(item.target) else { throw FileSystemError.sourceUnavailable(item.source) }
                    outcomeSteps.append(.copied(source: item.source, target: item.target, sourceFingerprint: sourceFP, targetFingerprint: targetFP))
                case .move:
                    let itemTotals = try Self.measure([item.source])
                    try FileManager.default.moveItem(at: item.source, to: item.target)
                    completedBytes += itemTotals.bytes
                    completedItems += itemTotals.items
                    progress(.init(completedBytes: completedBytes, totalBytes: totals.bytes, completedItems: completedItems, totalItems: totals.items, currentURL: item.target))
                    outcomeSteps.append(.moved(from: item.source, to: item.target))
                case .sync: throw SyncSafetyError.previewRequired
                }
                resultingURLs.append(item.target)
              } catch {
                // A cancelled in-flight item is rolled back by copyRecursively.  It is
                // therefore not a partial success even if some bytes were streamed.
                if error is CancellationError, outcomeSteps.isEmpty, resultingURLs.isEmpty {
                    throw error
                }
                throw PartialOperationFailure(outcome: .init(completedBytes: completedBytes, completedItems: completedItems,
                                                              resultingURLs: resultingURLs, historySteps: outcomeSteps), underlying: error)
              }
            }
            return OperationOutcome(completedBytes: completedBytes, completedItems: completedItems,
                                    resultingURLs: resultingURLs, historySteps: outcomeSteps)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func measure(_ roots: [URL]) throws -> (bytes: Int64, items: Int) {
        var bytes: Int64 = 0
        var items = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for root in roots {
            try Task.checkCancellation()
            let values = try root.resourceValues(forKeys: Set(keys))
            items += 1
            if values.isDirectory == true, values.isSymbolicLink != true {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { continue }
                for case let child as URL in enumerator {
                    try Task.checkCancellation()
                    let childValues = try child.resourceValues(forKeys: Set(keys))
                    items += 1
                    if childValues.isDirectory != true { bytes += Int64(childValues.fileSize ?? 0) }
                }
            } else { bytes += Int64(values.fileSize ?? 0) }
        }
        return (bytes, items)
    }

    private static func copyRecursively(
        _ source: URL,
        to target: URL,
        cloneStrategy: FileCloneStrategy,
        progress: (Int64, Int, URL) -> Void
    ) throws {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            progress(Int64(values.fileSize ?? 0), 1, source)
        } else if values.isDirectory == true {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            do {
                progress(0, 1, source)
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for child in children {
                    try copyRecursively(child, to: target.appendingPathComponent(child.lastPathComponent), cloneStrategy: cloneStrategy, progress: progress)
                }
                applyMetadata(from: source, to: target)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        } else {
            // clonefile is atomic from the application's point of view and
            // preserves APFS copy-on-write storage. Directories remain
            // recursive here so cancellation and per-child history/progress
            // semantics are retained.
            if cloneStrategy.canClone(source, target), cloneStrategy.clone(source, target) {
                try Task.checkCancellation()
                progress(Int64(values.fileSize ?? 0), 1, source)
                return
            }
            let staging = target.deletingLastPathComponent().appendingPathComponent(".quadfinder-\(UUID().uuidString).partial")
            FileManager.default.createFile(atPath: staging.path, contents: nil)
            do {
                let input = try FileHandle(forReadingFrom: source)
                let output = try FileHandle(forWritingTo: staging)
                defer { try? input.close(); try? output.close() }
                while true {
                    try Task.checkCancellation()
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                    progress(Int64(data.count), 0, source)
                }
                try FileManager.default.moveItem(at: staging, to: target)
                applyMetadata(from: source, to: target)
                progress(0, 1, source)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
    }

    private static func applyMetadata(from source: URL, to target: URL) {
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var attributes: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.posixPermissions, .modificationDate, .creationDate] {
            if let value = sourceAttributes[key] { attributes[key] = value }
        }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
    }

    static func bookmark(for url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions = AppSecurityEnvironment.current.isSandboxed ? [.withSecurityScope] : []
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) throws -> URL {
        try resolveBookmarkWithStatus(data).url
    }

    static func resolveBookmarkWithStatus(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let options: URL.BookmarkResolutionOptions = AppSecurityEnvironment.current.isSandboxed ? [.withSecurityScope] : []
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    private static func executeSync(
        _ plan: SyncExecutionPlan, progress: @escaping @Sendable (FileOperationProgress) -> Void
    ) async throws -> OperationOutcome {
        let usesChecksum = plan.sourceSnapshot.entries.values.contains { $0.checksum != nil }
            || plan.targetSnapshot.entries.values.contains { $0.checksum != nil }
        async let source = snapshot(plan.sourceSnapshot.directoryURL, usesChecksum: usesChecksum)
        async let target = snapshot(plan.targetSnapshot.directoryURL, usesChecksum: usesChecksum)
        let (currentSource, currentTarget) = try await (source, target)
        try SyncSafetyValidator.validate(plan, currentSource: currentSource, currentTarget: currentTarget)

        var steps: [HistoryStep] = []
        var results: [URL] = []
        let totalBytes = (try? measure(plan.actions.compactMap(\.sourceURL)).bytes) ?? 0
        var completedBytes: Int64 = 0
        progress(.init(completedBytes: 0, totalBytes: totalBytes, completedItems: 0,
                       totalItems: plan.actions.count, currentURL: plan.actions.first?.targetURL))
        for action in plan.actions {
          do {
            try Task.checkCancellation()
            switch action.kind {
            case .create:
                guard let sourceURL = action.sourceURL else { throw FileSystemError.noSources }
                try FileManager.default.copyItem(at: sourceURL, to: action.targetURL)
                guard let sourceFP = HistoryFingerprint.capture(sourceURL), let targetFP = HistoryFingerprint.capture(action.targetURL) else { throw FileSystemError.sourceUnavailable(sourceURL) }
                steps.append(.copied(source: sourceURL, target: action.targetURL, sourceFingerprint: sourceFP, targetFingerprint: targetFP))
                results.append(action.targetURL)
            case .overwrite:
                guard let sourceURL = action.sourceURL else { throw FileSystemError.noSources }
                guard let sourceFP = HistoryFingerprint.capture(sourceURL) else { throw FileSystemError.sourceUnavailable(sourceURL) }
                var oldTrashURL: URL?
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: action.targetURL, resultingItemURL: &trashed)
                    oldTrashURL = trashed as URL?
                } catch {
                    throw SyncSafetyError.trashUnavailable(action.targetURL)
                }
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: action.targetURL)
                } catch {
                    if let oldTrashURL, !FileManager.default.fileExists(atPath: action.targetURL.path) {
                        try? FileManager.default.moveItem(at: oldTrashURL, to: action.targetURL)
                    }
                    throw error
                }
                guard let targetFP = HistoryFingerprint.capture(action.targetURL) else { throw FileSystemError.sourceUnavailable(action.targetURL) }
                steps.append(.replaced(source: sourceURL, target: action.targetURL, oldTrashURL: oldTrashURL,
                                       sourceFingerprint: sourceFP, newFingerprint: targetFP, movesSource: false))
                results.append(action.targetURL)
            case .delete:
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: action.targetURL, resultingItemURL: &trashed)
                    steps.append(.trashed(original: action.targetURL, trashURL: trashed as URL?))
                } catch {
                    throw SyncSafetyError.trashUnavailable(action.targetURL)
                }
            }
            if let sourceURL = action.sourceURL { completedBytes += (try? measure([sourceURL]).bytes) ?? 0 }
            progress(.init(completedBytes: completedBytes, totalBytes: totalBytes, completedItems: steps.count,
                           totalItems: plan.actions.count, currentURL: action.targetURL))
          } catch {
            throw PartialOperationFailure(outcome: .init(completedBytes: 0, completedItems: steps.count,
                                                          resultingURLs: results, historySteps: steps), underlying: error)
          }
        }
        progress(.init(completedBytes: totalBytes, totalBytes: totalBytes, completedItems: plan.actions.count,
                       totalItems: plan.actions.count, currentURL: plan.actions.last?.targetURL))
        return OperationOutcome(completedBytes: completedBytes, completedItems: steps.count,
                                resultingURLs: results, historySteps: steps)
    }

    static func snapshot(_ url: URL, usesChecksum: Bool) async throws -> DirectorySnapshot {
        try await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            var entries: [String: DirectoryEntryFingerprint] = [:]
            for itemURL in urls {
                try Task.checkCancellation()
                let values = try itemURL.resourceValues(forKeys: keys)
                let isDirectory = values.isDirectory == true
                let isUbiquitous = values.isUbiquitousItem == true
                let cloudStatus = isUbiquitous ? values.ubiquitousItemDownloadingStatus?.rawValue : nil
                let checksum = usesChecksum ? try await CloudChecksumPolicy.checksumIfAvailable(
                    isDirectory: isDirectory,
                    isUbiquitous: isUbiquitous,
                    downloadStatus: cloudStatus
                ) { try await FolderComparisonService.sha256(itemURL) } : nil
                entries[itemURL.lastPathComponent] = DirectoryEntryFingerprint(
                    name: itemURL.lastPathComponent,
                    isDirectory: isDirectory,
                    size: values.fileSize.map(Int64.init),
                    modificationDate: values.contentModificationDate,
                    checksum: checksum,
                    cloudStatus: cloudStatus
                )
            }
            return DirectorySnapshot(directoryURL: url, entries: entries)
        }.value
    }
}

enum SyncSafetyValidator {
    static func validate(
        _ plan: SyncExecutionPlan,
        currentSource: DirectorySnapshot,
        currentTarget: DirectorySnapshot
    ) throws {
        guard plan.confirmationStage >= 2 else { throw SyncSafetyError.secondConfirmationRequired }
        if plan.actions.contains(where: { $0.kind == .overwrite }) && !plan.allowsOverwrite {
            throw SyncSafetyError.overwriteNotEnabled
        }
        if plan.actions.contains(where: { $0.kind == .delete }) && !plan.allowsDelete {
            throw SyncSafetyError.deleteNotEnabled
        }
        guard currentSource == plan.sourceSnapshot, currentTarget == plan.targetSnapshot else {
            throw SyncSafetyError.staleSnapshot
        }
        for action in plan.actions {
            switch action.kind {
            case .create:
                guard let source = action.sourceURL, FileManager.default.fileExists(atPath: source.path) else {
                    throw FileSystemError.sourceUnavailable(action.sourceURL ?? action.targetURL)
                }
                guard !FileManager.default.fileExists(atPath: action.targetURL.path) else {
                    throw FileSystemError.destinationConflict(action.targetURL)
                }
            case .overwrite:
                guard let source = action.sourceURL, FileManager.default.fileExists(atPath: source.path) else {
                    throw FileSystemError.sourceUnavailable(action.sourceURL ?? action.targetURL)
                }
                guard FileManager.default.fileExists(atPath: action.targetURL.path) else {
                    throw SyncSafetyError.staleSnapshot
                }
            case .delete:
                guard FileManager.default.fileExists(atPath: action.targetURL.path) else {
                    throw SyncSafetyError.staleSnapshot
                }
            }
        }
    }
}
