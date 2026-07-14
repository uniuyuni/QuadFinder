import AppKit
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

enum PaneSlot: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var shortName: String {
        switch self {
        case .topLeft: "TL"
        case .topRight: "TR"
        case .bottomLeft: "BL"
        case .bottomRight: "BR"
        }
    }
}

enum PaneLayout: String, Codable, CaseIterable, Sendable {
    case single
    case vertical
    case horizontal
    case leading
    case trailing
    case top
    case bottom
    case grid

    var title: String {
        switch self {
        case .single: L10n.tr("1ペイン")
        case .vertical: L10n.tr("左右")
        case .horizontal: L10n.tr("上下")
        case .leading: L10n.tr("左＋右上下")
        case .trailing: L10n.tr("左上下＋右")
        case .top: L10n.tr("上＋下左右")
        case .bottom: L10n.tr("上左右＋下")
        case .grid: L10n.tr("2×2")
        }
    }
}

enum FileViewStyle: String, Codable, CaseIterable, Sendable {
    case list, icons, columns, tree
}

enum FileSortField: String, Codable, CaseIterable, Sendable {
    case name, size, modificationDate, cloud
}

struct FileSortDescriptor: Codable, Equatable, Sendable {
    var field: FileSortField = .name
    var ascending: Bool = true
    var foldersFirst: Bool = false

    init(field: FileSortField = .name, ascending: Bool = true, foldersFirst: Bool = false) {
        self.field = field
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    mutating func select(_ field: FileSortField) {
        guard self.field == field else {
            self.field = field
            ascending = true
            foldersFirst = false
            return
        }
        switch (foldersFirst, ascending) {
        case (false, true): ascending = false
        case (false, false): foldersFirst = true; ascending = true
        case (true, true): ascending = false
        case (true, false): foldersFirst = false; ascending = true
        }
    }

    func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if foldersFirst {
                let lhsIsFolder = lhs.isDirectory && !lhs.isPackage
                let rhsIsFolder = rhs.isDirectory && !rhs.isPackage
                if lhsIsFolder != rhsIsFolder { return lhsIsFolder }
            }
            let order: ComparisonResult
            switch field {
            case .name: order = lhs.name.localizedStandardCompare(rhs.name)
            case .size: order = (lhs.size ?? -1) == (rhs.size ?? -1) ? lhs.name.localizedStandardCompare(rhs.name) : ((lhs.size ?? -1) < (rhs.size ?? -1) ? .orderedAscending : .orderedDescending)
            case .modificationDate: order = (lhs.modificationDate ?? .distantPast) == (rhs.modificationDate ?? .distantPast) ? lhs.name.localizedStandardCompare(rhs.name) : ((lhs.modificationDate ?? .distantPast) < (rhs.modificationDate ?? .distantPast) ? .orderedAscending : .orderedDescending)
            case .cloud:
                let statusOrder = (lhs.cloudDownloadStatus ?? "").localizedStandardCompare(rhs.cloudDownloadStatus ?? "")
                order = statusOrder == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : statusOrder
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private enum CodingKeys: String, CodingKey { case field, ascending, foldersFirst }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decodeIfPresent(FileSortField.self, forKey: .field) ?? .name
        ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        foldersFirst = try container.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? false
    }
}

struct TabState: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var currentURL: URL
    var backwardHistory: [URL]
    var forwardHistory: [URL]
    var selectedURLs: Set<URL>
    var viewStyle: FileViewStyle
    var showsHiddenFiles: Bool
    var scrollAnchor: URL?
    var accessBookmark: Data?
    var sortDescriptor: FileSortDescriptor

    init(id: UUID = UUID(), currentURL: URL) {
        self.id = id
        self.currentURL = currentURL
        self.backwardHistory = []
        self.forwardHistory = []
        self.selectedURLs = []
        self.viewStyle = .list
        self.showsHiddenFiles = false
        self.scrollAnchor = nil
        self.accessBookmark = nil
        self.sortDescriptor = FileSortDescriptor()
    }


