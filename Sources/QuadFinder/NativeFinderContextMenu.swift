import AppKit

struct NativeFinderContextMenuConfiguration {
    let model: (_ clickedURL: URL, _ selection: Set<URL>) -> FinderContextActionModel
    let perform: (_ action: FinderContextAction, _ clickedURL: URL, _ selection: Set<URL>) -> Void
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
    let groups: [[(String, FinderContextAction)]] = [
        [("開く", .open), ("クイックルック", .quickLook), ("新規タブで開く", .openInNewTab)],
        [("カット", .cut), ("コピー", .copy), ("貼り付け", .paste), ("複製", .duplicate), ("名前を変更…", .rename), ("新規フォルダ…", .newFolder)],
        [("ゴミ箱に入れる", .trash), ("情報を見る", .getInfo), ("パスをコピー", .copyPath), ("Finderに表示", .revealInFinder)]
    ]
    for (groupIndex, group) in groups.enumerated() {
        if groupIndex > 0 { menu.addItem(.separator()) }
        for (title, finderAction) in group {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = finderAction.rawValue
            item.isEnabled = model.isEnabled(finderAction)
            menu.addItem(item)
        }
    }
    if model.isEnabled(.showPackageContents) {
        menu.addItem(withTitle: "パッケージの内容を表示", action: action, keyEquivalent: "")
        menu.items.last?.target = target
        menu.items.last?.representedObject = FinderContextAction.showPackageContents.rawValue
    }
    return menu
}
