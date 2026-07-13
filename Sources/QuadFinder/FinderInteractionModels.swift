import AppKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

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
    private var dragOriginScreenX: Double?

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

    /// Uses a fixed window/global coordinate so moving the divider cannot feed
    /// back into the gesture's coordinate system and make the width oscillate.
    func updateWidthDrag(screenX: Double, startScreenX: Double) {
        if dragOriginScreenX == nil {
            dragOriginScreenX = startScreenX
            _ = beginWidthDrag()
        }
        guard let originX = dragOriginScreenX, let originWidth = dragOriginWidth else { return }
        width = Self.clampedWidth(originWidth + screenX - originX)
    }

    func endWidthDrag() {
        guard dragOriginWidth != nil else { return }
        dragOriginWidth = nil
        dragOriginScreenX = nil
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
        insertCustom(name: name, url: url, bookmark: bookmark, at: favorites.endIndex)
    }

    func insertCustom(name: String, url: URL, bookmark: Data, at index: Int) {
        guard !favorites.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        favorites.insert(SidebarFavorite(name: name, url: url, bookmark: bookmark),
                         at: min(max(index, 0), favorites.endIndex))
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) { favorites.move(fromOffsets: fromOffsets, toOffset: toOffset); save() }
    func moveFavorite(id: UUID, toOffset: Int) {
        guard let source = favorites.firstIndex(where: { $0.id == id }) else { return }
        var destination = min(max(toOffset, 0), favorites.count)
        let favorite = favorites.remove(at: source)
        if source < destination { destination -= 1 }
        favorites.insert(favorite, at: min(destination, favorites.count))
        save()
    }
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

// MARK: - Finder sidebar drop routing

enum SidebarDropZone: Equatable, Sendable {
    case directory(URL)
    case trash
    case favoritesInsertion(Int)
    case unavailable
}

enum SidebarDropResolution: Equatable, Sendable {
    case transfer(target: URL)
    case trash
    case addFavorites(urls: [URL], index: Int)
    case reorderFavorite(id: UUID, index: Int)
    case reject
}

