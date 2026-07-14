import Foundation

enum FileOperationStatus: String, Codable, Sendable {
    case queued = "待機中"
    case running = "実行中"
    case succeeded = "完了"
    case failed = "失敗"
    case cancelled = "キャンセル"
    case stopped = "中止"

    var localizedTitle: String { L10n.tr(rawValue) }

    var isFinished: Bool { self == .succeeded || self == .failed || self == .cancelled || self == .stopped }
}

struct FileOperationJob: Identifiable, Sendable {
    let id: UUID
    let operation: PendingFileOperation
    let enqueuedAt: Date
    var status: FileOperationStatus
    var errorMessage: String?
    var progress: FileOperationProgress?

    /// Nil means that the underlying Foundation operation cannot report byte
    /// progress.  The UI intentionally shows an indeterminate spinner then.
    var fractionCompleted: Double? {
        switch status {
        case .succeeded: 1
        case .running: progress?.fractionCompleted
        case .queued, .failed, .cancelled, .stopped: nil
        }
    }

    var sourceDescription: String {
        if let plan = operation.transferPlan {
            return L10n.format("比較転送 %d操作: %@", plan.selectedActions.count, plan.sourceURLs.first?.path ?? "")
        }
        if operation.sourceURLs.isEmpty {
            return operation.syncPlan.map { L10n.format("同期 %d操作", $0.actions.count) } ?? L10n.tr("操作元なし")
        }
        if operation.sourceURLs.count == 1 { return operation.sourceURLs[0].path }
        return L10n.format("%d項目: %@ ほか", operation.sourceURLs.count, operation.sourceURLs[0].path)
    }
}

@MainActor
final class FileOperationQueue: ObservableObject {
    @Published private(set) var jobs: [FileOperationJob] = []

    private let fileSystem: any FileOperating
    private var processor: Task<Void, Never>?
    private var runningTask: Task<OperationOutcome, Error>?
    private var runningJobID: UUID?
    private var stopRequests: Set<UUID> = []
    private let cutMarkerClearer: @MainActor (ClipboardCutReceipt) -> Void
    private let history: OperationHistoryStore?

    init(
        fileSystem: any FileOperating = FileSystemService(),
        history: OperationHistoryStore? = nil,
        cutMarkerClearer: @escaping @MainActor (ClipboardCutReceipt) -> Void = {
            _ = FinderClipboard.shared.clearCutMarker(ifMatches: $0)
        }
    ) {
        self.fileSystem = fileSystem
        self.history = history
        self.cutMarkerClearer = cutMarkerClearer
    }

