import AppKit
import SwiftUI

/// Clickable path components, matching Finder's path navigation while keeping
/// every component independently useful from the context menu.
struct PathBreadcrumbView: View {
    let url: URL
    let navigate: (URL) -> Void

    private var components: [(String, URL)] {
        let pieces = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        return pieces.enumerated().map { index, piece in
            if index > 0 { current.appendPathComponent(piece, isDirectory: true) }
            return (index == 0 ? "/" : piece, current)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button(component.0) { navigate(component.1) }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .lineLimit(1)
                        .contextMenu {
                            Button(L10n.tr("この場所へ移動")) { navigate(component.1) }
                            Button(L10n.tr("パスをコピー")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(component.1.path(percentEncoded: false), forType: .string)
                            }
                        }
                }
            }
        }
        .help(url.path(percentEncoded: false))
    }
}

struct ColumnLevel: Identifiable, Equatable {
    let directoryURL: URL
    var items: [FileItem]
    var selectedURL: URL?
    var id: URL { directoryURL }
}

@MainActor
final class ColumnBrowserModel: ObservableObject {
    @Published private(set) var levels: [ColumnLevel] = []
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending: Set<URL> = []
    private var latestRefreshOptions: (showsHiddenFiles: Bool, bookmark: Data?)?
    private let fileSystem: FileSystemService

    init(fileSystem: FileSystemService = FileSystemService()) {
        self.fileSystem = fileSystem
    }

    func setRoot(url: URL, items: [FileItem]) {
        if levels.first?.directoryURL != url {
            loadTask?.cancel()
            refreshTask?.cancel()
            refreshTask = nil
            refreshPending = []
            levels = [ColumnLevel(directoryURL: url, items: items, selectedURL: nil)]
        } else if !levels.isEmpty {
            levels[0].items = items
            if let selected = levels[0].selectedURL, !items.contains(where: { $0.url == selected }) {
                levels[0].selectedURL = nil
                levels = Array(levels.prefix(1))
            }
        }
    }

    func select(_ item: FileItem, in levelIndex: Int, bookmark: Data?) {
        guard levels.indices.contains(levelIndex) else { return }
        levels[levelIndex].selectedURL = item.url
        if levels.count > levelIndex + 1 { levels = Array(levels.prefix(levelIndex + 1)) }
        loadTask?.cancel()
        guard item.isDirectory else { return }
        loadTask = Task {
            var scope: URL?
            var started = false
            if AppSecurityEnvironment.current.isSandboxed, let bookmark {
                guard let resolved = try? FileSystemService.resolveBookmark(bookmark),
                      SecurityScopeAccess().contains(scopeURL: resolved, requestedURL: item.url),
                      resolved.startAccessingSecurityScopedResource() else { return }
                scope = resolved
                started = true
            }
            defer { if started { scope?.stopAccessingSecurityScopedResource() } }
            let children = try? await fileSystem.listDirectory(
                item.url, showsHiddenFiles: false, bypassCache: true
            )
            guard !Task.isCancelled, levels.indices.contains(levelIndex),
                  levels[levelIndex].selectedURL == item.url else { return }
            levels.append(ColumnLevel(directoryURL: item.url, items: children ?? [], selectedURL: nil))
        }
    }

    /// Refreshes every directory which is currently represented by a visible
    /// column. FSEvents intentionally coalesces descendant changes to the pane
    /// root, so a root notification must also invalidate all child columns.
    func reloadVisibleDirectories(changedURL: URL, rootURL: URL,
                                  showsHiddenFiles: Bool, bookmark: Data?) {
        guard FileURLIdentity.contains(rootURL, changedURL) else { return }
        let reloadAll = FileURLIdentity.isSame(changedURL, rootURL)
        let directories = levels.map(\.directoryURL).filter {
            reloadAll || FileURLIdentity.isSame($0, changedURL)
        }
        guard !directories.isEmpty else { return }
        refreshPending.formUnion(directories.map(FileURLIdentity.canonical))
        latestRefreshOptions = (showsHiddenFiles, bookmark)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let options = self.latestRefreshOptions else { return }
                let pending = self.refreshPending
                self.refreshPending = []
                for directory in pending {
                    guard !Task.isCancelled else { return }
                    guard let items = try? await self.fileSystem.listDirectory(
                        directory, showsHiddenFiles: options.showsHiddenFiles, bypassCache: true
                    ) else { continue }
                    guard !Task.isCancelled, let index = self.levels.firstIndex(where: {
                        FileURLIdentity.isSame($0.directoryURL, directory)
                    }) else { continue }
                    self.levels[index].items = items
                    if let selected = self.levels[index].selectedURL,
                       !items.contains(where: { FileURLIdentity.isSame($0.url, selected) }) {
                        self.levels[index].selectedURL = nil
                        self.levels = Array(self.levels.prefix(index + 1))
                        break
                    }
                }
                if self.refreshPending.isEmpty { return }
            }
        }
    }

    func cancel() {
        loadTask?.cancel(); refreshTask?.cancel()
        refreshTask = nil; refreshPending = []
    }
    func waitForLoad() async { await loadTask?.value }
    func waitForRefresh() async { await refreshTask?.value }
}

