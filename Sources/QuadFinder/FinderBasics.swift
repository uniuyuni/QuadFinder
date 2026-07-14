import AppKit
import CoreServices
import Foundation
@preconcurrency import QuickLookUI
import SwiftUI

// MARK: - Clipboard

struct ClipboardCutReceipt: Equatable, Sendable {
    let changeCount: Int
    let sessionToken: String
    let sourceURLs: [URL]
}

/// Owns QuadFinder's cut marker. A cut only records intent; sources are not
/// mutated until the normal, conflict-checking move operation succeeds.
@MainActor
final class FinderClipboard: ObservableObject {
    static let shared = FinderClipboard()

    private let cutType = NSPasteboard.PasteboardType("com.quadfinder.private.cut-token")
    private let sessionToken = UUID().uuidString
    @Published private(set) var markedURLs: Set<URL> = []
    @Published private(set) var markedAsCut = false
    private var observedChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged() }
        }
    }

    func write(urls: [URL], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        if cut {
            pasteboard.setString(sessionToken, forType: cutType)
        }
        observedChangeCount = pasteboard.changeCount
        markedURLs = Set(urls.map(\.standardizedFileURL))
        markedAsCut = cut
    }

    func read() -> (urls: [URL], isCut: Bool) {
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: classes, options: options) as? [NSURL] ?? [])
            .map { $0 as URL }
        let isCut = NSPasteboard.general.string(forType: cutType) == sessionToken
        return (urls, isCut)
    }

    func cutReceiptIfCurrent() -> ClipboardCutReceipt? {
        let contents = read()
        guard contents.isCut else { return nil }
        return ClipboardCutReceipt(
            changeCount: NSPasteboard.general.changeCount,
            sessionToken: sessionToken,
            sourceURLs: Self.normalized(contents.urls)
        )
    }

    func readSnapshot() -> (urls: [URL], isCut: Bool, cutReceipt: ClipboardCutReceipt?) {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let contents = read()
        let after = pasteboard.changeCount
        guard before == after, contents.isCut else { return (contents.urls, contents.isCut, nil) }
        let normalizedURLs = Self.normalized(contents.urls)
        return (
            contents.urls,
            true,
            ClipboardCutReceipt(changeCount: after, sessionToken: sessionToken, sourceURLs: normalizedURLs)
        )
    }

    func clearCutMarker() {
        guard NSPasteboard.general.string(forType: cutType) == sessionToken else { return }
        // Preserve file URLs for interoperability while turning the operation
        // into a copy. Never clear unrelated pasteboard contents.
        let urls = read().urls
        write(urls: urls, cut: false)
    }

    @discardableResult
    func clearCutMarker(ifMatches receipt: ClipboardCutReceipt) -> Bool {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        guard initialChangeCount == receipt.changeCount,
              pasteboard.string(forType: cutType) == sessionToken,
              receipt.sessionToken == sessionToken else { return false }
        let currentURLs = read().urls
        guard pasteboard.changeCount == initialChangeCount,
              Self.normalized(currentURLs) == receipt.sourceURLs else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(currentURLs.map { $0 as NSURL })
        observedChangeCount = pasteboard.changeCount
        markedURLs = Set(currentURLs.map(\.standardizedFileURL))
        markedAsCut = false
        return true
    }

    func refreshIfChanged() {
        let current = NSPasteboard.general.changeCount
        guard current != observedChangeCount else { return }
        observedChangeCount = current
        markedURLs = []
        markedAsCut = false
    }

    func isMarked(_ url: URL) -> Bool { markedURLs.contains(url.standardizedFileURL) }

    private static func normalized(_ urls: [URL]) -> [URL] {
        urls.map(\.standardizedFileURL).sorted { $0.path < $1.path }
    }
}

// MARK: - Finder-like actions

enum FinderActionError: LocalizedError {
    case noSelection
    case invalidName
    case destinationConflict(URL)
    case trashFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .noSelection: L10n.tr("項目が選択されていません。")
        case .invalidName: L10n.tr("使用できない名前です。")
        case .destinationConflict(let url): L10n.format("同名の項目が既に存在します: %@", url.path)
        case .trashFailed(let url, let error): L10n.format("「%@」をゴミ箱に移動できませんでした。完全削除は行っていません。\n%@", url.lastPathComponent, error.localizedDescription)
        }
    }
}

