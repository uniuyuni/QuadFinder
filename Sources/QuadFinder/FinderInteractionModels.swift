import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Shared context-menu model

enum FinderContextAction: String, CaseIterable, Identifiable, Sendable {
    case open, quickLook, openInNewTab, openInOtherPane
    case cut, copy, paste, duplicate, rename, newFolder, trash
    case getInfo, copyPath, revealInFinder, showPackageContents
    var id: String { rawValue }
}

struct FinderContext: Sendable {
    var selectedURLs: [URL]
    var clickedURL: URL?
    var currentDirectory: URL
    var otherPaneCount: Int
    var clipboardContainsFiles: Bool

    var effectiveURLs: [URL] {
        if let clickedURL, !selectedURLs.contains(clickedURL) { return [clickedURL] }
        return selectedURLs
    }
}

struct FinderContextActionModel: Sendable {
    let context: FinderContext

    func isEnabled(_ action: FinderContextAction) -> Bool {
        let urls = context.effectiveURLs
        switch action {
        case .paste, .newFolder: return action == .newFolder || context.clipboardContainsFiles
        case .open, .quickLook, .cut, .copy, .trash, .getInfo, .copyPath, .revealInFinder:
            return !urls.isEmpty
        case .duplicate: return !urls.isEmpty
        case .rename: return urls.count == 1
        case .openInNewTab:
            return urls.count == 1 && isDirectory(urls[0])
        case .openInOtherPane:
            return urls.count == 1 && isDirectory(urls[0]) && context.otherPaneCount > 0
        case .showPackageContents:
            return urls.count == 1 && isPackage(urls[0])
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

// MARK: - Security scope

/// The single source of truth for whether security-scoped bookmarks are
/// required.  `startAccessingSecurityScopedResource()` is deliberately not an
/// environment probe: it commonly returns false for perfectly accessible URLs
/// in a non-sandboxed, ad-hoc signed application.
struct AppSecurityEnvironment: Sendable, Equatable {
    let isSandboxed: Bool

    static let current = AppSecurityEnvironment(isSandboxed: signedSandboxEntitlement())

    static func from(entitlements: [String: Any]) -> AppSecurityEnvironment {
        AppSecurityEnvironment(isSandboxed: entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    }

    private static func signedSandboxEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task, "com.apple.security.app-sandbox" as CFString, nil
        ) as? Bool == true
    }
}

enum SecurityScopeError: LocalizedError {
    case protectedLocation(URL)
    var errorDescription: String? {
        switch self {
        case .protectedLocation(let url):
            "macOSが保護している場所へアクセスできません: \(url.path)。システム設定の「プライバシーとセキュリティ」でQuadFinderへのアクセスを確認してください。通常のユーザーフォルダにフルディスクアクセスは不要です。"
        }
    }
}

/// Keeps one or more security-scoped resources alive for an entire operation.
/// Ad-hoc/local builds are not sandboxed: in that case `startAccessing…` may
/// legitimately return false and must not be interpreted as an access denial.
struct SecurityScopeSession: @unchecked Sendable {
    private(set) var startedURLs: [URL] = []
    let environment: AppSecurityEnvironment

    init(environment: AppSecurityEnvironment = .current) {
        self.environment = environment
    }

    mutating func add(bookmark: Data?, requestedURLs: [URL]) throws {
        guard environment.isSandboxed else { return }
        guard let bookmark else { return }
        guard let resolution = try? FileSystemService.resolveBookmarkWithStatus(bookmark) else { return }
        let scopeURL = resolution.url
        guard requestedURLs.allSatisfy({ SecurityScopeAccess().contains(scopeURL: scopeURL, requestedURL: $0) }) else { return }
        if scopeURL.startAccessingSecurityScopedResource() {
            startedURLs.append(scopeURL)
        }
    }

    mutating func stop() {
        startedURLs.reversed().forEach { $0.stopAccessingSecurityScopedResource() }
        startedURLs.removeAll()
    }
}

struct SecurityScopeAccess: Sendable {
    let environment: AppSecurityEnvironment

    init(environment: AppSecurityEnvironment = .current) {
        self.environment = environment
    }

    func withAccess<T: Sendable>(
        to requestedURL: URL,
        bookmark: Data?,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard environment.isSandboxed else { return try await operation(requestedURL) }
        guard let bookmark else { return try await operation(requestedURL) }
        guard let scopeURL = try? FileSystemService.resolveBookmark(bookmark),
              contains(scopeURL: scopeURL, requestedURL: requestedURL),
              scopeURL.startAccessingSecurityScopedResource() else {
            return try await operation(requestedURL)
        }
        defer { scopeURL.stopAccessingSecurityScopedResource() }
        return try await operation(requestedURL)
    }

    func contains(scopeURL: URL, requestedURL: URL) -> Bool {
        let root = scopeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let requested = requestedURL.resolvingSymlinksInPath().standardizedFileURL.path
        return requested == root || requested.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

// MARK: - Shared trash confirmation

struct PendingTrashRequest: Identifiable, Equatable, Sendable {
    enum Origin: String, Sendable { case contextMenu, keyboard, dragAndDrop }
    let id: UUID
    let urls: [URL]
    let origin: Origin
    let accessBookmark: Data?

    init(id: UUID = UUID(), urls: [URL], origin: Origin, accessBookmark: Data? = nil) {
        self.id = id
        self.urls = urls
        self.origin = origin
        self.accessBookmark = accessBookmark
    }
}

extension WorkspaceStore {
    func prepareTrash(_ urls: [URL], origin: PendingTrashRequest.Origin, accessBookmark: Data? = nil) {
        trashImmediately(urls, accessBookmark: accessBookmark)
    }

    func prepareTrash(urls: [URL], paneID: UUID) {
        if pane(id: paneID) != nil { activate(paneID) }
        trashImmediately(urls, accessBookmark: pane(id: paneID)?.accessBookmark)
    }

    func trashImmediately(_ urls: [URL], accessBookmark: Data? = nil) {
        guard !urls.isEmpty else { return }
        pendingTrash = PendingTrashRequest(urls: urls, origin: .contextMenu, accessBookmark: accessBookmark)
        confirmPendingTrash()
    }

    func confirmPendingTrash() {
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        do {
            var scope: URL?
            if AppSecurityEnvironment.current.isSandboxed, let bookmark = request.accessBookmark {
                scope = try? FileSystemService.resolveBookmark(bookmark)
                if scope == nil || !request.urls.allSatisfy({ SecurityScopeAccess().contains(scopeURL: scope!, requestedURL: $0) }) ||
                    scope!.startAccessingSecurityScopedResource() != true {
                    scope = nil
                }
            }
            defer { scope?.stopAccessingSecurityScopedResource() }
            let outcome = try FinderActionService().moveToTrashRecording(request.urls)
            let allRestorable = outcome.historySteps.allSatisfy { $0.undoabilityReason == nil }
            operationHistory.record(.init(kind: .trash, summary: "\(outcome.completedItems)項目をゴミ箱へ移動", steps: outcome.historySteps,
                                          itemCount: outcome.completedItems,
                                          sourceBookmark: request.accessBookmark, targetBookmark: request.accessBookmark, undoable: allRestorable,
                                          reason: allRestorable ? nil : "OSからゴミ箱内の復元URLを取得できませんでした"))
            for directory in Set(request.urls.map { $0.deletingLastPathComponent() }) {
                NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: directory)
            }
            if let pane = activePane { setSelection([], in: pane.id) }
        } catch let partial as PartialOperationFailure {
            if !partial.outcome.historySteps.isEmpty {
                let reason = partial.outcome.historySteps.compactMap(\.undoabilityReason).first
                operationHistory.record(.init(kind: .trash, summary: "\(partial.outcome.completedItems)項目をゴミ箱へ移動（一部完了）",
                    steps: partial.outcome.historySteps, itemCount: partial.outcome.completedItems,
                    sourceBookmark: request.accessBookmark, targetBookmark: request.accessBookmark,
                    undoable: reason == nil, reason: reason))
            }
            report("ゴミ箱へ移動できません", error: partial.underlying)
        } catch { report("ゴミ箱へ移動できません", error: error) }
    }
}

struct TrashConfirmationModifier: ViewModifier {
    @EnvironmentObject private var workspace: WorkspaceStore
    func body(content: Content) -> some View {
        content.confirmationDialog(
            "ゴミ箱に入れますか？",
            isPresented: Binding(
                get: { workspace.pendingTrash != nil },
                set: { if !$0 { workspace.pendingTrash = nil } }
            ), titleVisibility: .visible
        ) {
            Button("ゴミ箱に入れる", role: .destructive) { workspace.confirmPendingTrash() }
            Button("キャンセル", role: .cancel) { workspace.pendingTrash = nil }
        } message: {
            Text("\(workspace.pendingTrash?.urls.count ?? 0)項目をゴミ箱に移動します。完全削除は行いません。")
        }
    }
}

extension View {
    func trashConfirmation() -> some View { modifier(TrashConfirmationModifier()) }
}

// MARK: - Get Info

struct FinderItemInfo: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let created: Date?
    let modified: Date?
    let kind: String
    let permissions: String
    var id: URL { url }
}

struct FolderSizeResult: Equatable, Sendable {
    var logicalBytes: Int64 = 0
    var itemCount = 0
    var errorCount = 0
}

struct FolderSizeProgress: Equatable, Sendable {
    var itemCount: Int
    var currentPath: String
    var isCached = false
}

struct FolderSizeCalculator: Sendable {
    private struct RootStamp: Hashable, Sendable {
        let path: String
        let modificationDate: Date?
        let fileSize: Int?
    }

    private actor ResultCache {
        struct Entry: Sendable {
            let result: FolderSizeResult
            let storedAt: ContinuousClock.Instant
        }

        private var entries: [[RootStamp]: Entry] = [:]
        private let lifetime: Duration = .seconds(15)

        func value(for key: [RootStamp], now: ContinuousClock.Instant) -> FolderSizeResult? {
            entries = entries.filter { now - $0.value.storedAt < lifetime }
            return entries[key]?.result
        }

        func insert(_ result: FolderSizeResult, for key: [RootStamp], now: ContinuousClock.Instant) {
            entries[key] = Entry(result: result, storedAt: now)
        }

        func invalidate(url: URL) {
            let changedPath = url.standardizedFileURL.path
            entries = entries.filter { key, _ in
                !key.contains { stamp in
                    Self.contains(path: stamp.path, otherPath: changedPath)
                        || Self.contains(path: changedPath, otherPath: stamp.path)
                }
            }
        }

        func invalidateAll() { entries.removeAll() }

        private static func contains(path: String, otherPath: String) -> Bool {
            if path == otherPath { return true }
            return otherPath.hasPrefix(path == "/" ? "/" : path + "/")
        }
    }

    private static let cache = ResultCache()

    static func invalidate(url: URL) async { await cache.invalidate(url: url) }
    static func invalidateAll() async { await cache.invalidateAll() }

    /// Counts logical file sizes. Directory symlinks are never followed and
    /// packages are treated as folders so their complete on-disk contents are counted.
    func calculate(
        urls: [URL],
        useCache: Bool = true,
        elapsedTime: (@Sendable () -> Duration)? = nil,
        progress: @escaping @Sendable (FolderSizeProgress) async -> Void = { _ in }
    ) async throws -> FolderSizeResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let elapsed: @Sendable () -> Duration
        if let elapsedTime { elapsed = elapsedTime }
        else { elapsed = { clock.now - startedAt } }
        let cacheKey = urls.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return RootStamp(path: url.standardizedFileURL.path,
                             modificationDate: values?.contentModificationDate,
                             fileSize: values?.fileSize)
        }
        if useCache, let cached = await Self.cache.value(for: cacheKey, now: clock.now) {
            try Task.checkCancellation()
            await progress(.init(itemCount: cached.itemCount,
                                 currentPath: urls.first?.path ?? "", isCached: true))
            return cached
        }

        var result = FolderSizeResult()
        var lastProgressAt: Duration = .zero
        var lastPath = urls.first?.path ?? ""

        // UI updates are intentionally capped at twice per second. Cancellation
        // is still checked for every enumerated item and is not throttled.
        func reportProgressIfNeeded(path: String, force: Bool = false) async {
            lastPath = path
            let now = elapsed()
            guard force || now - lastProgressAt >= .milliseconds(500) else { return }
            lastProgressAt = now
            await progress(.init(itemCount: result.itemCount, currentPath: path))
        }

        // Initial and final states are delivered immediately.
        await reportProgressIfNeeded(path: lastPath, force: true)

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for root in urls {
            try Task.checkCancellation()
            let rootValues = try? root.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))
            if rootValues?.isDirectory != true {
                if rootValues?.isSymbolicLink != true {
                    result.logicalBytes = safeAdd(result.logicalBytes, Int64(rootValues?.fileSize ?? 0))
                }
                result.itemCount += 1
                await reportProgressIfNeeded(path: root.path)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [], errorHandler: { _, _ in true }
            ) else { result.errorCount += 1; continue }
            while let child = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                do {
                    let values = try child.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true {
                        // FileManager's directory enumerator does not follow
                        // directory symlinks. Calling skipDescendants here can
                        // skip an unrelated pending sibling depending on order.
                    } else if values.isRegularFile == true {
                        result.logicalBytes = safeAdd(result.logicalBytes, Int64(values.fileSize ?? 0))
                    }
                    result.itemCount += 1
                    await reportProgressIfNeeded(path: child.path)
                } catch { result.errorCount += 1 }
            }
        }
        await reportProgressIfNeeded(path: lastPath, force: true)
        try Task.checkCancellation()
        if useCache { await Self.cache.insert(result, for: cacheKey, now: clock.now) }
        return result
    }

    private func safeAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