/// Finder-style arbitrary-depth columns. Selecting a folder appends its
/// children; changing an earlier selection discards every column to its right.
struct ColumnFileView: View {
    let paneID: UUID
    let rootURL: URL
    let items: [FileItem]
    let showsHiddenFiles: Bool
    @Binding var selection: Set<URL>
    let bookmark: Data?
    let open: (FileItem) -> Void
    let activate: () -> Void
    let clipboardMarked: (URL) -> Bool
    let clipboardIsCut: Bool
    let receiveDrop: ([URL], UUID?, URL, FinderDropIntent) -> Void
    let trashDropped: ([URL]) -> Void
    let contextMenu: NativeFinderContextMenuConfiguration

    @StateObject private var model = ColumnBrowserModel()

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(model.levels.enumerated()), id: \.element.id) { index, level in
                    column(level, index: index)
                    if index < model.levels.count - 1 { Divider() }
                }
            }
        }
        .onAppear { model.setRoot(url: rootURL, items: items) }
        .onChange(of: rootURL) { _, _ in model.setRoot(url: rootURL, items: items) }
        .onChange(of: items) { _, value in model.setRoot(url: rootURL, items: value) }
        .onReceive(NotificationCenter.default.publisher(for: .quadFinderDirectoryDidChange)) { note in
            guard let changed = note.object as? URL else { return }
            model.reloadVisibleDirectories(changedURL: changed, rootURL: rootURL,
                                           showsHiddenFiles: showsHiddenFiles, bookmark: bookmark)
        }
        .onDisappear { model.cancel() }
    }

    private func column(_ level: ColumnLevel, index: Int) -> some View {
        NativeFileTableView(
            paneID: paneID, currentDirectory: level.directoryURL, items: level.items,
            selection: Binding(
                get: { selection.intersection(Set(level.items.map(\.url))) },
                set: { urls in
                    guard let url = urls.first, let item = level.items.first(where: { $0.url == url }) else { return }
                    selection = [url]
                    model.select(item, in: index, bookmark: bookmark)
                }
            ),
            activate: activate, open: open, receiveDrop: receiveDrop, trashDropped: trashDropped,
            contextMenu: contextMenu
        )
        .frame(width: 230)
    }

}

struct TreeRow: Identifiable, Hashable {
    let item: FileItem
    let depth: Int
    var id: URL { item.url }