struct FinderActionService: Sendable {
    func createFolder(in directory: URL, preferredName: String = L10n.tr("名称未設定フォルダ")) throws -> URL {
        for index in 1...10_000 {
            let name = index == 1 ? preferredName : "\(preferredName) \(index)"
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                return destination
            }
        }
        throw FinderActionError.destinationConflict(directory)
    }

    func rename(_ url: URL, to name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw FinderActionError.invalidName
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FinderActionError.destinationConflict(destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func duplicate(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let suffix = index == 1 ? L10n.tr(" のコピー") : L10n.format(" のコピー %d", index)
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            let destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            }
        }
        throw FinderActionError.destinationConflict(directory)
    }

    func moveToTrash(_ urls: [URL]) throws {
        _ = try moveToTrashRecording(urls)
    }

    func moveToTrashRecording(_ urls: [URL]) throws -> OperationOutcome {
        guard !urls.isEmpty else { throw FinderActionError.noSelection }
        var moved: [(URL, URL?)] = []
        for url in urls {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                moved.append((url, resultingURL as URL?))
            } catch {
                // Deliberately no removeItem fallback: Trash failure must never
                // become irreversible deletion.
                let steps = moved.map { HistoryStep.trashed(original: $0.0, trashURL: $0.1) }
                throw PartialOperationFailure(outcome: .init(completedBytes: 0, completedItems: steps.count,
                                                              resultingURLs: [], historySteps: steps),
                                              underlying: FinderActionError.trashFailed(url, error))
            }
        }
        let steps = moved.map { HistoryStep.trashed(original: $0.0, trashURL: $0.1) }
        return OperationOutcome(completedBytes: 0, completedItems: steps.count,
                                resultingURLs: [], historySteps: steps)
    }
}

extension WorkspaceStore {
    func copySelectionToClipboard(cut: Bool) {
        guard let pane = activePane, !pane.selectedURLs.isEmpty else {
            error = UserFacingError(title: L10n.tr("項目が選択されていません"), message: FinderActionError.noSelection.localizedDescription)
            return
        }
        FinderClipboard.shared.write(urls: pane.selectedURLs.sorted { $0.path < $1.path }, cut: cut)
    }

    func preparePasteFromClipboard() {
        guard let target = activePane else { return }
        let contents = FinderClipboard.shared.readSnapshot()
        guard !contents.urls.isEmpty else {
            error = UserFacingError(title: L10n.tr("貼り付けできません"), message: L10n.tr("クリップボードにファイルまたはフォルダがありません。"))
            return
        }
        pendingDrop = PendingDrop(
            sourcePaneID: nil,
            targetPaneID: target.id,
            sourceURLs: contents.urls.map(\.standardizedFileURL),
            targetDirectoryURL: target.currentURL.standardizedFileURL,
            sourceAccessBookmark: nil,
            targetAccessBookmark: target.accessBookmark,
            clipboardCutReceipt: contents.cutReceipt
        )
        // Keyboard paste already carries an unambiguous copy/cut intent.
        // Conflict handling still goes through WorkspaceStore's visual planner.
        performPendingDrop(as: contents.isCut ? .move : .copy)
    }

    var clipboardPasteKind: FileOperationKind {
        FinderClipboard.shared.read().isCut ? .move : .copy
    }

    func quickLookSelection() {
        guard let pane = activePane, !pane.selectedURLs.isEmpty else { return }
        QuickLookPresenter.shared.preview(pane.selectedURLs.sorted { $0.path < $1.path })
    }

    func moveSelectionToTrash() {
        guard let pane = activePane else { return }
        trashImmediately(Array(pane.selectedURLs), accessBookmark: pane.accessBookmark)
    }
}

// MARK: - Quick Look

