import AppKit
import SwiftUI

@main
struct QuadFinderApp: App {
    @StateObject private var workspace = WorkspaceStore()

    var body: some Scene {
        Window("QuadFinder", id: "main") {
            ContentView()
                .environmentObject(workspace)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("取り消す") {
                    if !AppCommandRouting.sendTextAction(Selector(("undo:"))) {
                        workspace.undoLastFileOperation()
                    }
                }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("やり直す") {
                    if !AppCommandRouting.sendTextAction(Selector(("redo:"))) {
                        workspace.redoLastFileOperation()
                    }
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("QuadFinderについて") { AppVersion.showAboutPanel() }
            }
            CommandGroup(replacing: .pasteboard) {
                Button("コピー") {
                    if !AppCommandRouting.sendTextAction(#selector(NSText.copy(_:))) {
                        workspace.copySelectionToClipboard(cut: false)
                    }
                }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("カット") {
                    if !AppCommandRouting.sendTextAction(#selector(NSText.cut(_:))) {
                        workspace.copySelectionToClipboard(cut: true)
                    }
                }
                    .keyboardShortcut("x", modifiers: [.command])
                Button("貼り付け") {
                    if !AppCommandRouting.sendTextAction(#selector(NSText.paste(_:))) {
                        workspace.preparePasteFromClipboard()
                    }
                }
                    .keyboardShortcut("v", modifiers: [.command])
                Divider()
                Button("クイックルック") { workspace.quickLookSelection() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("ゴミ箱に入れる") { workspace.moveSelectionToTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Divider()
                Button("すべてを選択") {
                    if !AppCommandRouting.sendSelectAllToFirstResponder() {
                        NotificationCenter.default.post(name: .quadFinderSelectAllInActivePane, object: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { AppCommandRouting.sendSaveToFirstResponder() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("ペインを追加") { workspace.addPane() }
                    .keyboardShortcut("n", modifiers: [.control, .option, .command])
                    .disabled(!workspace.canAddPane)
                Button("アクティブペインを閉じる") { workspace.closeActivePane() }
                    .keyboardShortcut("w", modifiers: [.control, .option, .command])
                    .disabled(!workspace.canClosePane)
                Button("閉じたペインを復元") { workspace.restoreClosedPane() }
                    .disabled(workspace.recentlyClosedPane == nil || !workspace.canAddPane)
            }
            CommandMenu("ペイン") {
                Button("次のペイン") { workspace.activateNext() }
                    .keyboardShortcut(.tab, modifiers: [.control])
                Button("前のペイン") { workspace.activateNext(reverse: true) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                Button("ペイン1") { workspace.activatePane(number: 1) }
                    .keyboardShortcut("1", modifiers: [.control])
                Button("ペイン2") { workspace.activatePane(number: 2) }
                    .keyboardShortcut("2", modifiers: [.control])
                    .disabled(workspace.state.panes.count < 2)
                Button("ペイン3") { workspace.activatePane(number: 3) }
                    .keyboardShortcut("3", modifiers: [.control])
                    .disabled(workspace.state.panes.count < 3)
                Button("ペイン4") { workspace.activatePane(number: 4) }
                    .keyboardShortcut("4", modifiers: [.control])
                    .disabled(workspace.state.panes.count < 4)
                Divider()
                Button("左のペイン") { workspace.activateDirection(horizontal: -1, vertical: 0) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                Button("右のペイン") { workspace.activateDirection(horizontal: 1, vertical: 0) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                Button("上のペイン") { workspace.activateDirection(horizontal: 0, vertical: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option])
                Button("下のペイン") { workspace.activateDirection(horizontal: 0, vertical: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option])
                Divider()
                Button(workspace.state.maximizedPaneID == nil ? "アクティブペインを一時最大化" : "グリッドに戻す") {
                    workspace.toggleMaximize()
                }
                .keyboardShortcut(.return, modifiers: [.control, .option])
                Divider()
                Button("選択項目を他ペインへコピー") { workspace.prepareExplicitTransfer(kind: .copy) }
                    .keyboardShortcut(KeyEquivalent(Character("\u{F708}")), modifiers: [])
                Button("選択項目を他ペインへ移動") { workspace.prepareExplicitTransfer(kind: .move) }
                    .keyboardShortcut(KeyEquivalent(Character("\u{F709}")), modifiers: [])
            }
        }
    }
}

@MainActor
enum AppCommandRouting {
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    @discardableResult
    static func sendTextAction(_ action: Selector) -> Bool {
        guard isTextInput(NSApp.keyWindow?.firstResponder) else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    static func sendSelectAllToFirstResponder() -> Bool {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }

    static func sendSaveToFirstResponder() {
        _ = NSApp.sendAction(Selector(("quadFinderSave:")), to: nil, from: nil)
    }
}