    @discardableResult
    func enqueue(_ operation: PendingFileOperation) -> UUID {
        let id = UUID()
        jobs.append(FileOperationJob(id: id, operation: operation, enqueuedAt: Date(), status: .queued, progress: nil))
        startProcessorIfNeeded()
        return id
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .queued:
            jobs[index].status = .cancelled
        case .running:
            guard runningJobID == id else { return }
            runningTask?.cancel()
        case .succeeded, .failed, .cancelled, .stopped:
            break
        }
    }

    /// Stops only this job. Completed top-level items are committed to the
    /// operation journal and can be reverted explicitly with Undo.
    func stop(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .queued:
            jobs[index].status = .stopped
        case .running:
            guard runningJobID == id else { return }
            stopRequests.insert(id)
            runningTask?.cancel()
        case .succeeded, .failed, .cancelled, .stopped:
            break
        }
    }

    func clearCompleted() {
        jobs.removeAll { $0.status.isFinished }
    }

    func job(id: UUID) -> FileOperationJob? { jobs.first { $0.id == id } }

    var progressSummary: FileOperationProgressSummary {
        FileOperationProgressSummary(jobs: jobs)
    }

    func waitUntilIdle() async {
        while processor != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func startProcessorIfNeeded() {
        guard processor == nil else { return }
        processor = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        defer {
            processor = nil
            if jobs.contains(where: { $0.status == .queued }) { startProcessorIfNeeded() }
        }
        while let index = jobs.firstIndex(where: { $0.status == .queued }) {
            let id = jobs[index].id
            let operation = jobs[index].operation
            jobs[index].status = .running
            runningJobID = id
            let progressTarget = self
            let operatorService = fileSystem
            let historyStore = history
            let task = Task {
                if let replay = operation.historyReplay {
                    guard let historyStore else { throw HistoryError.orderChanged }
                    await MainActor.run {
                        progressTarget.receiveProgress(.init(completedBytes: 0, totalBytes: 0, completedItems: 0,
                                                             totalItems: 1, currentURL: operation.targetDirectoryURL), for: id)
                    }
                    try historyStore.replay(replay)
                    await MainActor.run {
                        progressTarget.receiveProgress(.init(completedBytes: 0, totalBytes: 0, completedItems: 1,
                                                             totalItems: 1, currentURL: operation.targetDirectoryURL), for: id)
                    }
                    return OperationOutcome(completedBytes: 0, completedItems: 1, resultingURLs: [])
                }
                return try await operatorService.perform(operation) { value in
                    Task { @MainActor in progressTarget.receiveProgress(value, for: id) }
                }
            }
            runningTask = task
            do {
                let outcome = try await task.value
                update(id) { $0.status = .succeeded }
                if operation.historyReplay == nil { commit(outcome, for: operation, partial: false) }
                let normalizedSources = operation.sourceURLs.map(\.standardizedFileURL).sorted { $0.path < $1.path }
                if operation.kind == .move, let receipt = operation.clipboardCutReceipt,
                   receipt.sourceURLs == normalizedSources,
                   normalizedSources.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                    cutMarkerClearer(receipt)
                }
                postDirectoryChanges(for: operation)
            } catch let partial as PartialOperationFailure {
                commit(partial.outcome, for: operation, partial: true)
                if partial.outcome.completedItems > 0 { postDirectoryChanges(for: operation) }
                update(id) {
                    if stopRequests.contains(id) { $0.status = .stopped }
                    else if partial.underlying is CancellationError { $0.status = .cancelled }
                    else {
                        $0.status = .failed
                        $0.errorMessage = partial.localizedDescription
                    }
                }
            } catch is CancellationError {
                update(id) { $0.status = stopRequests.contains(id) ? .stopped : .cancelled }
            } catch {
                update(id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            runningTask = nil
            runningJobID = nil
            stopRequests.remove(id)
        }
    }

    private func update(_ id: UUID, change: (inout FileOperationJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func postDirectoryChanges(for operation: PendingFileOperation) {
        NotificationCenter.default.post(name: .quadFinderDirectoryDidChange,
                                        object: operation.targetDirectoryURL.standardizedFileURL)
        if operation.kind == .move || operation.historyReplay != nil {
            for directory in Set(operation.sourceURLs.map { $0.deletingLastPathComponent().standardizedFileURL }) {
                NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: directory)
            }
        }
    }

    private func commit(_ outcome: OperationOutcome, for operation: PendingFileOperation, partial: Bool) {
        guard !outcome.historySteps.isEmpty else { return }
        let kind: HistoryOperationKind = operation.syncPlan != nil ? .sync
            : (operation.transferPlan != nil ? .transfer : (operation.kind == .move ? .move : .copy))
        let verb = operation.syncPlan != nil ? L10n.tr("同期") : (operation.kind == .move ? L10n.tr("移動") : L10n.tr("コピー"))
        let reason = outcome.historySteps.compactMap(\.undoabilityReason).first
        history?.record(.init(kind: kind, summary: L10n.format("%d操作を%@%@", outcome.historySteps.count, verb, partial ? L10n.tr("（一部完了）") : ""),
                              steps: outcome.historySteps, itemCount: outcome.completedItems,
                              byteCount: outcome.completedBytes,
                              sourceBookmark: operation.sourceAccessBookmark,
                              targetBookmark: operation.targetAccessBookmark,
                              undoable: reason == nil, reason: reason))
    }

    private var progressUpdateTimes: [UUID: ContinuousClock.Instant] = [:]

    private func receiveProgress(_ progress: FileOperationProgress, for id: UUID) {
        let now = ContinuousClock.now
        if let previous = progressUpdateTimes[id], now - previous < .milliseconds(80), progress.fractionCompleted < 1 { return }
        progressUpdateTimes[id] = now
        update(id) { $0.progress = progress }
    }
}

struct FileOperationProgressSummary: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let runningJobID: UUID?
    let completedBytes: Int64
    let totalBytes: Int64
    let currentPath: String?
    let waitingCount: Int

    init(jobs: [FileOperationJob]) {
        totalCount = jobs.filter { $0.status != .cancelled }.count
        completedCount = jobs.filter { $0.status == .succeeded || $0.status == .failed || $0.status == .stopped }.count
        runningJobID = jobs.first(where: { $0.status == .running })?.id
        let running = jobs.first(where: { $0.status == .running })
        completedBytes = running?.progress?.completedBytes ?? 0
        totalBytes = running?.progress?.totalBytes ?? 0
        currentPath = running?.progress?.currentURL?.lastPathComponent
        waitingCount = jobs.filter { $0.status == .queued }.count
    }

    var isActive: Bool { runningJobID != nil || completedCount < totalCount }
    var fractionCompleted: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount)
    }
}