@MainActor
final class GetInfoModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var items: [FinderItemInfo] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var folderSize: FolderSizeResult?
    @Published private(set) var folderSizeProgress: FolderSizeProgress?
    @Published private(set) var isCalculatingSize = false
    private var sizeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadedURLs: [URL] = []
    private var bookmark: Data?

    func load(urls: [URL], bookmark: Data? = nil) {
        loadedURLs = urls
        self.bookmark = bookmark
        folderSize = nil
        guard !urls.isEmpty else { items = []; errorMessage = nil; return }
        loadTask?.cancel()
        loadTask = Task {
            do {
                items = try await Task.detached(priority: .userInitiated) {
                    var scope = SecurityScopeSession()
                    try scope.add(bookmark: bookmark, requestedURLs: urls)
                    defer { scope.stop() }
                    return try urls.map { url in
                        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .creationDateKey,
                            .contentModificationDateKey, .localizedTypeDescriptionKey, .fileSecurityKey]
                        let values = try url.resourceValues(forKeys: keys)
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        let permissions = (attributes?[.posixPermissions] as? NSNumber)
                            .map { String(format: "%03o", $0.intValue) } ?? "—"
                        return FinderItemInfo(
                            url: url, isDirectory: values.isDirectory == true,
                            size: values.fileSize.map(Int64.init), created: values.creationDate,
                            modified: values.contentModificationDate,
                            kind: values.localizedTypeDescription ?? "不明", permissions: permissions
                        )
                    }
                }.value
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func waitForLoad() async { await loadTask?.value }

    func calculateFolderSize() {
        let folders = items.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty, !isCalculatingSize else { return }
        isCalculatingSize = true
        folderSizeProgress = .init(itemCount: 0, currentPath: folders[0].path)
        let bookmark = self.bookmark
        sizeTask = Task {
            do {
                var scope = SecurityScopeSession()
                try scope.add(bookmark: bookmark, requestedURLs: folders)
                defer { scope.stop() }
                let result = try await FolderSizeCalculator().calculate(urls: folders, progress: { value in
                    await MainActor.run { self.folderSizeProgress = value }
                })
                folderSize = result
            } catch is CancellationError {
                // Cancellation deliberately retains no misleading partial total.
            } catch { errorMessage = error.localizedDescription }
            isCalculatingSize = false
        }
    }

    func cancelFolderSize() {
        sizeTask?.cancel()
        sizeTask = nil
        isCalculatingSize = false
    }

    /// Requests a folder once and retries the exact failed Get Info request
    /// with the panel-returned authority. Cancellation is intentionally silent.
    func authorizeAndRetry() {
        guard !loadedURLs.isEmpty else { return }
        let authorizationURLs = loadedURLs.map { url -> URL in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
                ? url : url.deletingLastPathComponent()
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "許可"
        panel.message = "対象を含むフォルダを選択してください。"
        panel.directoryURL = authorizationURLs.first
        guard panel.runModal() == .OK, let grantedURL = panel.url else { return }
        let access = SecurityScopeAccess()
        guard authorizationURLs.allSatisfy({ access.contains(scopeURL: grantedURL, requestedURL: $0) }) else {
            errorMessage = "選択したフォルダには対象項目が含まれていません。対象を含むフォルダを選択してください。"
            return
        }
        let persistedBookmark = try? FileSystemService.bookmark(for: grantedURL)
        load(urls: loadedURLs, bookmark: persistedBookmark)
    }
}

struct GetInfoSheet: View {
    @ObservedObject var model: GetInfoModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("情報を見る").font(.title2.bold()); Spacer(); Button("閉じる") { dismiss() } }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("フォルダを選択して許可…") { model.authorizeAndRetry() }
            }
            if model.items.contains(where: \.isDirectory) {
                HStack {
                    if model.isCalculatingSize {
                        ProgressView().controlSize(.small).accessibilityLabel("フォルダサイズを計算中")
                        Text("\(model.folderSizeProgress?.itemCount ?? 0)項目を計算中…")
                        Spacer()
                        Button("キャンセル") { model.cancelFolderSize() }
                    } else {
                        Button("フォルダサイズを計算") { model.calculateFolderSize() }
                        if let size = model.folderSize {
                            Text("論理サイズ \(ByteCountFormatter.string(fromByteCount: size.logicalBytes, countStyle: .file))（\(size.itemCount)項目、読取エラー \(size.errorCount)）")
                                .foregroundStyle(size.errorCount == 0 ? Color.secondary : Color.orange)
                                .help("ファイル内容の論理サイズです。APFSの共有ブロックや圧縮を反映したディスク使用量ではありません。")
                        }
                    }
                }
            }
            List(model.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.url.lastPathComponent, systemImage: item.isDirectory ? "folder" : "doc")
                    Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("種類: \(item.kind)　サイズ: \(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")　アクセス権: \(item.permissions)")
                        .font(.caption)
                    Text("作成: \(item.created?.formatted(date: .numeric, time: .standard) ?? "—")　変更: \(item.modified?.formatted(date: .numeric, time: .standard) ?? "—")")
                        .font(.caption)
                }
            }
        }.padding().frame(minWidth: 520, minHeight: 320)
    }
}

