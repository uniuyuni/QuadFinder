import AppKit

enum NativeFileColumn: String, CaseIterable, Sendable {
    case name, size, modificationDate, cloud

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .name: "名前"
        case .size: "サイズ"
        case .modificationDate: "更新日"
        case .cloud: "クラウド状態"
        }
    }
    var defaultWidth: CGFloat {
        switch self {
        case .name: 230
        case .size: 82
        case .modificationDate: 125
        case .cloud: 100
        }
    }
    var minimumWidth: CGFloat {
        switch self {
        case .name: 90
        case .size: 55
        case .modificationDate: 75
        case .cloud: 70
        }
    }
    var maximumWidth: CGFloat { self == .name ? 900 : 400 }
    var sortField: FileSortField {
        switch self {
        case .name: .name
        case .size: .size
        case .modificationDate: .modificationDate
        case .cloud: .cloud
        }
    }
}

struct NativeColumnWidthStore: Sendable {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func key(paneID: UUID, mode: String, column: NativeFileColumn) -> String {
        "QuadFinder.nativeColumnWidth.\(paneID.uuidString).\(mode).\(column.rawValue)"
    }
    func width(paneID: UUID, mode: String, column: NativeFileColumn) -> CGFloat {
        let value = defaults.double(forKey: key(paneID: paneID, mode: mode, column: column))
        return clamp(value > 0 ? value : column.defaultWidth, column: column)
    }
    func save(_ width: CGFloat, paneID: UUID, mode: String, column: NativeFileColumn) {
        defaults.set(Double(clamp(width, column: column)), forKey: key(paneID: paneID, mode: mode, column: column))
    }
    func clamp(_ width: CGFloat, column: NativeFileColumn) -> CGFloat {
        min(column.maximumWidth, max(column.minimumWidth, width))
    }
}

@MainActor
func configureNativeFileColumns(on table: NSTableView, paneID: UUID, mode: String,
                                widthStore: NativeColumnWidthStore = .init()) {
    for kind in NativeFileColumn.allCases {
        let column = NSTableColumn(identifier: kind.identifier)
        column.title = kind.title
        column.minWidth = kind.minimumWidth
        column.maxWidth = kind.maximumWidth
        column.width = widthStore.width(paneID: paneID, mode: mode, column: kind)
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: kind.rawValue, ascending: true)
        column.headerToolTip = kind == .cloud ? "iCloud上の項目の保存状態" : nil
        table.addTableColumn(column)
    }
}
