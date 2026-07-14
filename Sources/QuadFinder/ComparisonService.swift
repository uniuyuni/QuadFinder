import CryptoKit
import Foundation

struct ComparisonRequest: Sendable {
    let sourcePaneID: UUID
    let targetPaneID: UUID
    let sourceURL: URL
    let targetURL: URL
    let sourceBookmark: Data?
    let targetBookmark: Data?
    let usesChecksums: Bool
}

enum CloudChecksumPolicy {
    static func isContentAvailable(isUbiquitous: Bool, downloadStatus: String?) -> Bool {
        !isUbiquitous || downloadStatus == URLUbiquitousItemDownloadingStatus.current.rawValue
    }

    static func checksumIfAvailable(
        isDirectory: Bool,
        isUbiquitous: Bool,
        downloadStatus: String?,
        reader: @escaping @Sendable () async throws -> String
    ) async throws -> String? {
        guard !isDirectory,
              isContentAvailable(isUbiquitous: isUbiquitous, downloadStatus: downloadStatus) else { return nil }
        return try await reader()
    }
}

struct ComparisonProgressCoalescer {
    let total: Int
    let stride: Int

    init(total: Int, stride: Int = 128) {
        self.total = total
        self.stride = max(1, stride)
    }

    func progress(after processed: Int) -> Double? {
        guard total > 0 else { return 1 }
        guard processed == total || processed % stride == 0 else { return nil }
        return Double(processed) / Double(total)
    }
}

struct FolderComparisonService: Sendable {
    let fileSystem: FileSystemService

    init(fileSystem: FileSystemService = FileSystemService()) {
        self.fileSystem = fileSystem
    }