/// Separates filesystem destinations from Favorites insertion.  A URL dropped
/// on a row is always a file operation; only an insertion gap can mutate the
/// sidebar model, and regular files are never accepted as Favorites.
enum SidebarDropResolver {
    static func resolve(zone: SidebarDropZone, urls: [URL], favoriteID: UUID? = nil,
                        isDirectory: (URL) -> Bool = Self.isDirectory) -> SidebarDropResolution {
        switch zone {
        case .directory(let target):
            return urls.isEmpty ? .reject : .transfer(target: target.standardizedFileURL)
        case .trash:
            return urls.isEmpty ? .reject : .trash
        case .favoritesInsertion(let index):
            if let favoriteID { return .reorderFavorite(id: favoriteID, index: index) }
            guard !urls.isEmpty, urls.allSatisfy(isDirectory) else { return .reject }
            return .addFavorites(urls: urls.map(\.standardizedFileURL), index: index)
        case .unavailable:
            return .reject
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Maps a pointer inside a Favorites row to an insertion offset.  Keeping this
/// calculation independent of SwiftUI's narrow insertion overlays makes a
/// reorder deterministic across the entire row.
enum SidebarFavoriteDropPlacement {
    static func insertionIndex(row: Int, pointerY: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return row }
        // NSView coordinates grow upward: the visual upper half inserts before
        // the row and the lower half inserts after it.
        return pointerY >= rowHeight / 2 ? row : row + 1
    }

    /// External folders use the outer quarters as insertion targets; the
    /// middle half is an unambiguous drop *on* the destination folder.
    static func externalInsertionIndex(row: Int, pointerY: CGFloat, rowHeight: CGFloat) -> Int? {
        guard rowHeight > 0 else { return nil }
        if pointerY >= rowHeight * 0.75 { return row }
        if pointerY <= rowHeight * 0.25 { return row + 1 }
        return nil
    }
}

enum SidebarDraggingPasteboard {
    static let favoriteType = NSPasteboard.PasteboardType(UTType.quadFinderSidebarFavorite.identifier)
    static let batchType = NSPasteboard.PasteboardType(UTType.quadFinderPaneBatch.identifier)

    static func contents() -> (urls: [URL], sourcePaneID: UUID?, favoriteID: UUID?) {
        contents(from: NSPasteboard(name: .drag))
    }

    static func contents(from pasteboard: NSPasteboard) -> (urls: [URL], sourcePaneID: UUID?, favoriteID: UUID?) {
        let panePayloads = NativeFileDragPasteboard.payloads(from: pasteboard.pasteboardItems ?? [])
        let batches = (pasteboard.pasteboardItems ?? []).compactMap { item -> [PaneFileDragPayload]? in
            guard let data = item.data(forType: batchType),
                  let batch = try? JSONDecoder().decode(PaneFileDragBatchPayload.self, from: data) else { return nil }
            return batch.payloads
        }.flatMap { $0 }
        let allPanePayloads = panePayloads + batches
        let urls = Array(Set(NativeFileDragPasteboard.urls(from: pasteboard) + allPanePayloads.map(\.url)))
            .sorted { $0.path < $1.path }
        let sourcePaneID: UUID? = {
            guard let first = allPanePayloads.first?.sourcePaneID,
                  allPanePayloads.allSatisfy({ $0.sourcePaneID == first }) else { return nil }
            return first
        }()
        let favoriteID = (pasteboard.pasteboardItems ?? []).compactMap { item -> UUID? in
            guard let data = item.data(forType: favoriteType),
                  let payload = try? JSONDecoder().decode(SidebarFavoriteDragPayload.self, from: data) else { return nil }
            return payload.id
        }.first
        return (urls, sourcePaneID, favoriteID)
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let zone: SidebarDropZone
    let targetBookmark: Data?
    @Binding var isTargeted: Bool
    let perform: (SidebarDropResolution, [URL], UUID?, Data?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let content = SidebarDraggingPasteboard.contents()
        return SidebarDropResolver.resolve(zone: zone, urls: content.urls,
                                           favoriteID: content.favoriteID) != .reject
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let content = SidebarDraggingPasteboard.contents()
        let resolution = SidebarDropResolver.resolve(zone: zone, urls: content.urls,
                                                     favoriteID: content.favoriteID)
        guard resolution != .reject else { return DropProposal(operation: .cancel) }
        switch resolution {
        case .trash: return DropProposal(operation: .move)
        case .transfer(let target):
            let modifiers = DropModifierResolver.resolve(current: NSApp.currentEvent?.modifierFlags,
                                                         tracked: DragModifierTracker.shared.trackedFlags)
            let native = FinderDragOperationPolicy.operation(sourceURLs: content.urls,
                                                              targetDirectory: target,
                                                              modifiers: modifiers)
            // SwiftUI's DropOperation has no link case. Filesystem destination
            // rows use SidebarDropNSView below and therefore return the real
            // NSDragOperation.link; this delegate is only used by insertion gaps.
            return DropProposal(operation: native == .move ? .move : .copy)
        case .addFavorites, .reorderFavorite:
            return DropProposal(operation: .move)
        case .reject:
            return DropProposal(operation: .cancel)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let content = SidebarDraggingPasteboard.contents()
        let resolution = SidebarDropResolver.resolve(zone: zone, urls: content.urls,
                                                     favoriteID: content.favoriteID)
        guard resolution != .reject else { isTargeted = false; return false }
        isTargeted = false
        perform(resolution, content.urls, content.sourcePaneID, targetBookmark)
        return true
    }
}

/// AppKit destination used for actual sidebar folder rows.  Unlike SwiftUI's
/// DropProposal it can return `.link`, so Option+Command shows the native link
/// cursor while the drag is still in flight.
private struct SidebarNativeDropTarget: NSViewRepresentable {
    let zone: SidebarDropZone
    let targetBookmark: Data?
    @Binding var isTargeted: Bool
    let perform: (SidebarDropResolution, [URL], UUID?, Data?) -> Void
    var favoriteDragID: UUID? = nil
    var favoriteDragName: String? = nil
    var favoriteIndex: Int? = nil
    var favoriteClicked: (() -> Void)? = nil

    func makeNSView(context: Context) -> SidebarDropNSView {
        let view = SidebarDropNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: SidebarDropNSView, context: Context) { update(nsView) }

    private func update(_ view: SidebarDropNSView) {
        view.zone = zone
        view.targetBookmark = targetBookmark
        view.targeted = { value in isTargeted = value }
        view.perform = perform
        view.favoriteDragID = favoriteDragID
        view.favoriteDragName = favoriteDragName
        view.favoriteIndex = favoriteIndex
        view.favoriteClicked = favoriteClicked
        view.setAccessibilityElement(favoriteDragID != nil)
        view.setAccessibilityLabel(favoriteDragName)
    }
}

final class SidebarDropNSView: NSView, NSDraggingSource {
    var zone: SidebarDropZone = .unavailable
    var targetBookmark: Data?
    var targeted: ((Bool) -> Void)?
    var perform: ((SidebarDropResolution, [URL], UUID?, Data?) -> Void)?
    var favoriteDragID: UUID?
    var favoriteDragName: String?
    var favoriteIndex: Int?
    var favoriteClicked: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, NativeFileDragPasteboard.paneItemType,
                                 SidebarDraggingPasteboard.batchType,
                                 SidebarDraggingPasteboard.favoriteType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The representable is layered above a SwiftUI Button. It participates in
    /// drag hit-testing but passes ordinary clicks through to that button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return favoriteDragID == nil ? nil : self
        case .rightMouseDown, .rightMouseUp, .mouseMoved, .otherMouseDown, .otherMouseUp:
            return nil
        default:
            return super.hitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let favoriteDragID, let window else { return }
        let origin = convert(event.locationInWindow, from: nil)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                favoriteClicked?()
                return
            }
            let current = convert(next.locationInWindow, from: nil)
            guard hypot(current.x - origin.x, current.y - origin.y) >= 3 else { continue }
            beginFavoriteDrag(id: favoriteDragID, event: next)
            return
        }
    }

    private func beginFavoriteDrag(id: UUID, event: NSEvent) {
        let item = NSPasteboardItem()
        guard let data = try? JSONEncoder().encode(SidebarFavoriteDragPayload(id: id)) else { return }
        item.setData(data, forType: SidebarDraggingPasteboard.favoriteType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(systemSymbolName: "folder", accessibilityDescription: favoriteDragName)
        let frame = NSRect(x: bounds.minX + 4, y: bounds.midY - 8, width: 16, height: 16)
        draggingItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender, updateTarget: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender, updateTarget: true)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted?(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        operation(for: sender, updateTarget: false) != []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let content = SidebarDraggingPasteboard.contents(from: sender.draggingPasteboard)
        let resolution = resolution(for: sender, content: content)
        targeted?(false)
        guard resolution != .reject else { return false }
        perform?(resolution, content.urls, content.sourcePaneID, targetBookmark)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { targeted?(false) }

    private func operation(for sender: any NSDraggingInfo, updateTarget: Bool) -> NSDragOperation {
        let content = SidebarDraggingPasteboard.contents(from: sender.draggingPasteboard)
        let resolution = resolution(for: sender, content: content)
        if updateTarget { targeted?(resolution != .reject) }
        switch resolution {
        case .trash:
            return .move
        case .transfer(let target):
            let flags = DropModifierResolver.resolve(current: NSApp.currentEvent?.modifierFlags,
                                                     tracked: DragModifierTracker.shared.trackedFlags)
            return FinderDragOperationPolicy.operation(sourceURLs: content.urls,
                                                        targetDirectory: target,
                                                        modifiers: flags)
        case .addFavorites, .reorderFavorite:
            return .move
        case .reject:
            return []
        }
    }

    private func resolution(
        for sender: any NSDraggingInfo,
        content: (urls: [URL], sourcePaneID: UUID?, favoriteID: UUID?)
    ) -> SidebarDropResolution {
        // An internal Favorites drag always means reorder.  The whole row is a
        // stable target and its upper/lower half determines the insertion side.
        // External file URLs still use the row's filesystem destination.
        if let draggedID = content.favoriteID, let favoriteIndex {
            let point = convert(sender.draggingLocation, from: nil)
            let insertion = SidebarFavoriteDropPlacement.insertionIndex(
                row: favoriteIndex, pointerY: point.y, rowHeight: bounds.height
            )
            return .reorderFavorite(id: draggedID, index: insertion)
        }
        return SidebarDropResolver.resolve(zone: zone, urls: content.urls,
                                           favoriteID: content.favoriteID)
    }
}

/// One native owner for every Favorites interaction.  NSTableView distinguishes
/// dropping *on* a row (filesystem transfer) from dropping *above* a row
/// (reorder/add favorite), avoiding competing SwiftUI hit regions.
struct NativeSidebarFavoritesView: NSViewRepresentable {
    /// Match the compact density used by the remaining sidebar sections.
    static let rowHeight: CGFloat = SidebarMetrics.rowHeight

    @ObservedObject var store: SidebarStore
    let navigate: (SidebarFavorite) -> Void
    let perform: (SidebarDropResolution, [URL], UUID?, Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SidebarFavoritesContainerView {
        let table = SidebarFavoritesTableView()
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        // `.sourceList` reserves an undocumented top content inset (10 pt on
        // current macOS).  Inside an already styled SwiftUI sidebar section it
        // visibly pushes a short table toward the centre.  `.plain` keeps row 0
        // at y=0 while retaining native selection and drag/drop behaviour.
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = false
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.registerForDraggedTypes([
            SidebarDraggingPasteboard.favoriteType, .fileURL,
            NativeFileDragPasteboard.paneItemType, SidebarDraggingPasteboard.batchType
        ])
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 1
        table.addTableColumn(column)
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.menu(for: row)
        }
        context.coordinator.table = table

        // A scroll view gives a document view with no intrinsic width/height an
        // arbitrary document frame.  Embedded in a SwiftUI List row that made
        // the compact Favorites rows appear clustered around the centre.  The
        // sidebar itself already scrolls, so pin the table directly to a
        // deterministic, top-leading container instead.
        return SidebarFavoritesContainerView(tableView: table)
    }

    func updateNSView(_ container: SidebarFavoritesContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reloadPreservingSelection()
        container.rowCount = store.favorites.count
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: NativeSidebarFavoritesView
        weak var table: SidebarFavoritesTableView?
        private var suppressSelection = false
        private var selectedFavoriteID: UUID?

        init(parent: NativeSidebarFavoritesView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.store.favorites.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.store.favorites.indices.contains(row) else { return nil }
            let favorite = parent.store.favorites[row]
            let id = NSUserInterfaceItemIdentifier("SidebarFavoriteCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SidebarFavoriteCellView) ?? {
                let cell = SidebarFavoriteCellView()
                cell.identifier = id
                return cell
            }()
            cell.titleField.stringValue = favorite.name
            cell.configure(icon: SidebarFavoriteIcon.image(for: favorite),
                           treatment: SidebarFavoriteIcon.treatment(for: favorite),
                           selected: tableView.selectedRow == row,
                           accessibilityLabel: favorite.name)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table,
                  parent.store.favorites.indices.contains(table.selectedRow) else { return }
            let favorite = parent.store.favorites[table.selectedRow]
            selectedFavoriteID = favorite.id
            updateVisibleCellAppearances(in: table)
            parent.navigate(favorite)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard parent.store.favorites.indices.contains(row),
                  let data = try? JSONEncoder().encode(
                    SidebarFavoriteDragPayload(id: parent.store.favorites[row].id)
                  ) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: SidebarDraggingPasteboard.favoriteType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let content = SidebarDraggingPasteboard.contents(from: info.draggingPasteboard)
            if content.favoriteID != nil {
                tableView.setDropRow(nativeInsertionRow(info: info, table: tableView), dropOperation: .above)
                return .move
            }
            guard !content.urls.isEmpty else { return [] }
            let point = tableView.convert(info.draggingLocation, from: nil)
            let pointerRow = tableView.row(at: point)
            if parent.store.favorites.indices.contains(pointerRow) {
                let rect = tableView.rect(ofRow: pointerRow)
                let localY = point.y - rect.minY
                if let insertion = SidebarFavoriteDropPlacement.externalInsertionIndex(
                    row: pointerRow, pointerY: localY, rowHeight: rect.height
                ) {
                    guard content.urls.allSatisfy(Self.isDirectory) else { return [] }
                    tableView.setDropRow(insertion, dropOperation: .above)
                    return .copy
                }
                tableView.setDropRow(pointerRow, dropOperation: .on)
                let favorite = parent.store.favorites[pointerRow]
                if favorite.name == "ゴミ箱" { return .move }
                let flags = DropModifierResolver.resolve(current: NSApp.currentEvent?.modifierFlags,
                                                         tracked: DragModifierTracker.shared.trackedFlags)
                return FinderDragOperationPolicy.operation(sourceURLs: content.urls,
                                                            targetDirectory: favorite.url,
                                                            modifiers: flags)
            } else {
                guard content.urls.allSatisfy(Self.isDirectory) else { return [] }
                let insertion = point.y < 0 ? tableView.numberOfRows : 0
                tableView.setDropRow(insertion, dropOperation: .above)
                return .copy
            }
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            let content = SidebarDraggingPasteboard.contents(from: info.draggingPasteboard)
            let resolution: SidebarDropResolution
            if let id = content.favoriteID {
                resolution = .reorderFavorite(id: id, index: min(max(row, 0), parent.store.favorites.count))
            } else if operation == .above {
                guard !content.urls.isEmpty, content.urls.allSatisfy(Self.isDirectory) else { return false }
                resolution = .addFavorites(urls: content.urls, index: min(max(row, 0), parent.store.favorites.count))
            } else {
                guard parent.store.favorites.indices.contains(row), !content.urls.isEmpty else { return false }
                let favorite = parent.store.favorites[row]
                resolution = favorite.name == "ゴミ箱" ? .trash : .transfer(target: favorite.url)
            }
            let bookmark: Data? = {
                guard operation == .on, parent.store.favorites.indices.contains(row) else { return nil }
                return parent.store.favorites[row].bookmark
            }()
            parent.perform(resolution, content.urls, content.sourcePaneID, bookmark)
            return true
        }

        func reloadPreservingSelection() {
            guard let table else { return }
            suppressSelection = true
            table.reloadData()
            if let selectedFavoriteID,
               let index = parent.store.favorites.firstIndex(where: { $0.id == selectedFavoriteID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            suppressSelection = false
            updateVisibleCellAppearances(in: table)
        }

        private func updateVisibleCellAppearances(in table: NSTableView) {
            let rows = table.rows(in: table.visibleRect)
            guard rows.location != NSNotFound else { return }
            for row in rows.location..<(rows.location + rows.length) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFavoriteCellView)?
                    .setSelected(row == table.selectedRow)
            }
        }

        func menu(for row: Int) -> NSMenu? {
            guard parent.store.favorites.indices.contains(row) else { return nil }
            let favorite = parent.store.favorites[row]
            let menu = NSMenu()
            if !favorite.isDefault {
                let remove = NSMenuItem(title: "サイドバーから取り除く", action: #selector(removeFavorite(_:)), keyEquivalent: "")
                remove.representedObject = favorite.id
                remove.target = self
                menu.addItem(remove)
            }
            let copy = NSMenuItem(title: "パスをコピー", action: #selector(copyPath(_:)), keyEquivalent: "")
            copy.representedObject = favorite.url
            copy.target = self
            menu.addItem(copy)
            return menu
        }

        @objc private func removeFavorite(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.store.remove(id: id)
        }

        @objc private func copyPath(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }

        private func nativeInsertionRow(info: any NSDraggingInfo, table: NSTableView) -> Int {
            let point = table.convert(info.draggingLocation, from: nil)
            let row = table.row(at: point)
            guard row >= 0 else { return point.y < 0 ? table.numberOfRows : 0 }
            let rect = table.rect(ofRow: row)
            return SidebarFavoriteDropPlacement.insertionIndex(
                row: row, pointerY: point.y - rect.minY, rowHeight: rect.height
            )
        }

        private static func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

final class SidebarFavoritesTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }
}

final class SidebarFavoriteCellView: NSTableCellView {
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    private var iconTreatment: SidebarFavoriteIcon.Treatment = .systemSymbol
    /// Keep the untinted source around so a reused NSTableCellView can rebuild
    /// the symbol for the current selection/appearance.  `contentTintColor`
    /// alone is not reliable for symbol images inside a source-list cell: the
    /// table's vibrancy pass can render the template as solid black again.
    private var sourceIcon: NSImage?
    private var selected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: SidebarMetrics.iconSize,
                                                                    weight: .regular)
        titleField.font = .systemFont(ofSize: SidebarMetrics.fontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        imageView = iconView
        textField = titleField
        addSubview(iconView)
        addSubview(titleField)
    }

    func configure(icon: NSImage, treatment: SidebarFavoriteIcon.Treatment,
                   selected: Bool, accessibilityLabel: String) {
        sourceIcon = (icon.copy() as? NSImage) ?? icon
        iconTreatment = treatment
        self.selected = selected
        iconView.setAccessibilityLabel(accessibilityLabel)
        updateColors()
    }

    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        titleField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        switch iconTreatment {
        case .systemSymbol:
            // Bake the colour into the SF Symbol and make the result
            // non-template. This avoids NSTableView/source-list vibrancy
            // overriding NSImageView.contentTintColor and drawing it black.
            let color: NSColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
            let size = NSImage.SymbolConfiguration(pointSize: SidebarMetrics.iconSize, weight: .regular)
            let palette = NSImage.SymbolConfiguration(paletteColors: [color])
            let configuration = size.applying(palette)
            if let colored = sourceIcon?.withSymbolConfiguration(configuration) {
                let rendered = (colored.copy() as? NSImage) ?? colored
                rendered.isTemplate = false
                iconView.image = rendered
            } else {
                let fallback = (sourceIcon?.copy() as? NSImage) ?? sourceIcon
                fallback?.isTemplate = true
                iconView.image = fallback
                iconView.contentTintColor = color
            }
            iconView.contentTintColor = nil
        case .workspaceIcon:
            // Workspace icons contain their own colour information. Applying
            // template tinting here turns folders into solid black silhouettes.
            let rendered = (sourceIcon?.copy() as? NSImage) ?? sourceIcon
            rendered?.isTemplate = false
            iconView.image = rendered
            iconView.contentTintColor = nil
        }
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let iconY = (bounds.height - SidebarMetrics.iconSize) / 2
        iconView.frame = NSRect(x: SidebarMetrics.horizontalInset, y: iconY,
                                width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
        let textX = SidebarMetrics.horizontalInset + SidebarMetrics.iconSize + SidebarMetrics.itemSpacing
        let textHeight = min(bounds.height, ceil(titleField.intrinsicContentSize.height))
        let textY = (bounds.height - textHeight) / 2
        titleField.frame = NSRect(x: textX, y: textY,
                                  width: max(0, bounds.width - textX - SidebarMetrics.trailingInset),
                                  height: textHeight)
    }
}

/// Non-scrolling host for the native Favorites table. The enclosing SwiftUI
/// sidebar owns scrolling; this host owns deterministic content geometry.
final class SidebarFavoritesContainerView: NSView {
    let tableView: SidebarFavoritesTableView
    var rowCount: Int = 0 {
        didSet {
            guard rowCount != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(tableView: SidebarFavoritesTableView) {
        self.tableView = tableView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(tableView)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat {
        CGFloat(rowCount) * (tableView.rowHeight + tableView.intercellSpacing.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override func layout() {
        super.layout()
        // NSTableView reserves a 10 pt leading content inset on current macOS,
        // even for a headerless plain table. Compensate at the host boundary so
        // the first visible row starts at the section's y=0 rather than making
        // a short favorites list look vertically centred.
        tableView.frame = NSRect(x: 0, y: 0, width: bounds.width,
                                 height: max(bounds.height, contentHeight) + 16)
        let nativeTopInset = rowCount > 0 ? tableView.rect(ofRow: 0).minY : 0
        tableView.frame = NSRect(x: 0, y: -nativeTopInset, width: bounds.width,
                                 height: max(bounds.height, contentHeight) + nativeTopInset)
        // NSTableColumn does not always follow its bare table view until a
        // subsequent layout pass. Keep the single column full width now so the
        // icon and label remain leading-aligned at every sidebar width.
        tableView.tableColumns.first?.width = max(1, bounds.width)
    }
}

enum SidebarMetrics {
    /// Finder's compact sidebar reduces padding, not the glyph and text to an
    /// unreadable size. All native and SwiftUI sections share these metrics.
    static let rowHeight: CGFloat = 24
    static let horizontalInset: CGFloat = 6
    static let trailingInset: CGFloat = 6
    static let iconSize: CGFloat = 16
    static let itemSpacing: CGFloat = 6
    static let fontSize: CGFloat = 13
}

enum SidebarFavoriteIcon {
    enum Treatment: Equatable { case systemSymbol, workspaceIcon }

    static func treatment(for favorite: SidebarFavorite) -> Treatment {
        favorite.isDefault ? .systemSymbol : .workspaceIcon
    }

    static func symbolName(for favorite: SidebarFavorite) -> String? {
        guard favorite.isDefault else { return nil }
        switch favorite.name {
        case "ホーム": return "house.fill"
        case "デスクトップ": return "display"
        case "書類": return "doc.fill"
        case "ダウンロード": return "arrow.down.circle.fill"
        case "ゴミ箱": return "trash.fill"
        default: return "folder.fill"
        }
    }

    static func image(for favorite: SidebarFavorite) -> NSImage {
        if let symbolName = symbolName(for: favorite),
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: favorite.name) {
            image.isTemplate = true
            return image
        }
        // NSWorkspace caches icon instances. Copy before clearing template mode
        // so QuadFinder never mutates the shared cache entry.
        let shared = NSWorkspace.shared.icon(forFile: favorite.url.path)
        let image = (shared.copy() as? NSImage) ?? shared
        image.isTemplate = false
        return image
    }
}

struct PersistentFinderSidebarView: View {
    static let compactRowHeight: CGFloat = SidebarMetrics.rowHeight
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var store: SidebarStore
    let navigate: (SidebarFavorite) -> Void
    let openRecent: (SidebarRecentItem) -> Void
    @State private var targetedZone: SidebarDropZone?

    private var fileDropTypes: [String] {
        [UTType.fileURL.identifier, UTType.quadFinderPaneItem.identifier,
         UTType.quadFinderPaneBatch.identifier]
    }

    var body: some View {
        List {
            Section("よく使う項目") {
                NativeSidebarFavoritesView(store: store, navigate: navigate, perform: performDrop)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: CGFloat(store.favorites.count) * NativeSidebarFavoritesView.rowHeight,
                           alignment: .topLeading)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
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
        .font(.system(size: SidebarMetrics.fontSize))
        .controlSize(.mini)
        .environment(\.defaultMinListRowHeight, Self.compactRowHeight)
        .listStyle(.sidebar)
        .frame(minWidth: 90, idealWidth: store.width, maxWidth: 360)
    }

    private func deviceRow(_ device: SidebarLocation) -> some View {
        HStack(spacing: 4) {
            Button { navigate(SidebarFavorite(name: device.name, url: device.url, isDefault: true)) } label: {
                sidebarLabel(device.name, systemImage: device.systemImage)
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
        .background(rowHighlight(for: .directory(device.url)))
        .overlay {
            SidebarNativeDropTarget(zone: .directory(device.url), targetBookmark: nil,
                                    isTargeted: targetedBinding(.directory(device.url)),
                                    perform: performDrop)
        }
        .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 4))
    }

    private func recentRow(_ recent: SidebarRecentItem) -> some View {
        Button { openRecent(recent) } label: {
            sidebarLabel(
                recent.url.lastPathComponent.isEmpty ? recent.url.path : recent.url.lastPathComponent,
                systemImage: !FileManager.default.fileExists(atPath: recent.url.path)
                    ? "questionmark.diamond" : (recent.kind == .folder ? "folder" : "doc")
            )
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: Self.compactRowHeight)
        }
        .buttonStyle(.plain).help(recent.url.path(percentEncoded: false))
        .contextMenu { Button("履歴から削除") { store.removeRecent(recent.url) } }
        .background(rowHighlight(for: recent.kind == .folder ? .directory(recent.url) : .unavailable))
        .modifier(RecentFolderDropModifier(
            recent: recent, fileDropTypes: fileDropTypes,
            isTargeted: targetedBinding(recent.kind == .folder ? .directory(recent.url) : .unavailable),
            perform: performDrop
        ))
        .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 4))
    }

    private func sidebarLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SidebarMetrics.itemSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: SidebarMetrics.iconSize - 2, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            Text(title)
                .font(.system(size: SidebarMetrics.fontSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private func rowHighlight(for zone: SidebarDropZone) -> some View {
        if targetedZone == zone {
            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.18))
        }
    }

    private func targetedBinding(_ zone: SidebarDropZone) -> Binding<Bool> {
        Binding(get: { targetedZone == zone }, set: { value in
            if value { targetedZone = zone }
            else if targetedZone == zone { targetedZone = nil }
        })
    }

    private func performDrop(_ resolution: SidebarDropResolution, urls: [URL],
                             sourcePaneID: UUID?, targetBookmark: Data?) {
        switch resolution {
        case .transfer(let target):
            workspace.prepareSidebarDrop(sourcePaneID: sourcePaneID,
                                         targetDirectoryURL: target,
                                         targetAccessBookmark: targetBookmark,
                                         urls: urls)
        case .trash:
            let sourceBookmark = sourcePaneID.flatMap { workspace.pane(id: $0)?.accessBookmark }
            workspace.trashImmediately(urls, accessBookmark: sourceBookmark)
        case .addFavorites(let folders, let index):
            var insertion = index
            for folder in folders {
                guard let bookmark = try? FileSystemService.bookmark(for: folder) else { continue }
                store.insertCustom(name: folder.lastPathComponent, url: folder,
                                   bookmark: bookmark, at: insertion)
                insertion += 1
            }
        case .reorderFavorite(let id, let index):
            store.moveFavorite(id: id, toOffset: index)
        case .reject:
            break
        }
        targetedZone = nil
        DragModifierTracker.shared.reset()
    }

    private func eject(_ device: SidebarLocation) {
        Task {
            do { try await store.eject(device); NotificationCenter.default.post(name: .quadFinderSidebarDidEject, object: device.url) }
            catch { NotificationCenter.default.post(name: .quadFinderSidebarEjectFailed, object: device.url, userInfo: ["error": error]) }
        }
    }
}

/// Conditional modifiers avoid registering recent files as drop targets at
/// all.  A file in History remains an open-only row, matching Finder.
private struct RecentFolderDropModifier: ViewModifier {
    let recent: SidebarRecentItem
    let fileDropTypes: [String]
    @Binding var isTargeted: Bool
    let perform: (SidebarDropResolution, [URL], UUID?, Data?) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if recent.kind == .folder {
            content.overlay {
                SidebarNativeDropTarget(zone: .directory(recent.url), targetBookmark: recent.bookmark,
                                        isTargeted: $isTargeted, perform: perform)
            }
        } else {
            content
        }
    }
}