    private enum CodingKeys: String, CodingKey {
        case id, currentURL, backwardHistory, forwardHistory, selectedURLs, viewStyle
        case showsHiddenFiles, scrollAnchor, accessBookmark, sortDescriptor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        currentURL = try container.decode(URL.self, forKey: .currentURL)
        backwardHistory = try container.decodeIfPresent([URL].self, forKey: .backwardHistory) ?? []
        forwardHistory = try container.decodeIfPresent([URL].self, forKey: .forwardHistory) ?? []
        selectedURLs = try container.decodeIfPresent(Set<URL>.self, forKey: .selectedURLs) ?? []
        viewStyle = try container.decodeIfPresent(FileViewStyle.self, forKey: .viewStyle) ?? .list
        showsHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
        scrollAnchor = try container.decodeIfPresent(URL.self, forKey: .scrollAnchor)
        accessBookmark = try container.decodeIfPresent(Data.self, forKey: .accessBookmark)
        sortDescriptor = try container.decodeIfPresent(FileSortDescriptor.self, forKey: .sortDescriptor) ?? FileSortDescriptor()
    }
}

struct PaneState: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var tabs: [TabState]
    var activeTabID: UUID

    init(id: UUID = UUID(), currentURL: URL) {
        self.id = id
        let tab = TabState(currentURL: currentURL)
        self.tabs = [tab]
        self.activeTabID = tab.id
    }

    var activeTabIndex: Int { tabs.firstIndex { $0.id == activeTabID } ?? 0 }
    var currentURL: URL {
        get { tabs[activeTabIndex].currentURL }
        set { tabs[activeTabIndex].currentURL = newValue }
    }
    var backwardHistory: [URL] {
        get { tabs[activeTabIndex].backwardHistory }
        set { tabs[activeTabIndex].backwardHistory = newValue }
    }
    var forwardHistory: [URL] {
        get { tabs[activeTabIndex].forwardHistory }
        set { tabs[activeTabIndex].forwardHistory = newValue }
    }
    var selectedURLs: Set<URL> {
        get { tabs[activeTabIndex].selectedURLs }
        set { tabs[activeTabIndex].selectedURLs = newValue }
    }
    var viewStyle: FileViewStyle {
        get { tabs[activeTabIndex].viewStyle }
        set { tabs[activeTabIndex].viewStyle = newValue }
    }
    var showsHiddenFiles: Bool {
        get { tabs[activeTabIndex].showsHiddenFiles }
        set { tabs[activeTabIndex].showsHiddenFiles = newValue }
    }
    var scrollAnchor: URL? {
        get { tabs[activeTabIndex].scrollAnchor }
        set { tabs[activeTabIndex].scrollAnchor = newValue }
    }
    var accessBookmark: Data? {
        get { tabs[activeTabIndex].accessBookmark }
        set { tabs[activeTabIndex].accessBookmark = newValue }
    }
    var sortDescriptor: FileSortDescriptor {
        get { tabs[activeTabIndex].sortDescriptor }
        set { tabs[activeTabIndex].sortDescriptor = newValue }
    }

    mutating func normalize(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        var seen = Set<UUID>()
        tabs = tabs.filter { seen.insert($0.id).inserted }
        if tabs.isEmpty { tabs = [TabState(currentURL: homeURL)] }
        if !tabs.contains(where: { $0.id == activeTabID }) { activeTabID = tabs[0].id }
    }

    private enum CodingKeys: String, CodingKey {
        case id, tabs, activeTabID
        case currentURL, backwardHistory, forwardHistory, selectedURLs, viewStyle
        case showsHiddenFiles, scrollAnchor, accessBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let decodedTabs = try container.decodeIfPresent([TabState].self, forKey: .tabs), !decodedTabs.isEmpty {
            tabs = decodedTabs
            activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID) ?? decodedTabs[0].id
        } else {
            let url = try container.decode(URL.self, forKey: .currentURL)
            var tab = TabState(currentURL: url)
            tab.backwardHistory = try container.decodeIfPresent([URL].self, forKey: .backwardHistory) ?? []
            tab.forwardHistory = try container.decodeIfPresent([URL].self, forKey: .forwardHistory) ?? []
            tab.selectedURLs = try container.decodeIfPresent(Set<URL>.self, forKey: .selectedURLs) ?? []
            tab.viewStyle = try container.decodeIfPresent(FileViewStyle.self, forKey: .viewStyle) ?? .list
            tab.showsHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
            tab.scrollAnchor = try container.decodeIfPresent(URL.self, forKey: .scrollAnchor)
            tab.accessBookmark = try container.decodeIfPresent(Data.self, forKey: .accessBookmark)
            tabs = [tab]
            activeTabID = tab.id
        }
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(activeTabID, forKey: .activeTabID)
    }
}

enum ModuleKind: String, Codable, CaseIterable, Sendable {
    case selectionInfo
    case operationQueue
    case imagePreview
    case hexViewer
    case textEditor
}

