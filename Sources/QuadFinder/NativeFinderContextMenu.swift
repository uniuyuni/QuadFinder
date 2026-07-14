import AppKit

struct NativeFinderContextMenuConfiguration {
    let model: (_ clickedURL: URL, _ selection: Set<URL>) -> FinderContextActionModel
    let perform: (_ action: FinderContextAction, _ clickedURL: URL, _ selection: Set<URL>) -> Void
    let openWith: (_ applicationURL: URL?, _ clickedURL: URL, _ selection: Set<URL>) -> Void
}

final class NativeOpenWithCommand: NSObject {
    let applicationURL: URL?
    init(_ applicationURL: URL?) { self.applicationURL = applicationURL }
}

@MainActor
func makeNativeFinderContextMenu(
    clickedURL: URL,
    selection: Set<URL>,
    configuration: NativeFinderContextMenuConfiguration,
    target: AnyObject,
    action: Selector
) -> NSMenu {
    let model = configuration.model(clickedURL, selection)
    let menu = NSMenu()
    let targets = Array(PaneSelectionPolicy.contextTargets(clicked: clickedURL, selection: selection))
    let groups: [[(String, FinderContextAction)]] = [
        [(L10n.tr("開く"), .open), (L10n.tr("クイックルック"), .quickLook), (L10n.tr("新規タブで開く"), .openInNewTab)],
        [(L10n.tr("カット"), .cut), (L10n.tr("コピー"), .copy), (L10n.tr("貼り付け"), .paste), (L10n.tr("複製"), .duplicate), (L10n.tr("名前を変更…"), .rename), (L10n.tr("新規フォルダ…"), .newFolder)],
        [(L10n.tr("情報を見る"), .getInfo), (L10n.tr("パスをコピー"), .copyPath), (L10n.tr("Finderに表示"), .revealInFinder)],
        [(L10n.tr("ゴミ箱に入れる"), .trash)]
    ]
    for (groupIndex, group) in groups.enumerated() {
        if groupIndex > 0 { menu.addItem(.separator()) }
        for (title, finderAction) in group {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = finderAction.rawValue
            item.isEnabled = model.isEnabled(finderAction)
            menu.addItem(item)
            if finderAction == .open, targets.count == 1,
               !targets[0].hasDirectoryPath {
                menu.addItem(makeOpenWithMenu(url: targets[0], target: target, action: action))
            }
        }
    }
    if model.isEnabled(.showPackageContents) {
        menu.addItem(withTitle: L10n.tr("パッケージの内容を表示"), action: action, keyEquivalent: "")
        menu.items.last?.target = target
        menu.items.last?.representedObject = FinderContextAction.showPackageContents.rawValue
    }
    return menu
}

@MainActor
private func makeOpenWithMenu(url: URL, target: AnyObject, action: Selector) -> NSMenuItem {
    let parent = NSMenuItem(title: L10n.tr("このアプリケーションで開く"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: parent.title)
    let workspace = NSWorkspace.shared
    let defaultURL = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
    var seen = Set<String>()
    var applications = workspace.urlsForApplications(toOpen: url).map(\.standardizedFileURL)
    if let defaultURL { applications.insert(defaultURL, at: 0) }
    applications = applications.filter { seen.insert($0.path).inserted }
    applications.sort {
        if $0 == defaultURL { return true }
        if $1 == defaultURL { return false }
        return applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending
    }
    for appURL in applications {
        let suffix = appURL == defaultURL ? L10n.tr("（デフォルト）") : ""
        let item = NSMenuItem(title: applicationName(appURL) + suffix, action: action, keyEquivalent: "")
        item.target = target
        item.image = workspace.icon(forFile: appURL.path)
        item.image?.size = NSSize(width: 16, height: 16)
        item.representedObject = NativeOpenWithCommand(appURL)
        submenu.addItem(item)
    }
    if !submenu.items.isEmpty { submenu.addItem(.separator()) }
    let other = NSMenuItem(title: L10n.tr("その他…"), action: action, keyEquivalent: "")
    other.target = target
    other.representedObject = NativeOpenWithCommand(nil)
    submenu.addItem(other)
    parent.submenu = submenu
    return parent
}

private func applicationName(_ url: URL) -> String {
    (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
        ?? url.deletingPathExtension().lastPathComponent
}