// MARK: - Persistent sidebar model

struct SidebarFavorite: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var bookmark: Data?
    var isDefault: Bool
    init(id: UUID = UUID(), name: String, url: URL, bookmark: Data? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.bookmark = bookmark; self.isDefault = isDefault
    }
}

struct SidebarRecentItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, file }
    var id: URL { url.standardizedFileURL }
    var url: URL
    var kind: Kind
    var lastAccessed: Date
    var bookmark: Data?

    init(url: URL, kind: Kind, lastAccessed: Date, bookmark: Data? = nil) {
        self.url = url; self.kind = kind; self.lastAccessed = lastAccessed; self.bookmark = bookmark
    }
}

protocol SidebarPreferences: Sendable {
    func sidebarData(forKey key: String) -> Data?
    func setSidebarData(_ data: Data?, forKey key: String)
}

extension UserDefaults: @unchecked @retroactive Sendable {}
extension UserDefaults: SidebarPreferences {
    func sidebarData(forKey key: String) -> Data? { data(forKey: key) }
    func setSidebarData(_ data: Data?, forKey key: String) { set(data, forKey: key) }
}

struct SidebarEjectError: LocalizedError, Sendable {
    let deviceName: String
    let underlyingDescription: String

    init(deviceName: String, underlying: Error) {
        self.deviceName = deviceName
        self.underlyingDescription = underlying.localizedDescription
    }

