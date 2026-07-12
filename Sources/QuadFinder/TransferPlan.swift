import AppKit
import Foundation

enum TransferConflictPolicy: String, CaseIterable, Sendable {
    case missingOnly = "存在しない項目のみ"
    case newerOnly = "新しい項目のみ"
    case replace = "上書き"
    case synchronize = "同期（ターゲットを一致）"
    case autoRename = "自動で名前を変更"
}

enum TransferPlanActionKind: String, Sendable {
    case copy = "コピー"
    case merge = "フォルダを統合"
    case replace = "上書き"
    case trashTarget = "ターゲットから削除"
    case skip = "変更なし"
    case autoRename = "名前を変更"

    var isDestructive: Bool { self == .replace || self == .trashTarget }
    var isExecutable: Bool { self != .skip && self != .merge }
}

struct TransferItemFingerprint: Equatable, Sendable {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let modificationDate: Date?
}

struct TransferPlanAction: Identifiable, Sendable {
    let id: UUID
    let kind: TransferPlanActionKind
    let sourceURL: URL?
    let targetURL: URL
    let sourceFingerprint: TransferItemFingerprint?
    let targetFingerprint: TransferItemFingerprint?
    var isSelected: Bool

    init(
        id: UUID = UUID(), kind: TransferPlanActionKind, sourceURL: URL?, targetURL: URL,
        sourceFingerprint: TransferItemFingerprint?, targetFingerprint: TransferItemFingerprint?,
        isSelected: Bool
    ) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.isSelected = isSelected
    }
}

struct TransferExecutionPlan: Sendable {
    let kind: FileOperationKind
    let policy: TransferConflictPolicy
    let sourceURLs: [URL]
    let targetDirectoryURL: URL
    let sourceAccessBookmark: Data?
    let targetAccessBookmark: Data?
    var actions: [TransferPlanAction]
    var confirmationStage: Int

    var selectedActions: [TransferPlanAction] { actions.filter { $0.isSelected && $0.kind.isExecutable } }
    var hasDestructiveActions: Bool { selectedActions.contains { $0.kind.isDestructive } }
    var copyCount: Int { selectedActions.count { $0.kind == .copy || $0.kind == .autoRename } }
    var mergeCount: Int { actions.count { $0.kind == .merge } }
    var replaceCount: Int { selectedActions.count { $0.kind == .replace } }
    var deleteCount: Int { selectedActions.count { $0.kind == .trashTarget } }
    var sourceDeleteCount: Int {
        kind == .move
            ? selectedActions.count { $0.sourceURL != nil && ($0.kind == .copy || $0.kind == .autoRename || $0.kind == .replace) }
            : 0
    }
    var skipCount: Int { actions.count { $0.kind == .skip || ($0.kind.isExecutable && !$0.isSelected) } }
}

struct TransferPlanRequest: Sendable {
    let kind: FileOperationKind
    let sourceURLs: [URL]
    let targetDirectoryURL: URL
    let sourceAccessBookmark: Data?
    let targetAccessBookmark: Data?
}

enum TransferPlanError: LocalizedError, Equatable {
    case noSources
    case sourceUnavailable(URL)
    case destinationNotDirectory(URL)
    case duplicateTarget(URL)
    case selfCopy(URL)
    case sourceInsideDestination(URL)
    case stalePlan
    case confirmationRequired
    case overwriteNotConfirmed
    case deletionNotConfirmed
    case trashUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .noSources: "操作対象がありません。"
        case .sourceUnavailable(let url): "操作元が見つかりません: \(url.path)"
        case .destinationNotDirectory(let url): "コピー先がフォルダではありません: \(url.path)"
        case .duplicateTarget(let url): "複数の項目が同じコピー先になります: \(url.path)"
        case .selfCopy(let url): "項目を同じ場所へコピーまたは移動できません: \(url.path)"
        case .sourceInsideDestination(let url): "フォルダをその内部へコピーまたは移動できません: \(url.path)"
        case .stalePlan: "確認後にファイル構成が変化しました。プレビューを作り直してください。"
        case .confirmationRequired: "実行前の確認が完了していません。"
        case .overwriteNotConfirmed: "上書きが明示的に確認されていません。"
        case .deletionNotConfirmed: "削除が明示的に確認されていません。"
        case .trashUnavailable(let url): "項目をゴミ箱へ移動できません。完全削除は行いません: \(url.path)"
        }
    }
}

struct TransferPlanningService: Sendable {
    func makePlan(_ request: TransferPlanRequest, policy: TransferConflictPolicy) async throws -> TransferExecutionPlan {
        try await Task.detached(priority: .userInitiated) {
            try Self.makePlanSynchronously(request, policy: policy)
        }.value
    }

