import AppKit

enum NativeFileColumn: String, CaseIterable, Sendable {
    case name, size, modificationDate, cloud

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .name: L10n.tr("名前")
        case .size: L10n.tr("サイズ")
        case .modificationDate: L10n.tr("更新日")
        case .cloud: L10n.tr("クラウド状態")
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
        column.headerToolTip = kind == .cloud ? L10n.tr("iCloud上の項目の保存状態") : nil
        table.addTableColumn(column)
    }
}

@MainActor
func updateNativeSortIndicator(on table: NSTableView, sort: FileSortDescriptor?) {
    for kind in NativeFileColumn.allCases {
        guard let column = table.tableColumn(withIdentifier: kind.identifier) else { continue }
        column.title = kind.title
        column.headerCell.stringValue = kind.title
        column.headerCell.setAccessibilityLabel(kind.title)
        column.headerToolTip = kind == .cloud ? L10n.tr("iCloud上の項目の保存状態") : nil
        table.setIndicatorImage(nil, in: column)
    }
    guard let sort,
          let kind = NativeFileColumn.allCases.first(where: { $0.sortField == sort.field }),
          let column = table.tableColumn(withIdentifier: kind.identifier) else { return }

    if sort.foldersFirst {
        let direction = L10n.tr(sort.ascending ? "昇順" : "降順")
        let explanation = L10n.format("フォルダ優先・%@", direction)
        column.headerToolTip = explanation
        column.headerCell.setAccessibilityLabel("\(kind.title)、\(explanation)")
        table.setIndicatorImage(folderSortIndicator(ascending: sort.ascending, description: explanation), in: column)
        return
    }
    table.setIndicatorImage(
        NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
        in: column
    )
}

@MainActor
private func folderSortIndicator(ascending: Bool, description: String) -> NSImage {
    let folder = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    let arrow = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
    let result = NSImage(size: NSSize(width: 22, height: 11), flipped: false) { _ in
        folder?.draw(in: NSRect(x: 0, y: 0, width: 12, height: 10))
        arrow?.draw(in: NSRect(x: 15, y: 1, width: 7, height: 8))
        return true
    }
    result.isTemplate = true
    result.accessibilityDescription = description
    return result
}