@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []
    private weak var panel: QLPreviewPanel?
    private(set) var selectionRevision = 0
    private(set) var isSessionActive = false

    func preview(_ urls: [URL]) {
        beginSession(urls)
        guard let panel = QLPreviewPanel.shared() else { return }
        self.panel = panel
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func present(urls: [URL]) { preview(urls) }

    func selectionDidChange(_ urls: [URL]) {
        let wasSessionActive = isSessionActive
        replaceSelection(urls)
        guard wasSessionActive else { return }
        guard let panel, panel.isVisible else { return }
        if urls.isEmpty {
            panel.orderOut(nil)
            self.panel = nil
        } else {
            panel.reloadData()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        urls = []
        isSessionActive = false
        selectionRevision += 1
    }

    var previewedURLs: [URL] { urls }
    var isVisible: Bool { isSessionActive && panel?.isVisible == true }
    var isPanelVisible: Bool { isVisible }

    func reloadSelection(_ urls: [URL]) { selectionDidChange(urls) }

    func beginSession(_ urls: [URL]) {
        self.urls = urls
        isSessionActive = !urls.isEmpty
        selectionRevision += 1
    }

    func replaceSelection(_ urls: [URL]) {
        self.urls = urls
        selectionRevision += 1
        if urls.isEmpty { isSessionActive = false }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        urls[index] as NSURL
    }
}

typealias QuickLookController = QuickLookPresenter

// MARK: - Directory monitoring

enum FileURLIdentity {
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    static func contains(_ directory: URL, _ candidate: URL) -> Bool {
        let root = canonical(directory).path
        let path = canonical(candidate).path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Watches displayed directories through a vnode source. Events are coalesced
/// and delivered through the same notification already consumed by PaneView.
@MainActor
final class DirectoryMonitoringCenter {
    private struct Observation {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private var observations: [URL: Observation] = [:]
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    private var debounceTasks: [URL: Task<Void, Never>] = [:]
    private var eventTokens: [URL: UUID] = [:]
    private let debounceDuration: Duration
    private let notify: @MainActor (URL, UUID) -> Void

    init(
        debounceDuration: Duration = .milliseconds(150),
        notify: @escaping @MainActor (URL, UUID) -> Void = { url, _ in
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: url)
        }
    ) {
        self.debounceDuration = debounceDuration
        self.notify = notify
    }

    func update(urls: Set<URL>) {
        let canonical = Set(urls.map(FileURLIdentity.canonical))
        guard canonical != Set(observations.keys) else { return }
        for url in observations.keys where !canonical.contains(url) { remove(url) }
        for url in canonical where observations[url] == nil { add(url) }
        restartEventStream()
    }

    func stop() {
        stopEventStream()
        for url in Array(observations.keys) { remove(url) }
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
    }

    func receiveEvent(for url: URL) {
        let url = FileURLIdentity.canonical(url)
        let token = UUID()
        eventTokens[url] = token
        debounceTasks[url]?.cancel()
        let duration = debounceDuration
        debounceTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.eventTokens[url] == token else { return }
            self.debounceTasks[url] = nil
            self.notify(url, token)
        }
    }

    private func add(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            self.receiveEvent(for: url)
            let flags = source?.data ?? []
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                // Keep the event already queued above. `remove` normally
                // cancels debounce work, which used to swallow the last
                // refresh when a watched directory was renamed or deleted.
                self.remove(url, cancelPendingNotification: false)
            }
        }
        source.setCancelHandler { close(descriptor) }
        observations[url] = Observation(descriptor: descriptor, source: source)
        source.resume()
    }

    private func remove(_ url: URL, cancelPendingNotification: Bool = true) {
        observations.removeValue(forKey: url)?.source.cancel()
        if cancelPendingNotification {
            debounceTasks.removeValue(forKey: url)?.cancel()
            eventTokens[url] = nil
        }
    }

    /// Directory vnode sources catch entry changes cheaply, but do not report
    /// every write to an existing child. FSEvents supplies those descendant
    /// events. The paths are already limited to the currently displayed
    /// directories, and the normal debounce coalesces duplicate vnode/FSEvent
    /// delivery into one reload.
    private func restartEventStream() {
        stopEventStream()
        let paths = observations.keys.map(\.path)
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<DirectoryMonitoringCenter>.fromOpaque(info).takeUnretainedValue()
            let values = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            var paths: [URL] = []
            paths.reserveCapacity(eventCount)
            for index in 0..<eventCount {
                if let path = CFArrayGetValueAtIndex(values, index) {
                    let value = Unmanaged<CFString>.fromOpaque(path).takeUnretainedValue() as String
                    paths.append(URL(fileURLWithPath: value))
                }
            }
            Task { @MainActor in monitor.receiveFSEvents(paths: paths) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        eventStream = stream
    }

    /// FSEvents can batch paths from every watched root into one callback. Route
    /// each path only to the displayed directory which actually contains it;
    /// notifying every pane made a busy directory starve unrelated panes.
    func receiveFSEvents(paths: [URL]) {
        guard !paths.isEmpty else { return }
        for root in Self.affectedRoots(observed: Set(observations.keys), eventPaths: paths) {
            receiveEvent(for: root)
        }
    }

    static func affectedRoots(observed: Set<URL>, eventPaths: [URL]) -> Set<URL> {
        Set(observed.map(FileURLIdentity.canonical).filter { root in
            eventPaths.contains(where: { FileURLIdentity.contains(root, $0) })
        })
    }

    private func stopEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        for observation in observations.values { observation.source.cancel() }
        for task in debounceTasks.values { task.cancel() }
    }
}