enum ModuleContext: Codable, Equatable, Sendable {
    case active
    case pinned(UUID)
    case pair(UUID, UUID)
    case window
}

struct ModuleConfiguration: Codable, Equatable, Sendable {
    var isVisible: Bool
    var context: ModuleContext
}

struct ModuleSettings: Codable, Equatable, Sendable {
    var selectionInfo = ModuleConfiguration(isVisible: false, context: .active)
    var operationQueue = ModuleConfiguration(isVisible: true, context: .window)
    var comparison = ModuleConfiguration(isVisible: false, context: .active)
    var imagePreview = ModuleConfiguration(isVisible: false, context: .active)
    var hexViewer = ModuleConfiguration(isVisible: false, context: .active)
    var textEditor = ModuleConfiguration(isVisible: false, context: .active)

    private enum CodingKeys: String, CodingKey { case selectionInfo, operationQueue, comparison, imagePreview, hexViewer, textEditor }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectionInfo = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .selectionInfo)
            ?? ModuleConfiguration(isVisible: false, context: .active)
        operationQueue = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .operationQueue)
            ?? ModuleConfiguration(isVisible: true, context: .window)
        comparison = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .comparison)
            ?? ModuleConfiguration(isVisible: false, context: .active)
        imagePreview = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .imagePreview)
            ?? ModuleConfiguration(isVisible: false, context: .active)
        hexViewer = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .hexViewer)
            ?? ModuleConfiguration(isVisible: false, context: .active)
        textEditor = try c.decodeIfPresent(ModuleConfiguration.self, forKey: .textEditor)
            ?? ModuleConfiguration(isVisible: false, context: .active)
    }
}

