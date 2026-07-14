import Foundation

struct PaneLinkGroup: Codable, Equatable, Sendable {
    var paneIDs: Set<UUID>
    var followsRelativeNavigation: Bool
    var followsSelection: Bool
}

enum ComparisonClassification: String, Codable, CaseIterable, Sendable {
    case onlySource = "ソースのみ"
    case onlyTarget = "ターゲットのみ"
    case different = "差異あり"
    case equal = "同一"
    case error = "エラー"

    var localizedTitle: String { L10n.tr(rawValue) }
}

struct DirectoryEntryFingerprint: Codable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let checksum: String?
    let cloudStatus: String?
}

struct DirectorySnapshot: Codable, Equatable, Sendable {
    let directoryURL: URL
    let entries: [String: DirectoryEntryFingerprint]
}

struct ComparisonEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let source: DirectoryEntryFingerprint?
    let target: DirectoryEntryFingerprint?
    let classification: ComparisonClassification
    let message: String?
}

struct FolderComparisonResult: Codable, Equatable, Sendable {
    let sourcePaneID: UUID
    let targetPaneID: UUID
    let sourceURL: URL
    let targetURL: URL
    let sourceBookmark: Data?
    let targetBookmark: Data?
    let usesChecksums: Bool
    let sourceSnapshot: DirectorySnapshot
    let targetSnapshot: DirectorySnapshot
    let entries: [ComparisonEntry]
}

enum SyncMode: String, Codable, CaseIterable, Sendable {
    case oneWayUpdate = "片方向更新"
    case oneWayMirror = "片方向ミラー"
    case missingOnly = "欠落項目のみ"

    var localizedTitle: String { L10n.tr(rawValue) }
}

enum SyncActionKind: String, Codable, Sendable {
    case create = "作成"
    case overwrite = "上書き"
    case delete = "削除"

    var localizedTitle: String { L10n.tr(rawValue) }
}

struct SyncAction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: SyncActionKind
    let sourceURL: URL?
    let targetURL: URL

    init(id: UUID = UUID(), kind: SyncActionKind, sourceURL: URL?, targetURL: URL) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.targetURL = targetURL
    }
}

struct SyncExecutionPlan: Codable, Equatable, Sendable {
    let mode: SyncMode
    let sourceSnapshot: DirectorySnapshot
    let targetSnapshot: DirectorySnapshot
    let sourceBookmark: Data?
    let targetBookmark: Data?
    let actions: [SyncAction]
    let allowsOverwrite: Bool
    let allowsDelete: Bool
    let confirmationStage: Int

    var createCount: Int { actions.count { $0.kind == .create } }
    var overwriteCount: Int { actions.count { $0.kind == .overwrite } }
    var deleteCount: Int { actions.count { $0.kind == .delete } }
}

enum SyncSafetyError: LocalizedError, Equatable {
    case previewRequired
    case overwriteNotEnabled
    case deleteNotEnabled
    case secondConfirmationRequired
    case staleSnapshot
    case trashUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .previewRequired: L10n.tr("同期プレビューがありません。再比較してください。")
        case .overwriteNotEnabled: L10n.tr("上書きは明示的に有効化されていません。")
        case .deleteNotEnabled: L10n.tr("削除は明示的に有効化されていません。")
        case .secondConfirmationRequired: L10n.tr("完全パスを確認する二段階目の確認が完了していません。")
        case .staleSnapshot: L10n.tr("比較後にフォルダ内容が変化しました。再比較が必要です。")
        case .trashUnavailable(let url): L10n.format("項目をゴミ箱へ移動できません。完全削除は行いません: %@", url.path)
        }
    }
}

enum WindowScopePolicy: String, Sendable {
    case singleWindow
}