// MARK: - Sidebar

struct SidebarLocation: Identifiable, Hashable {
    enum Section: String {
        case favorites = "よく使う項目", devices = "デバイス"
        var localizedTitle: String { L10n.tr(rawValue) }
    }
    let section: Section
    let name: String
    let url: URL
    let systemImage: String
    /// True when Finder would offer an eject control for this mounted volume.
    let isEjectable: Bool
    var id: URL { url }

    init(section: Section, name: String, url: URL, systemImage: String, isEjectable: Bool = false) {
        self.section = section
        self.name = name
        self.url = url
        self.systemImage = systemImage
        self.isEjectable = isEjectable
    }
}

struct SidebarLocationsProvider {
    func locations() -> [SidebarLocation] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var result = [
            SidebarLocation(section: .favorites, name: L10n.tr("ホーム"), url: home, systemImage: "house"),
            SidebarLocation(section: .favorites, name: L10n.tr("デスクトップ"), url: home.appendingPathComponent("Desktop", isDirectory: true), systemImage: "menubar.dock.rectangle"),
            SidebarLocation(section: .favorites, name: L10n.tr("書類"), url: home.appendingPathComponent("Documents", isDirectory: true), systemImage: "doc"),
            SidebarLocation(section: .favorites, name: L10n.tr("ダウンロード"), url: home.appendingPathComponent("Downloads", isDirectory: true), systemImage: "arrow.down.circle")
        ]
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeIsEjectableKey]
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        result += volumes.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return SidebarLocation(
                section: .devices,
                name: values?.volumeName ?? url.lastPathComponent,
                url: url,
                systemImage: values?.volumeIsInternal == true ? "internaldrive" : "externaldrive",
                isEjectable: values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            )
        }
        return result
    }
}