struct WorkspaceState: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version = currentVersion
    var panes: [PaneState]
    var slots: [PaneSlot: UUID]
    var activePaneID: UUID
    var previousActivePaneID: UUID?
    var layout: PaneLayout
    var verticalRatio: Double
    var horizontalRatio: Double
    var maximizedPaneID: UUID?
    var moduleSettings: ModuleSettings
    var paneLinkGroup: PaneLinkGroup?

    static func initial(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> WorkspaceState {
        let pane = PaneState(currentURL: homeURL)
        return WorkspaceState(
            panes: [pane],
            slots: [.topLeft: pane.id],
            activePaneID: pane.id,
            previousActivePaneID: nil,
            layout: .single,
            verticalRatio: 0.5,
            horizontalRatio: 0.5,
            maximizedPaneID: nil,
            moduleSettings: ModuleSettings(),
            paneLinkGroup: nil
        )
    }

    var orderedPaneIDs: [UUID] {
        PaneSlot.allCases.compactMap { slots[$0] }
    }

    mutating func normalize() {
        version = Self.currentVersion
        var seenPaneIDs = Set<UUID>()
        panes = Array(panes.filter { seenPaneIDs.insert($0.id).inserted }.prefix(4))
        if panes.isEmpty {
            self = .initial()
            return
        }
        for index in panes.indices { panes[index].normalize() }
        let validIDs = Set(panes.map(\.id))
        var assignedSlotIDs = Set<UUID>()
        slots = Dictionary(uniqueKeysWithValues: PaneSlot.allCases.compactMap { slot in
            guard let id = slots[slot], validIDs.contains(id), assignedSlotIDs.insert(id).inserted else { return nil }
            return (slot, id)
        })
        let assigned = Set(slots.values)
        let freeSlots = PaneSlot.allCases.filter { slots[$0] == nil }
        for (pane, slot) in Swift.zip(panes.filter({ !assigned.contains($0.id) }), freeSlots) {
            slots[slot] = pane.id
        }
        if !validIDs.contains(activePaneID) {
            activePaneID = orderedPaneIDs.first ?? panes[0].id
        }
        if let previousActivePaneID, !validIDs.contains(previousActivePaneID) {
            self.previousActivePaneID = nil
        }
        if let maximizedPaneID, !validIDs.contains(maximizedPaneID) {
            self.maximizedPaneID = nil
        }
        verticalRatio = min(max(verticalRatio, 0.2), 0.8)
        horizontalRatio = min(max(horizontalRatio, 0.2), 0.8)
        layout = Self.defaultLayout(for: panes.count, preferred: layout)
        if case .pinned(let id) = moduleSettings.selectionInfo.context,
           !validIDs.contains(id) {
            moduleSettings.selectionInfo.context = .active
        }
        if case .pinned(let id) = moduleSettings.imagePreview.context, !validIDs.contains(id) {
            moduleSettings.imagePreview.context = .active
        }
        if case .pinned(let id) = moduleSettings.hexViewer.context, !validIDs.contains(id) {
            moduleSettings.hexViewer.context = .active
        }
        if case .pinned(let id) = moduleSettings.textEditor.context, !validIDs.contains(id) {
            moduleSettings.textEditor.context = .active
        }
        moduleSettings.operationQueue.context = .window
        if case .pair(let source, let target) = moduleSettings.comparison.context {
            if source == target || !validIDs.contains(source) || !validIDs.contains(target) {
                moduleSettings.comparison.context = .active
            }
        } else if moduleSettings.comparison.context != .active {
            moduleSettings.comparison.context = .active
        }
        if var group = paneLinkGroup {
            group.paneIDs = group.paneIDs.intersection(validIDs)
            paneLinkGroup = group.paneIDs.count >= 2 ? group : nil
        }
    }

    static func defaultLayout(for count: Int, preferred: PaneLayout? = nil) -> PaneLayout {
        switch count {
        case 1: .single
        case 2: preferred == .horizontal ? .horizontal : .vertical
        case 3:
            if let preferred, [.leading, .trailing, .top, .bottom].contains(preferred) {
                preferred
            } else {
                .leading
            }
        default: .grid
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, panes, slots, activePaneID, previousActivePaneID, layout
        case verticalRatio, horizontalRatio, maximizedPaneID, moduleSettings, paneLinkGroup
    }

    init(
        version: Int = currentVersion,
        panes: [PaneState],
        slots: [PaneSlot: UUID],
        activePaneID: UUID,
        previousActivePaneID: UUID?,
        layout: PaneLayout,
        verticalRatio: Double,
        horizontalRatio: Double,
        maximizedPaneID: UUID?,
        moduleSettings: ModuleSettings = ModuleSettings(),
        paneLinkGroup: PaneLinkGroup? = nil
    ) {
        self.version = version
        self.panes = panes
        self.slots = slots
        self.activePaneID = activePaneID
        self.previousActivePaneID = previousActivePaneID
        self.layout = layout
        self.verticalRatio = verticalRatio
        self.horizontalRatio = horizontalRatio
        self.maximizedPaneID = maximizedPaneID
        self.moduleSettings = moduleSettings
        self.paneLinkGroup = paneLinkGroup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        panes = try c.decode([PaneState].self, forKey: .panes)
        slots = try c.decode([PaneSlot: UUID].self, forKey: .slots)
        activePaneID = try c.decode(UUID.self, forKey: .activePaneID)
        previousActivePaneID = try c.decodeIfPresent(UUID.self, forKey: .previousActivePaneID)
        layout = try c.decode(PaneLayout.self, forKey: .layout)
        verticalRatio = try c.decodeIfPresent(Double.self, forKey: .verticalRatio) ?? 0.5
        horizontalRatio = try c.decodeIfPresent(Double.self, forKey: .horizontalRatio) ?? 0.5
        maximizedPaneID = try c.decodeIfPresent(UUID.self, forKey: .maximizedPaneID)
        moduleSettings = try c.decodeIfPresent(ModuleSettings.self, forKey: .moduleSettings) ?? ModuleSettings()
        paneLinkGroup = try c.decodeIfPresent(PaneLinkGroup.self, forKey: .paneLinkGroup)
        normalize()
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let isUbiquitous: Bool
    let cloudDownloadStatus: String?
    var isSymbolicLink: Bool = false
    /// File packages (for example, `.app`) are directories on disk but are
    /// opened as documents/applications when their name is activated.
    var isPackage: Bool = false

    var id: URL { url }
    var name: String { url.lastPathComponent }

    func replacingSize(_ value: Int64?) -> FileItem {
        FileItem(url: url, isDirectory: isDirectory, size: value,
                 modificationDate: modificationDate, isUbiquitous: isUbiquitous,
                 cloudDownloadStatus: cloudDownloadStatus,
                 isSymbolicLink: isSymbolicLink, isPackage: isPackage)
    }
}

enum FileItemActivationPolicy {
    static func navigatesInside(_ item: FileItem) -> Bool {
        item.isDirectory && !item.isPackage
    }
}

enum FileOperationKind: String, Sendable {
    case copy = "コピー"
    case move = "移動"
    case sync = "同期"

    var localizedTitle: String { L10n.tr(rawValue) }
}

enum DropIntent: Equatable, Sendable {
    case trash
    case transfer
    case symbolicLink

    static func resolve(modifiers: NSEvent.ModifierFlags, isTrashTarget: Bool) -> DropIntent {
        if isTrashTarget { return .trash }
        return modifiers.contains([.command, .option]) ? .symbolicLink : .transfer
    }
}

struct PendingFileOperation: Identifiable, Sendable {
    let id = UUID()
    let kind: FileOperationKind
    let sourcePaneID: UUID?
    let targetPaneID: UUID
    let sourceURLs: [URL]
    let targetDirectoryURL: URL
    let sourceAccessBookmark: Data?
    let targetAccessBookmark: Data?
    let syncPlan: SyncExecutionPlan?
    let transferPlan: TransferExecutionPlan?
    let clipboardCutReceipt: ClipboardCutReceipt?
    let historyReplay: HistoryReplayPlan?

    init(
        kind: FileOperationKind,
        sourcePaneID: UUID?,
        targetPaneID: UUID,
        sourceURLs: [URL],
        targetDirectoryURL: URL,
        sourceAccessBookmark: Data? = nil,
        targetAccessBookmark: Data? = nil,
        syncPlan: SyncExecutionPlan? = nil,
        transferPlan: TransferExecutionPlan? = nil,
        clipboardCutReceipt: ClipboardCutReceipt? = nil,
        historyReplay: HistoryReplayPlan? = nil
    ) {
        self.kind = kind
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
        self.sourceURLs = sourceURLs
        self.targetDirectoryURL = targetDirectoryURL
        self.sourceAccessBookmark = sourceAccessBookmark
        self.targetAccessBookmark = targetAccessBookmark
        self.syncPlan = syncPlan
        self.transferPlan = transferPlan
        self.clipboardCutReceipt = clipboardCutReceipt
        self.historyReplay = historyReplay
    }
}

extension UTType {
    static let quadFinderPaneItem = UTType(exportedAs: "com.quadfinder.pane-item")
    static let quadFinderPaneBatch = UTType(exportedAs: "com.quadfinder.pane-item-batch")
    static let quadFinderSidebarFavorite = UTType(exportedAs: "com.quadfinder.sidebar-favorite")
}

struct PaneFileDragPayload: Codable, Transferable, Sendable {
    let sourcePaneID: UUID
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // Finder and the Dock Trash consume public.file-url.  Keep this as an
        // explicit representation (rather than relying only on URL's proxy)
        // while retaining the typed payload used between QuadFinder panes.
        DataRepresentation(exportedContentType: .fileURL) { payload in
            Data(payload.url.absoluteString.utf8)
        }
        CodableRepresentation(contentType: .quadFinderPaneItem)
    }
}

struct PaneFileDragBatchPayload: Codable, Transferable, Sendable {
    let payloads: [PaneFileDragPayload]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quadFinderPaneBatch)
    }
}