    func compare(
        _ request: ComparisonRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> FolderComparisonResult {
        var scopedURLs: [URL] = []
        for bookmark in [request.sourceBookmark, request.targetBookmark].compactMap({ $0 }) {
            let url = try FileSystemService.resolveBookmark(bookmark)
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        async let sourceItems = fileSystem.listDirectory(request.sourceURL, showsHiddenFiles: false, bypassCache: true)
        async let targetItems = fileSystem.listDirectory(request.targetURL, showsHiddenFiles: false, bypassCache: true)
        let (sourceListed, targetListed) = try await (sourceItems, targetItems)
        try Task.checkCancellation()
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceListed.map { ($0.name, $0) })
        let targetByName = Dictionary(uniqueKeysWithValues: targetListed.map { ($0.name, $0) })
        let names = Set(sourceByName.keys).union(targetByName.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var sourceSnapshot: [String: DirectoryEntryFingerprint] = [:]
        var targetSnapshot: [String: DirectoryEntryFingerprint] = [:]
        var entries: [ComparisonEntry] = []
        let progressCoalescer = ComparisonProgressCoalescer(total: names.count)

        for (index, name) in names.enumerated() {
            try Task.checkCancellation()
            let source = sourceByName[name]
            let target = targetByName[name]
            let sourceFingerprint = try await fingerprint(source, checksum: request.usesChecksums)
            let targetFingerprint = try await fingerprint(target, checksum: request.usesChecksums)
            if let sourceFingerprint { sourceSnapshot[name] = sourceFingerprint }
            if let targetFingerprint { targetSnapshot[name] = targetFingerprint }
            let cloudUnavailable = [source, target].compactMap { $0 }.first { item in
                !CloudChecksumPolicy.isContentAvailable(
                    isUbiquitous: item.isUbiquitous,
                    downloadStatus: item.cloudDownloadStatus
                )
            }
            let classified = ComparisonClassifier.classify(
                source: sourceFingerprint,
                target: targetFingerprint,
                cloudError: cloudUnavailable.map { L10n.format("未ダウンロードまたは状態不明: %@", $0.cloudDownloadStatus ?? L10n.tr("不明")) }
            )
            entries.append(ComparisonEntry(
                name: name,
                source: sourceFingerprint,
                target: targetFingerprint,
                classification: classified.0,
                message: classified.1
            ))
            if let value = progressCoalescer.progress(after: index + 1) { progress(value) }
        }
        if names.isEmpty { progress(1) }
        return FolderComparisonResult(
            sourcePaneID: request.sourcePaneID,
            targetPaneID: request.targetPaneID,
            sourceURL: request.sourceURL,
            targetURL: request.targetURL,
            sourceBookmark: request.sourceBookmark,
            targetBookmark: request.targetBookmark,
            usesChecksums: request.usesChecksums,
            sourceSnapshot: DirectorySnapshot(directoryURL: request.sourceURL, entries: sourceSnapshot),
            targetSnapshot: DirectorySnapshot(directoryURL: request.targetURL, entries: targetSnapshot),
            entries: entries
        )
    }

    private func fingerprint(_ item: FileItem?, checksum: Bool) async throws -> DirectoryEntryFingerprint? {
        guard let item else { return nil }
        let digest = checksum ? try await CloudChecksumPolicy.checksumIfAvailable(
            isDirectory: item.isDirectory,
            isUbiquitous: item.isUbiquitous,
            downloadStatus: item.cloudDownloadStatus
        ) { try await Self.sha256(item.url) } : nil
        return DirectoryEntryFingerprint(
            name: item.name,
            isDirectory: item.isDirectory,
            size: item.size,
            modificationDate: item.modificationDate,
            checksum: digest,
            cloudStatus: item.isUbiquitous ? item.cloudDownloadStatus : nil
        )
    }

    static func sha256(_ url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

@MainActor
final class ComparisonController: ObservableObject {
    @Published private(set) var result: FolderComparisonResult?
    @Published private(set) var progress = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published var preview: SyncExecutionPlan?

    private let service: FolderComparisonService
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(service: FolderComparisonService = FolderComparisonService()) {
        self.service = service
    }

    func start(_ request: ComparisonRequest) {
        cancel()
        let currentGeneration = UUID()
        generation = currentGeneration
        result = nil
        preview = nil
        errorMessage = nil
        progress = 0
        isRunning = true
        task = Task {
            do {
                let compared = try await service.compare(request) { [weak self] value in
                    Task { @MainActor in
                        guard self?.generation == currentGeneration else { return }
                        self?.progress = value
                    }
                }
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                result = compared
            } catch is CancellationError {
                guard generation == currentGeneration else { return }
                errorMessage = L10n.tr("比較をキャンセルしました。")
            } catch {
                guard generation == currentGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == currentGeneration { isRunning = false }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if isRunning { isRunning = false }
    }

    func waitUntilIdle() async {
        while isRunning { await Task.yield() }
    }

    func makePreview(mode: SyncMode, allowsOverwrite: Bool, allowsDelete: Bool) throws -> SyncExecutionPlan {
        guard let result else { throw SyncSafetyError.previewRequired }
        let plan = SyncPreviewBuilder.make(
            from: result,
            mode: mode,
            allowsOverwrite: allowsOverwrite,
            allowsDelete: allowsDelete
        )
        preview = plan
        return plan
    }

    func confirmedPlan() throws -> SyncExecutionPlan {
        guard let preview else { throw SyncSafetyError.previewRequired }
        return SyncExecutionPlan(
            mode: preview.mode,
            sourceSnapshot: preview.sourceSnapshot,
            targetSnapshot: preview.targetSnapshot,
            sourceBookmark: preview.sourceBookmark,
            targetBookmark: preview.targetBookmark,
            actions: preview.actions,
            allowsOverwrite: preview.allowsOverwrite,
            allowsDelete: preview.allowsDelete,
            confirmationStage: 2
        )
    }
}

enum ComparisonClassifier {
    static func classify(
        source: DirectoryEntryFingerprint?,
        target: DirectoryEntryFingerprint?,
        cloudError: String?
    ) -> (ComparisonClassification, String?) {
        if let cloudError { return (.error, cloudError) }
        if source == nil { return (.onlyTarget, nil) }
        if target == nil { return (.onlySource, nil) }
        return source == target ? (.equal, nil) : (.different, nil)
    }
}

enum SyncPreviewBuilder {
    static func make(
        from result: FolderComparisonResult,
        mode: SyncMode,
        allowsOverwrite: Bool,
        allowsDelete: Bool
    ) -> SyncExecutionPlan {
        var actions: [SyncAction] = []
        for entry in result.entries {
            let source = result.sourceURL.appendingPathComponent(entry.name)
            let target = result.targetURL.appendingPathComponent(entry.name)
            switch (mode, entry.classification) {
            case (_, .onlySource):
                actions.append(SyncAction(kind: .create, sourceURL: source, targetURL: target))
            case (.oneWayUpdate, .different):
                if let sourceDate = entry.source?.modificationDate,
                   let targetDate = entry.target?.modificationDate,
                   sourceDate > targetDate {
                    actions.append(SyncAction(kind: .overwrite, sourceURL: source, targetURL: target))
                }
            case (.oneWayMirror, .different):
                actions.append(SyncAction(kind: .overwrite, sourceURL: source, targetURL: target))
            case (.oneWayMirror, .onlyTarget):
                actions.append(SyncAction(kind: .delete, sourceURL: nil, targetURL: target))
            default:
                break
            }
        }
        return SyncExecutionPlan(
            mode: mode,
            sourceSnapshot: result.sourceSnapshot,
            targetSnapshot: result.targetSnapshot,
            sourceBookmark: result.sourceBookmark,
            targetBookmark: result.targetBookmark,
            actions: actions,
            allowsOverwrite: allowsOverwrite,
            allowsDelete: allowsDelete,
            confirmationStage: 1
        )
    }
}