struct FinderSidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    private let locations = SidebarLocationsProvider().locations()

    var body: some View {
        List {
            ForEach([SidebarLocation.Section.favorites, .devices], id: \.self) { section in
                Section(section.localizedTitle) {
                    ForEach(locations.filter { $0.section == section }) { location in
                        Button {
                            // No bookmark is fabricated or borrowed. If sandbox
                            // access is unavailable, PaneView exposes its picker.
                            workspace.navigate(paneID: workspace.state.activePaneID, to: location.url)
                        } label: {
                            Label(location.name, systemImage: location.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
    }
}

// MARK: - Trash drop target

struct TrashDropTargetView: NSViewRepresentable {
    @EnvironmentObject private var workspace: WorkspaceStore

    func makeNSView(context: Context) -> TrashDropNSView {
        let view = TrashDropNSView()
        view.onDrop = { urls, sourcePaneID in
            Task { @MainActor in
                let bookmark = sourcePaneID.flatMap { workspace.pane(id: $0)?.accessBookmark }
                workspace.trashImmediately(urls, accessBookmark: bookmark)
            }
        }
        return view
    }

    func updateNSView(_ nsView: TrashDropNSView, context: Context) {}
}

final class TrashDropNSView: NSView {
    var onDrop: (([URL], UUID?) -> Void)?
    private let internalType = NSPasteboard.PasteboardType("com.quadfinder.pane-item")
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, internalType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let image = NSImage(systemSymbolName: targeted ? "trash.fill" : "trash", accessibilityDescription: L10n.tr("ゴミ箱"))
        image?.draw(in: bounds.insetBy(dx: 5, dy: 5))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        targeted = readURLs(sender).isEmpty == false
        return targeted ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        targeted = !readURLs(sender).isEmpty
        return targeted ? .move : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = readURLs(sender)
        targeted = false
        let modifiers = DropModifierResolver.resolve(
            current: NSApp.currentEvent?.modifierFlags,
            tracked: DragModifierTracker.shared.trackedFlags
        )
        guard DropIntent.resolve(modifiers: modifiers, isTrashTarget: true) == .trash,
              !urls.isEmpty else { return false }
        onDrop?(urls, readInternalSourcePane(sender))
        DragModifierTracker.shared.reset()
        return true
    }

    private func readURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        let external = objects.map { ($0 as URL).standardizedFileURL }
        let internalURLs = readInternalPayloads(sender).map { $0.url.standardizedFileURL }
        return Array(Set(external + internalURLs)).sorted { $0.path < $1.path }
    }

    private func readInternalSourcePane(_ sender: any NSDraggingInfo) -> UUID? {
        let payloads = readInternalPayloads(sender)
        guard let source = payloads.first?.sourcePaneID,
              payloads.allSatisfy({ $0.sourcePaneID == source }) else { return nil }
        return source
    }

    private func readInternalPayloads(_ sender: any NSDraggingInfo) -> [PaneFileDragPayload] {
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item -> PaneFileDragPayload? in
            guard let data = item.data(forType: internalType) else { return nil }
            return try? JSONDecoder().decode(PaneFileDragPayload.self, from: data)
        }
    }
}

@MainActor
final class DragModifierTracker {
    static let shared = DragModifierTracker()
    private(set) var trackedFlags: NSEvent.ModifierFlags = []

    private init() {}

    /// Native NSTableView/NSCollectionView/NSOutlineView dragging sessions own
    /// modifier tracking and cursor badges. Kept as a compatibility no-op for
    /// the app lifecycle and non-browser drop targets.
    func start() {}
    func stop() { reset() }
    func reset() { trackedFlags = [] }
    func record(_ flags: NSEvent.ModifierFlags) { trackedFlags = flags.intersection(.deviceIndependentFlagsMask) }
}

enum DropModifierResolver {
    static func resolve(current: NSEvent.ModifierFlags?, tracked: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        let live = current?.intersection(.deviceIndependentFlagsMask) ?? []
        return live.isEmpty ? tracked : live
    }
}

struct SymbolicLinkRequest: Sendable {
    let sourceURLs: [URL]
    let targetDirectoryURL: URL
    let sourceAccessBookmark: Data?
    let targetAccessBookmark: Data?
}

struct SymbolicLinkService: Sendable {
    @discardableResult
    func createLinks(_ request: SymbolicLinkRequest) throws -> [URL] {
        let sources = request.sourceURLs.map(\.standardizedFileURL)
        guard !sources.isEmpty else { throw FileSystemError.noSources }
        let target = request.targetDirectoryURL.standardizedFileURL
        var scopes = SecurityScopeSession()
        defer { scopes.stop() }
        // Source and destination are deliberately separate scopes. A bookmark
        // for the destination must never be accepted as authority for source.
        try scopes.add(bookmark: request.sourceAccessBookmark, requestedURLs: sources)
        try scopes.add(bookmark: request.targetAccessBookmark, requestedURLs: [target])
        var plan: [(URL, URL)] = []
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else { throw FileSystemError.sourceUnavailable(source) }
            var sourceIsDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
            let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
            let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
            if sourceIsDirectory.boolValue,
               canonicalTarget.path.hasPrefix(canonicalSource.path.hasSuffix("/") ? canonicalSource.path : canonicalSource.path + "/") {
                throw FileSystemError.sourceInsideDestination(source)
            }
            let destination = target.appendingPathComponent(source.lastPathComponent).standardizedFileURL
            guard destination != source.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: destination.path),
                  !plan.contains(where: { $0.1 == destination }) else {
                throw FinderActionError.destinationConflict(destination)
            }
            plan.append((source.standardizedFileURL, destination))
        }
        var completed: [URL] = []
        var steps: [HistoryStep] = []
        for (source, destination) in plan {
            do {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
                completed.append(destination)
                if let fp = HistoryFingerprint.capture(destination) {
                    steps.append(.symbolicLink(source: source, target: destination, targetFingerprint: fp))
                }
            } catch {
                throw PartialOperationFailure(outcome: .init(completedBytes: 0, completedItems: completed.count,
                    resultingURLs: completed, historySteps: steps), underlying: error)
            }
        }
        return completed
    }
}