/// Private representation used only to reorder Favorites.  It deliberately
/// does not vend `public.file-url`: dropping a sidebar row must never be
/// mistaken for moving the folder itself on disk.
struct SidebarFavoriteDragPayload: Codable, Transferable, Sendable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quadFinderSidebarFavorite)
    }
}

/// AppKit-compatible provider used by file rows. NSURL's native writer is
/// important here: the Dock Trash does not understand an app-private
/// Transferable representation, while QuadFinder drop targets still need the
/// source pane ID carried by the private type.
enum PaneDragItemProvider {
    static func make(_ payload: PaneFileDragPayload) -> NSItemProvider {
        let provider = NSItemProvider(object: payload.url as NSURL)
        provider.suggestedName = payload.url.lastPathComponent
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.quadFinderPaneItem.identifier,
            visibility: .ownProcess
        ) { completion in
            do { completion(try JSONEncoder().encode(payload), nil) }
            catch { completion(nil, error) }
            return nil
        }
        return provider
    }

    static func makeBatch(_ payloads: [PaneFileDragPayload]) -> NSItemProvider {
        guard let first = payloads.first else { return NSItemProvider() }
        let provider = NSItemProvider(object: first.url as NSURL)
        provider.suggestedName = payloads.count == 1 ? first.url.lastPathComponent : L10n.format("%d項目", payloads.count)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.quadFinderPaneBatch.identifier,
            visibility: .ownProcess
        ) { completion in
            do { completion(try JSONEncoder().encode(PaneFileDragBatchPayload(payloads: payloads)), nil) }
            catch { completion(nil, error) }
            return nil
        }
        return provider
    }
}

struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