    static func == (lhs: TreeRow, rhs: TreeRow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class TreeBrowserModel: ObservableObject {
    @Published private(set) var expanded: Set<URL> = []
    @Published private(set) var children: [URL: [FileItem]] = [:]
    private var generations: [URL: UUID] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshPending: Set<URL> = []
    private var latestRefreshOptions: (showsHiddenFiles: Bool, bookmark: Data?)?
    private let fileSystem: FileSystemService

    init(fileSystem: FileSystemService = FileSystemService()) { self.fileSystem = fileSystem }

    func rows(rootItems: [FileItem], sortDescriptor: FileSortDescriptor = FileSortDescriptor()) -> [TreeRow] {
        func append(_ items: [FileItem], depth: Int, to output: inout [TreeRow]) {
            for item in sortDescriptor.sorted(items) {
                output.append(TreeRow(item: item, depth: depth))
                if expanded.contains(item.url), let nested = children[item.url] { append(nested, depth: depth + 1, to: &output) }
            }
        }
        var result: [TreeRow] = []
        append(rootItems, depth: 0, to: &result)
        return result
    }

    func toggle(_ item: FileItem, showsHiddenFiles: Bool, bookmark: Data?) {
        guard item.isDirectory, !item.isSymbolicLink else { return }
        if expanded.remove(item.url) != nil { tasks[item.url]?.cancel(); return }
        expanded.insert(item.url)
        load(item.url, showsHiddenFiles: showsHiddenFiles, bookmark: bookmark)
    }

    func load(_ url: URL, showsHiddenFiles: Bool, bookmark: Data?) {
        tasks[url]?.cancel()
        let generation = UUID(); generations[url] = generation
        tasks[url] = Task {
            var scope: URL?; var started = false
            if AppSecurityEnvironment.current.isSandboxed, let bookmark, let resolved = try? FileSystemService.resolveBookmark(bookmark),
               SecurityScopeAccess().contains(scopeURL: resolved, requestedURL: url) {
                scope = resolved; started = resolved.startAccessingSecurityScopedResource()
            }
            defer { if started { scope?.stopAccessingSecurityScopedResource() } }
            let result = try? await fileSystem.listDirectory(url, showsHiddenFiles: showsHiddenFiles, bypassCache: true)
            guard !Task.isCancelled, generations[url] == generation, expanded.contains(url) else { return }
            children[url] = result ?? []
        }
    }

    /// Keeps expanded rows live. The pane-level browser owns only the root
    /// listing; without this path an FSEvent showed the root loading indicator
    /// while leaving expanded descendants permanently stale.
    func reloadExpandedDirectories(changedURL: URL, rootURL: URL,
                                   showsHiddenFiles: Bool, bookmark: Data?) {
        guard FileURLIdentity.contains(rootURL, changedURL) else { return }
        let reloadAll = FileURLIdentity.isSame(changedURL, rootURL)
        refreshPending.formUnion(expanded.filter {
            reloadAll || FileURLIdentity.isSame($0, changedURL)
        }.map(FileURLIdentity.canonical))
        guard !refreshPending.isEmpty else { return }
        latestRefreshOptions = (showsHiddenFiles, bookmark)
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let options = self.latestRefreshOptions else { return }
                let pending = self.refreshPending
                self.refreshPending = []
                for directory in pending where self.expanded.contains(where: {
                    FileURLIdentity.isSame($0, directory)
                }) {
                    let expandedURL = self.expanded.first(where: {
                        FileURLIdentity.isSame($0, directory)
                    }) ?? directory
                    self.load(expandedURL, showsHiddenFiles: options.showsHiddenFiles,
                              bookmark: options.bookmark)
                }
                let active = pending.compactMap { directory in
                    self.tasks.first(where: { FileURLIdentity.isSame($0.key, directory) })?.value
                }
                for task in active { await task.value }
                if self.refreshPending.isEmpty { return }
            }
        }
    }

    func collapseAll() {
        tasks.values.forEach { $0.cancel() }
        refreshTask?.cancel(); refreshTask = nil; refreshPending = []
        expanded = []; children = [:]
    }
    func waitForLoad(_ url: URL) async { await tasks[url]?.value }
    func waitForRefresh() async { await refreshTask?.value }
}

struct TreeFileView: View {
    let paneID: UUID
    let rootURL: URL
    let rootItems: [FileItem]
    let showsHiddenFiles: Bool
    let sortDescriptor: FileSortDescriptor
    @Binding var selection: Set<URL>
    let bookmark: Data?
    let open: (FileItem) -> Void
    let activate: () -> Void
    let clipboardMarked: (URL) -> Bool
    let clipboardIsCut: Bool
    let receiveDrop: ([URL], UUID?, URL, FinderDropIntent) -> Void
    let trashDropped: ([URL]) -> Void
    let selectSort: (FileSortField) -> Void
    let contextMenu: NativeFinderContextMenuConfiguration
    @StateObject private var model = TreeBrowserModel()

    var body: some View {
        NativeTreeOutlineView(
            paneID: paneID,
            currentDirectory: rootURL,
            rows: model.rows(rootItems: rootItems, sortDescriptor: sortDescriptor),
            expandedURLs: model.expanded,
            selection: $selection,
            activate: activate,
            open: open,
            toggle: { model.toggle($0, showsHiddenFiles: showsHiddenFiles, bookmark: bookmark) },
            receiveDrop: receiveDrop,
            trashDropped: trashDropped,
            sortDescriptor: sortDescriptor,
            selectSort: selectSort,
            contextMenu: contextMenu
        )
        .onReceive(NotificationCenter.default.publisher(for: .quadFinderDirectoryDidChange)) { note in
            guard let changed = note.object as? URL else { return }
            model.reloadExpandedDirectories(changedURL: changed, rootURL: rootURL,
                                            showsHiddenFiles: showsHiddenFiles, bookmark: bookmark)
        }
    }
}