    var errorDescription: String? {
        "「\(deviceName)」を取り出せませんでした。使用中のファイルやアプリを閉じて、もう一度お試しください。\n\(underlyingDescription)"
    }
}

@MainActor
final class SidebarStore: ObservableObject {
    static let minimumWidth = 90.0
    static let maximumWidth = 360.0
    @Published private(set) var favorites: [SidebarFavorite]
    @Published private(set) var devices: [SidebarLocation] = []
    @Published private(set) var ejectingDeviceIDs: Set<URL> = []
    @Published private(set) var recents: [SidebarRecentItem]
    @Published var isVisible: Bool { didSet { save() } }
    /// The displayed width. During a drag this changes without writing preferences;
    /// committing only once avoids layout feedback making the divider jitter.
    @Published private(set) var width: Double
    private var dragOriginWidth: Double?

    private struct State: Codable {
        var version: Int?
        var favorites: [SidebarFavorite]
        var isVisible: Bool
        var width: Double
        var recents: [SidebarRecentItem]?
    }
    private let preferences: any SidebarPreferences
    private let key = "QuadFinder.Sidebar.v1"
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(preferences: any SidebarPreferences = UserDefaults.standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.preferences = preferences
        let defaults = Self.defaultFavorites(home: home)
        if let data = preferences.sidebarData(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) {
            favorites = state.favorites
            isVisible = state.isVisible
            let migratedWidth = state.version == nil && state.width == 190 ? 100 : state.width
            width = min(max(migratedWidth, Self.minimumWidth), Self.maximumWidth)
            recents = state.recents ?? []
        } else {
            favorites = defaults
            isVisible = true
            width = 100
            recents = []
        }
        refreshDevices()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } })
        observers.append(NotificationCenter.default.addObserver(forName: .quadFinderRecentAccess, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL,
                  let rawKind = note.userInfo?["kind"] as? String,
                  let kind = SidebarRecentItem.Kind(rawValue: rawKind) else { return }
            let bookmark = note.userInfo?["bookmark"] as? Data
            Task { @MainActor in self?.recordRecent(url, kind: kind, bookmark: bookmark) }
        })
    }

    func setWidth(_ proposed: Double) {
        let clamped = Self.clampedWidth(proposed)
        guard width != clamped else { return }
        width = clamped
        save()
    }

    @discardableResult
    func beginWidthDrag() -> Double {
        if dragOriginWidth == nil { dragOriginWidth = width }
        return dragOriginWidth!
    }

    func updateWidthDrag(translation: Double) {
        let origin = beginWidthDrag()
        width = Self.clampedWidth(origin + translation)
    }

    func endWidthDrag() {
        guard dragOriginWidth != nil else { return }
        dragOriginWidth = nil
        save()
    }

    static func clampedWidth(_ value: Double) -> Double {
        min(max(value, minimumWidth), maximumWidth)
    }

    static func defaultFavorites(home: URL) -> [SidebarFavorite] {
        [("ホーム", home), ("デスクトップ", home.appendingPathComponent("Desktop")),
         ("書類", home.appendingPathComponent("Documents")), ("ダウンロード", home.appendingPathComponent("Downloads")),
         ("ゴミ箱", home.appendingPathComponent(".Trash"))]
            .map { SidebarFavorite(name: $0.0, url: $0.1, isDefault: true) }
    }

    func addCustom(name: String, url: URL, bookmark: Data) {
        guard !favorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        favorites.append(SidebarFavorite(name: name, url: url, bookmark: bookmark)); save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) { favorites.move(fromOffsets: fromOffsets, toOffset: toOffset); save() }
    func remove(id: UUID) { favorites.removeAll { $0.id == id && !$0.isDefault }; save() }

    func refreshDevices() {
        devices = SidebarLocationsProvider().locations().filter { $0.section == .devices }
    }

    /// Unmounts and ejects a device using the same Workspace service Finder uses.
    /// The injected action keeps policy testable without mounting test media.
    func eject(_ device: SidebarLocation,
               action: @escaping @Sendable (URL) async throws -> Void = { url in
                   try NSWorkspace.shared.unmountAndEjectDevice(at: url)
               }) async throws {
        guard device.section == .devices, device.isEjectable else {
            throw CocoaError(.featureUnsupported)
        }
        guard !ejectingDeviceIDs.contains(device.id) else { return }
        ejectingDeviceIDs.insert(device.id)
        defer { ejectingDeviceIDs.remove(device.id) }
        do {
            try await action(device.url)
            refreshDevices()
        } catch {
            throw SidebarEjectError(deviceName: device.name, underlying: error)
        }
    }

    func recordRecent(_ url: URL, kind: SidebarRecentItem.Kind, date: Date = Date(), bookmark: Data? = nil) {
        let normalized = url.standardizedFileURL
        let existingBookmark = recents.first(where: { $0.url.standardizedFileURL == normalized })?.bookmark
        recents.removeAll { $0.url.standardizedFileURL == normalized }
        recents.insert(SidebarRecentItem(url: normalized, kind: kind, lastAccessed: date,
                                         bookmark: bookmark ?? existingBookmark), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        save()
    }

    func clearRecents() { recents.removeAll(); save() }
    func removeRecent(_ url: URL) { recents.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }; save() }

    private func save() {
        guard let data = try? JSONEncoder().encode(State(version: 3, favorites: favorites, isVisible: isVisible, width: width, recents: recents)) else { return }
        preferences.setSidebarData(data, forKey: key)
    }

    func stopObservingMounts() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

