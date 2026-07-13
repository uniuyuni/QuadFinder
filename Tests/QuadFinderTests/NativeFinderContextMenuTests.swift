import AppKit
import Testing
@testable import QuadFinder

@Suite("Native Finder context menu")
struct NativeFinderContextMenuTests {
    final class Target: NSObject {
        @objc func invoke(_ sender: NSMenuItem) {}
    }

    @Test @MainActor func trashIsInASeparateFinalSectionAndOpenWithIsASubmenu() throws {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try Data("test".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = Target()
        let configuration = NativeFinderContextMenuConfiguration(
            model: { _, _ in FinderContextActionModel(context: FinderContext(
                selectedURLs: [url], clickedURL: url, currentDirectory: directory,
                otherPaneCount: 0, clipboardContainsFiles: false)) },
            perform: { _, _, _ in }, openWith: { _, _, _ in }
        )
        let menu = makeNativeFinderContextMenu(clickedURL: url, selection: [url],
            configuration: configuration, target: target, action: #selector(Target.invoke(_:)))
        let trashIndex = try #require(menu.items.firstIndex { $0.title == "ゴミ箱に入れる" })
        #expect(trashIndex == menu.items.count - 1)
        #expect(trashIndex > 0 && menu.items[trashIndex - 1].isSeparatorItem)
        #expect(trashIndex < 2 || !menu.items[trashIndex - 2].isSeparatorItem)
        let openWith = try #require(menu.items.first { $0.title == "このアプリケーションで開く" })
        #expect(openWith.submenu?.items.last?.title == "その他…")
    }
}