    private static func makePlanSynchronously(
        _ request: TransferPlanRequest, policy: TransferConflictPolicy
    ) throws -> TransferExecutionPlan {
        guard !request.sourceURLs.isEmpty else { throw TransferPlanError.noSources }
        var destinationIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.targetDirectoryURL.path, isDirectory: &destinationIsDirectory),
              destinationIsDirectory.boolValue else {
            throw TransferPlanError.destinationNotDirectory(request.targetDirectoryURL)
        }

        let targetDirectory = request.targetDirectoryURL.standardizedFileURL
        let canonicalTargetDirectory = targetDirectory.resolvingSymlinksInPath().standardizedFileURL
        var targets = Set<URL>()
        var actions: [TransferPlanAction] = []
        for rawSource in request.sourceURLs {
            try Task.checkCancellation()
            let source = rawSource.standardizedFileURL
            guard let sourceFingerprint = fingerprint(source) else { throw TransferPlanError.sourceUnavailable(source) }
            let target = targetDirectory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
            guard targets.insert(target).inserted else { throw TransferPlanError.duplicateTarget(target) }
            let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
            let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
            if canonicalSource == canonicalTarget { throw TransferPlanError.selfCopy(source) }
            if sourceFingerprint.isDirectory && !sourceFingerprint.isSymbolicLink &&
                canonicalTargetDirectory.path.hasPrefix(canonicalSource.path + "/") {
                // Preserve the caller's URL spelling in diagnostics (including
                // its directory-slash form) while using canonical URLs for the
                // safety comparison above.
                throw TransferPlanError.sourceInsideDestination(rawSource)
            }
            try appendActions(source: source, target: target, policy: policy, actions: &actions)
        }
        return TransferExecutionPlan(
            kind: request.kind, policy: policy, sourceURLs: request.sourceURLs.map(\.standardizedFileURL),
            targetDirectoryURL: targetDirectory, sourceAccessBookmark: request.sourceAccessBookmark,
            targetAccessBookmark: request.targetAccessBookmark, actions: actions, confirmationStage: 1
        )
    }

    private static func appendActions(
        source: URL, target: URL, policy: TransferConflictPolicy, actions: inout [TransferPlanAction]
    ) throws {
        try Task.checkCancellation()
        guard let sourceFingerprint = fingerprint(source) else { throw TransferPlanError.sourceUnavailable(source) }
        guard let targetFingerprint = fingerprint(target) else {
            actions.append(TransferPlanAction(
                kind: .copy, sourceURL: source, targetURL: target, sourceFingerprint: sourceFingerprint,
                targetFingerprint: nil, isSelected: true
            ))
            return
        }

        let mergeableDirectories = sourceFingerprint.isDirectory && !sourceFingerprint.isSymbolicLink
            && targetFingerprint.isDirectory && !targetFingerprint.isSymbolicLink
        if mergeableDirectories && policy != .replace && policy != .autoRename {
            actions.append(TransferPlanAction(
                kind: .merge, sourceURL: source, targetURL: target,
                sourceFingerprint: sourceFingerprint, targetFingerprint: targetFingerprint,
                isSelected: false
            ))
            let sourceChildren = try children(source)
            let targetChildren = try children(target)
            let sourceByName = Dictionary(uniqueKeysWithValues: sourceChildren.map { ($0.lastPathComponent, $0) })
            let targetByName = Dictionary(uniqueKeysWithValues: targetChildren.map { ($0.lastPathComponent, $0) })
            for name in sourceByName.keys.sorted() {
                try appendActions(
                    source: sourceByName[name]!, target: target.appendingPathComponent(name),
                    policy: policy, actions: &actions
                )
            }
            if policy == .synchronize {
                for name in targetByName.keys.filter({ sourceByName[$0] == nil }).sorted() {
                    let extra = targetByName[name]!
                    actions.append(TransferPlanAction(
                        kind: .trashTarget, sourceURL: nil, targetURL: extra,
                        sourceFingerprint: nil, targetFingerprint: fingerprint(extra), isSelected: true
                    ))
                }
            }
            return
        }

        let actionKind: TransferPlanActionKind
        let selected: Bool
        switch policy {
        case .missingOnly:
            actionKind = .skip; selected = false
        case .newerOnly:
            let sourceDate = sourceFingerprint.modificationDate ?? .distantPast
            let targetDate = targetFingerprint.modificationDate ?? .distantPast
            actionKind = sourceDate > targetDate ? .replace : .skip
            selected = actionKind == .replace
        case .replace, .synchronize:
            actionKind = .replace; selected = true
        case .autoRename:
            let renamedTarget = availableRenameTarget(for: target)
            actions.append(TransferPlanAction(
                kind: .autoRename, sourceURL: source, targetURL: renamedTarget,
                sourceFingerprint: sourceFingerprint, targetFingerprint: nil, isSelected: true
            ))
            return
        }
        actions.append(TransferPlanAction(
            kind: actionKind, sourceURL: source, targetURL: target, sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint, isSelected: selected
        ))
    }

    /// Finder-like conflict names. The candidate is part of the preview and
    /// its nil fingerprint is checked again immediately before execution, so
    /// a racing creator can never be overwritten silently.
    static func availableRenameTarget(for target: URL) -> URL {
        let directory = target.deletingLastPathComponent()
        let ext = target.pathExtension
        let stem = ext.isEmpty ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent
        var sequence = 1
        while true {
            let suffix = sequence == 1 ? " copy" : " copy \(sequence)"
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            sequence += 1
        }
    }

    private static func children(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        )
    }

    static func fingerprint(_ url: URL) -> TransferItemFingerprint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // URLResourceValues may be cached by Foundation. A transfer plan's
        // pre-execution stale check must query the filesystem afresh.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let fileType = attributes[.type] as? FileAttributeType
        return TransferItemFingerprint(
            isDirectory: fileType == .typeDirectory,
            isSymbolicLink: fileType == .typeSymbolicLink,
            size: (attributes[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}

struct TransferExecutionService: Sendable {
    func execute(
        _ plan: TransferExecutionPlan, allowsOverwrite: Bool, allowsDelete: Bool,
        progress: @escaping @Sendable (FileOperationProgress) -> Void = { _ in }
    ) async throws -> OperationOutcome {
        let worker = Task.detached(priority: .userInitiated) {
            var scopedURLs: [URL] = []
            for bookmark in [plan.sourceAccessBookmark, plan.targetAccessBookmark].compactMap({ $0 }) {
                let url = try FileSystemService.resolveBookmark(bookmark)
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            }
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            try Self.validate(plan, allowsOverwrite: allowsOverwrite, allowsDelete: allowsDelete)
            return try Self.executeSynchronously(plan, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func validate(
        _ plan: TransferExecutionPlan, allowsOverwrite: Bool, allowsDelete: Bool
    ) throws {
        guard plan.confirmationStage >= 2 else { throw TransferPlanError.confirmationRequired }
        if plan.selectedActions.contains(where: { $0.kind == .replace }) && !allowsOverwrite {
            throw TransferPlanError.overwriteNotConfirmed
        }
        if plan.selectedActions.contains(where: { $0.kind == .trashTarget }) && !allowsDelete {
            throw TransferPlanError.deletionNotConfirmed
        }
        // Merge rows are descriptive rather than executable, but their
        // directory fingerprints guard against children being added or removed
        // after preview. Executable selected rows protect their own endpoints.
        for action in plan.actions where action.isSelected || action.kind == .merge {
            try Task.checkCancellation()
            if let source = action.sourceURL,
               TransferPlanningService.fingerprint(source) != action.sourceFingerprint {
                throw TransferPlanError.stalePlan
            }
            if action.kind != .autoRename,
               TransferPlanningService.fingerprint(action.targetURL) != action.targetFingerprint {
                throw TransferPlanError.stalePlan
            }
        }
    }

    private static func executeSynchronously(
        _ plan: TransferExecutionPlan, progress: @escaping @Sendable (FileOperationProgress) -> Void
    ) throws -> OperationOutcome {
        var sourceDirectories = Set<URL>()
        var steps: [HistoryStep] = []
        var resultingURLs: [URL] = []
        let total = plan.selectedActions.count
        let totalBytes = (try? FileSystemService.measure(plan.selectedActions.compactMap(\.sourceURL)).bytes) ?? 0
        var completedBytes: Int64 = 0
        progress(.init(completedBytes: 0, totalBytes: totalBytes, completedItems: 0, totalItems: total,
                       currentURL: plan.selectedActions.first?.sourceURL ?? plan.selectedActions.first?.targetURL))
        for action in plan.selectedActions {
            do {
              try Task.checkCancellation()
              let actionBytes = action.sourceURL.flatMap { try? FileSystemService.measure([$0]).bytes } ?? 0
              switch action.kind {
            case .copy:
                guard let source = action.sourceURL else { throw TransferPlanError.stalePlan }
                if plan.kind == .move {
                    try FileManager.default.moveItem(at: source, to: action.targetURL)
                    steps.append(.moved(from: source, to: action.targetURL))
                } else {
                    try FileManager.default.copyItem(at: source, to: action.targetURL)
                    guard let sourceFP = HistoryFingerprint.capture(source), let targetFP = HistoryFingerprint.capture(action.targetURL) else {
                        throw TransferPlanError.stalePlan
                    }
                    steps.append(.copied(source: source, target: action.targetURL, sourceFingerprint: sourceFP, targetFingerprint: targetFP))
                }
                resultingURLs.append(action.targetURL)
                sourceDirectories.insert(source.deletingLastPathComponent())
            case .autoRename:
                guard let source = action.sourceURL else { throw TransferPlanError.stalePlan }
                var destination = action.targetURL
                let originalTarget = plan.targetDirectoryURL.appendingPathComponent(source.lastPathComponent)
                while true {
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) {
                        destination = TransferPlanningService.availableRenameTarget(for: originalTarget)
                    }
                    do {
                        if plan.kind == .move {
                            try FileManager.default.moveItem(at: source, to: destination)
                            steps.append(.moved(from: source, to: destination))
                        } else {
                            try FileManager.default.copyItem(at: source, to: destination)
                            guard let sourceFP = HistoryFingerprint.capture(source),
                                  let targetFP = HistoryFingerprint.capture(destination) else {
                                throw TransferPlanError.stalePlan
                            }
                            steps.append(.copied(source: source, target: destination,
                                                 sourceFingerprint: sourceFP, targetFingerprint: targetFP))
                        }
                        resultingURLs.append(destination)
                        break
                    } catch {
                        // A different process can claim the previewed name
                        // between existence check and copy/move. Retry only
                        // that collision; propagate every other filesystem error.
                        guard FileManager.default.fileExists(atPath: destination.path),
                              FileManager.default.fileExists(atPath: source.path) else { throw error }
                        destination = TransferPlanningService.availableRenameTarget(for: originalTarget)
                    }
                }
                sourceDirectories.insert(source.deletingLastPathComponent())
            case .replace:
                guard let source = action.sourceURL else { throw TransferPlanError.stalePlan }
                guard let sourceFP = HistoryFingerprint.capture(source) else { throw TransferPlanError.stalePlan }
                let staging = action.targetURL.deletingLastPathComponent()
                    .appendingPathComponent(".quadfinder-stage-\(UUID().uuidString)")
                var replacedTrashURL: URL?
                do {
                    try FileManager.default.copyItem(at: source, to: staging)
                    replacedTrashURL = try trash(action.targetURL)
                    try FileManager.default.moveItem(at: staging, to: action.targetURL)
                    if plan.kind == .move { try FileManager.default.removeItem(at: source) }
                    guard let newFP = HistoryFingerprint.capture(action.targetURL) else { throw TransferPlanError.stalePlan }
                    steps.append(.replaced(source: source, target: action.targetURL, oldTrashURL: replacedTrashURL,
                                           sourceFingerprint: sourceFP, newFingerprint: newFP, movesSource: plan.kind == .move))
                    resultingURLs.append(action.targetURL)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    if let replacedTrashURL {
                        if plan.kind == .move, !FileManager.default.fileExists(atPath: source.path),
                           FileManager.default.fileExists(atPath: action.targetURL.path) {
                            try? FileManager.default.moveItem(at: action.targetURL, to: source)
                        } else if FileManager.default.fileExists(atPath: action.targetURL.path) {
                            try? FileManager.default.removeItem(at: action.targetURL)
                        }
                        if !FileManager.default.fileExists(atPath: action.targetURL.path) {
                            try? FileManager.default.moveItem(at: replacedTrashURL, to: action.targetURL)
                        }
                    }
                    throw error
                }
                sourceDirectories.insert(source.deletingLastPathComponent())
            case .trashTarget:
                let trashed = try trash(action.targetURL)
                steps.append(.trashed(original: action.targetURL, trashURL: trashed))
            case .merge, .skip:
                break
              }
              completedBytes += actionBytes
              progress(.init(completedBytes: completedBytes, totalBytes: totalBytes, completedItems: steps.count,
                             totalItems: total, currentURL: action.targetURL))
            } catch {
                throw PartialOperationFailure(outcome: .init(completedBytes: 0, completedItems: steps.count,
                                                              resultingURLs: resultingURLs, historySteps: steps), underlying: error)
            }
        }
        progress(.init(completedBytes: totalBytes, totalBytes: totalBytes, completedItems: total,
                       totalItems: total, currentURL: plan.selectedActions.last?.targetURL))
        if plan.kind == .move {
            // Merge moves may leave now-empty source directories. Never remove a non-empty directory.
            for directory in sourceDirectories.sorted(by: { $0.path.count > $1.path.count }) {
                if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true,
                   plan.sourceURLs.contains(where: { directory.path.hasPrefix($0.path) }) {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
        return OperationOutcome(completedBytes: completedBytes, completedItems: steps.count,
                                resultingURLs: resultingURLs, historySteps: steps)
    }

    private static func trash(_ url: URL) throws -> URL? {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            throw TransferPlanError.trashUnavailable(url)
        }
    }
}