struct PersistentFinderSidebarView: View {
    static let compactRowHeight: CGFloat = 14
    @ObservedObject var store: SidebarStore
    let navigate: (SidebarFavorite) -> Void
    let openRecent: (SidebarRecentItem) -> Void

    var body: some View {
        List {
            Section("よく使う項目") {
                ForEach(store.favorites) { favorite in
                    favoriteRow(favorite)
                }
                .onMove(perform: store.move)
            }
            Section("デバイス") {
                ForEach(store.devices) { device in
                    deviceRow(device)
                }
            }
            if !store.recents.isEmpty {
                Section("履歴") {
                    ForEach(store.recents) { recent in
                        recentRow(recent)
                    }
                    Button("履歴を消去", role: .destructive) { store.clearRecents() }
                        .font(.caption)
                }
            }
        }
        .font(.system(size: 10.5))
        .controlSize(.mini)
        .environment(\.defaultMinListRowHeight, Self.compactRowHeight)
        .listStyle(.sidebar)
        .frame(minWidth: 90, idealWidth: store.width, maxWidth: 360)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                guard let bookmark = try? FileSystemService.bookmark(for: url) else { continue }
                store.addCustom(name: url.lastPathComponent, url: url, bookmark: bookmark)
            }
            return !urls.isEmpty
        }
    }

    private func favoriteRow(_ favorite: SidebarFavorite) -> some View {
        Button { navigate(favorite) } label: {
            Label(favorite.name, systemImage: favorite.name == "ゴミ箱" ? "trash" : "folder")
                .imageScale(.small).frame(maxWidth: .infinity, alignment: .leading).frame(height: Self.compactRowHeight)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !favorite.isDefault { Button("サイドバーから取り除く") { store.remove(id: favorite.id) } }
            Button("パスをコピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(favorite.url.path, forType: .string) }
        }
        .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 4))
    }

    private func deviceRow(_ device: SidebarLocation) -> some View {
        HStack(spacing: 4) {
            Button { navigate(SidebarFavorite(name: device.name, url: device.url, isDefault: true)) } label: {
                Label(device.name, systemImage: device.systemImage).imageScale(.small)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).frame(height: Self.compactRowHeight)
            }.buttonStyle(.plain)
            if device.isEjectable {
                Button { eject(device) } label: {
                    if store.ejectingDeviceIDs.contains(device.id) { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "eject.fill").font(.caption).foregroundStyle(.secondary).contentShape(Rectangle()) }
                }
                .buttonStyle(.plain).disabled(store.ejectingDeviceIDs.contains(device.id))
                .help("\(device.name)を取り出す").accessibilityLabel("\(device.name)を取り出す")
            }
        }
        .contextMenu { if device.isEjectable { Button("取り出す") { eject(device) }.disabled(store.ejectingDeviceIDs.contains(device.id)) } }
        .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 4))
    }

    private func recentRow(_ recent: SidebarRecentItem) -> some View {
        Button { openRecent(recent) } label: {
            Label(recent.url.lastPathComponent.isEmpty ? recent.url.path : recent.url.lastPathComponent,
                  systemImage: !FileManager.default.fileExists(atPath: recent.url.path) ? "questionmark.diamond" : (recent.kind == .folder ? "folder" : "doc"))
                .imageScale(.small).frame(maxWidth: .infinity, alignment: .leading).frame(height: Self.compactRowHeight)
        }
        .buttonStyle(.plain).help(recent.url.path(percentEncoded: false))
        .contextMenu { Button("履歴から削除") { store.removeRecent(recent.url) } }
        .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 4))
    }

    private func eject(_ device: SidebarLocation) {
        Task {
            do { try await store.eject(device); NotificationCenter.default.post(name: .quadFinderSidebarDidEject, object: device.url) }
            catch { NotificationCenter.default.post(name: .quadFinderSidebarEjectFailed, object: device.url, userInfo: ["error": error]) }
        }
    }
}
