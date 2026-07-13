import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var showsPaneSets = false
    @State private var showsPaneLinks = false
    @State private var showsOperationHistory = false
    @StateObject private var sidebarStore = SidebarStore()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if sidebarStore.isVisible {
                HStack(spacing: 0) {
                    PersistentFinderSidebarView(store: sidebarStore, navigate: { favorite in
                        workspace.updatePane(id: workspace.state.activePaneID) {
                            $0.accessBookmark = favorite.bookmark
                        }
                        workspace.navigate(
                            paneID: workspace.state.activePaneID, to: favorite.url,
                            bookmark: favorite.bookmark
                        )
                    }, openRecent: { recent in
                        guard FileManager.default.fileExists(atPath: recent.url.path) else {
                            workspace.report("履歴項目を開けません", error: CocoaError(.fileNoSuchFile))
                            return
                        }
                        var scope: URL?
                        if AppSecurityEnvironment.current.isSandboxed, let bookmark = recent.bookmark,
                           let resolved = try? FileSystemService.resolveBookmark(bookmark),
                           resolved.startAccessingSecurityScopedResource() { scope = resolved }
                        defer { scope?.stopAccessingSecurityScopedResource() }
                        if recent.kind == .folder {
                            workspace.navigate(paneID: workspace.state.activePaneID, to: recent.url, bookmark: recent.bookmark)
                        } else if !NSWorkspace.shared.open(recent.url) {
                            workspace.report("履歴項目を開けません", error: CocoaError(.fileReadUnknown))
                        }
                    })
                    .frame(width: sidebarStore.width)
                    SidebarResizeHandle(store: sidebarStore)
                    paneArea
                }
            } else {
                paneArea
            }
            if workspace.state.moduleSettings.comparison.isVisible {
                Divider()
                ComparisonModuleView(controller: workspace.comparisonController)
            }
            if workspace.state.moduleSettings.operationQueue.isVisible {
                Divider()
                OperationQueueModuleView(queue: workspace.operationQueue)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .quadFinderSidebarEjectFailed)) { note in
            let error = note.userInfo?["error"] as? Error ?? CocoaError(.fileWriteUnknown)
            workspace.report("ディスクを取り出せません", error: error)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quadFinderSidebarDidEject)) { note in
            guard let volumeURL = note.object as? URL else { return }
            workspace.relocatePanesAfterEject(of: volumeURL)
        }
        .alert(item: $workspace.error) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "ファイル操作を選択",
            isPresented: Binding(get: { workspace.pendingDrop != nil }, set: { if !$0 { workspace.pendingDrop = nil } }),
            titleVisibility: .visible
        ) {
            Button("コピー") { workspace.performPendingDrop(as: .copy) }
            Button("移動") { workspace.performPendingDrop(as: .move) }
            Button("キャンセル", role: .cancel) { workspace.pendingDrop = nil }
        } message: {
            if let drop = workspace.pendingDrop {
                Text("\(drop.sourceURLs.count)項目\nコピー先: \(drop.targetDirectoryURL.path(percentEncoded: false))\n\n移動は元の場所から項目を削除します。")
            }
        }
        .sheet(item: $workspace.pendingTransfer) { transfer in
            TransferTargetSheet(transfer: transfer).environmentObject(workspace)
        }
        .sheet(item: $workspace.transferPlanner) { controller in
            TransferPlanSheet(controller: controller)
        }
        .sheet(isPresented: $showsPaneSets) {
            PaneSetSheet().environmentObject(workspace)
        }
        .sheet(isPresented: $showsPaneLinks) {
            PaneLinkSheet(group: workspace.state.paneLinkGroup).environmentObject(workspace)
        }
        .sheet(isPresented: $showsOperationHistory) {
            OperationHistoryView(store: workspace.operationHistory,
                                 undo: workspace.undoLastFileOperation,
                                 redo: workspace.redoLastFileOperation)
        }
        .onExitCommand {
            if workspace.state.maximizedPaneID != nil { workspace.toggleMaximize() }
        }
        .onChange(of: workspace.state.moduleSettings.comparison.isVisible) { _, visible in
            if !visible { workspace.comparisonController.cancel() }
        }
        .onDisappear { sidebarStore.stopObservingMounts() }
    }

    private var paneArea: some View {
        HStack(spacing: 0) {
            PaneGridView()
            if workspace.state.moduleSettings.selectionInfo.isVisible {
                Divider()
                SelectionInfoModuleView()
            }
            if workspace.state.moduleSettings.imagePreview.isVisible {
                Divider()
                ImagePreviewModuleView(pane: modulePane(workspace.state.moduleSettings.imagePreview.context)) {
                    workspace.updateModuleSettings { $0.imagePreview.isVisible = false }
                }
            }
            if workspace.state.moduleSettings.hexViewer.isVisible {
                Divider()
                HexViewerModuleView(selectedURLs: modulePane(workspace.state.moduleSettings.hexViewer.context)?.selectedURLs ?? []) {
                    workspace.updateModuleSettings { $0.hexViewer.isVisible = false }
                }
            }
        }
    }

    private func modulePane(_ context: ModuleContext) -> PaneState? {
        switch context {
        case .active, .window: workspace.activePane
        case .pinned(let id), .pair(let id, _): workspace.pane(id: id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { sidebarStore.isVisible.toggle() } label: {
                Label("サイドバー", systemImage: "sidebar.left")
            }
            .help(sidebarStore.isVisible ? "サイドバーを隠す" : "サイドバーを表示")
            Button { workspace.addPane() } label: { Label("ペインを追加", systemImage: "rectangle.split.2x2") }
                .disabled(!workspace.canAddPane)
            Button { workspace.closeActivePane() } label: { Label("閉じる", systemImage: "rectangle.badge.xmark") }
                .disabled(!workspace.canClosePane)
            Button { workspace.restoreClosedPane() } label: { Label("復元", systemImage: "arrow.uturn.backward") }
                .disabled(workspace.recentlyClosedPane == nil || !workspace.canAddPane)
            Divider().frame(height: 20)
            layoutMenu
            Button { showsPaneLinks = true } label: {
                Label("リンク", systemImage: workspace.state.paneLinkGroup == nil ? "link" : "link.circle.fill")
            }
            Menu {
                ForEach(workspace.destinationCandidates(excluding: workspace.state.activePaneID)) { destination in
                    Button("ペイン\(destination.paneNumber): \(destination.folderName)") {
                        workspace.setComparisonTarget(destination.paneID)
                    }
                }
            } label: { Label("比較", systemImage: "arrow.left.arrow.right.square") }
            .disabled(workspace.state.panes.count < 2)
            Button { workspace.toggleMaximize() } label: {
                Label(workspace.state.maximizedPaneID == nil ? "最大化" : "元に戻す", systemImage: workspace.state.maximizedPaneID == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .help("アクティブペインを一時最大化")
            Spacer()
            Button { showsOperationHistory = true } label: { Label("履歴", systemImage: "clock.arrow.circlepath") }
            TrashDropTargetView()
                .environmentObject(workspace)
                .frame(width: 36, height: 32)
                .zIndex(100)
                .help("ここへドラッグしてゴミ箱に入れる")
            Menu {
                Toggle("選択情報", isOn: Binding(
                    get: { workspace.state.moduleSettings.selectionInfo.isVisible },
                    set: { value in workspace.updateModuleSettings { $0.selectionInfo.isVisible = value } }
                ))
                Toggle("操作キュー", isOn: Binding(
                    get: { workspace.state.moduleSettings.operationQueue.isVisible },
                    set: { value in workspace.updateModuleSettings { $0.operationQueue.isVisible = value } }
                ))
                Toggle("フォルダ比較", isOn: Binding(
                    get: { workspace.state.moduleSettings.comparison.isVisible },
                    set: { value in workspace.updateModuleSettings { $0.comparison.isVisible = value } }
                ))
                Toggle("画像表示", isOn: Binding(
                    get: { workspace.state.moduleSettings.imagePreview.isVisible },
                    set: { value in workspace.updateModuleSettings { $0.imagePreview.isVisible = value } }
                ))
                Toggle("Hexビューアー", isOn: Binding(
                    get: { workspace.state.moduleSettings.hexViewer.isVisible },
                    set: { value in workspace.updateModuleSettings { $0.hexViewer.isVisible = value } }
                ))
            } label: { Label("モジュール", systemImage: "sidebar.right") }
            Button { showsPaneSets = true } label: { Label("セット", systemImage: "square.grid.2x2") }
            Text("\(workspace.state.panes.count)ペイン")
                .foregroundStyle(.secondary)
            if let pane = workspace.activePane {
                Text(pane.currentURL.lastPathComponent.isEmpty ? "/" : pane.currentURL.lastPathComponent)
                    .lineLimit(1)
                    .help("アクティブペイン")
            }
            FileOperationProgressBadge(queue: workspace.operationQueue)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    @ViewBuilder
    private var layoutMenu: some View {
        Menu {
            switch workspace.state.panes.count {
            case 1:
                Button("1ペイン") { workspace.setLayout(.single) }
            case 2:
                Button("左右") { workspace.setLayout(.vertical) }
                Button("上下") { workspace.setLayout(.horizontal) }
            case 3:
                Button("左＋右上下") { workspace.setLayout(.leading) }
                Button("左上下＋右") { workspace.setLayout(.trailing) }
                Button("上＋下左右") { workspace.setLayout(.top) }
                Button("上左右＋下") { workspace.setLayout(.bottom) }
            default:
                Button("2×2") { workspace.setLayout(.grid) }
            }
            Divider()
            Button("分割比率を50:50に戻す") { workspace.resetRatios() }
            if workspace.state.panes.count > 1 {
                Divider()
                Menu("アクティブペインと交換") {
                    ForEach(Array(workspace.state.orderedPaneIDs.enumerated()), id: \.element) { index, id in
                        Button("ペイン\(index + 1)") { workspace.swapActive(with: id) }
                            .disabled(id == workspace.state.activePaneID)
                    }
                }
            }
        } label: {
            Label(workspace.state.layout.title, systemImage: "rectangle.3.group")
        }
    }
}

extension Notification.Name {
    static let quadFinderSidebarEjectFailed = Notification.Name("QuadFinder.SidebarEjectFailed")
    static let quadFinderSidebarDidEject = Notification.Name("QuadFinder.SidebarDidEject")
}

private struct SidebarResizeHandle: View {
    @ObservedObject var store: SidebarStore
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .frame(width: 5)
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                store.updateWidthDrag(screenX: Double(value.location.x), startScreenX: Double(value.startLocation.x))
            }
            .onEnded { _ in store.endWidthDrag() })
        .accessibilityLabel("サイドバーの幅")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: store.setWidth(store.width + 10)
            case .decrement: store.setWidth(store.width - 10)
            @unknown default: break
            }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
    }
}
