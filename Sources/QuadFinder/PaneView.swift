import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TabMenuPresentation {
    static let accessibilityLabel = "タブ操作"
    /// The borderless macOS Menu draws the only visible disclosure indicator.
    static let customIndicatorSymbol: String? = nil
}

struct PaneView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let paneID: UUID
    let paneNumber: Int

    @StateObject private var browser: PaneBrowserModel
    @State private var isDropTargeted = false
    @State private var selectionAnchor: URL?
    @State private var getInfoModel: GetInfoModel?
    @ObservedObject private var clipboard = FinderClipboard.shared

    init(paneID: UUID, paneNumber: Int) {
        self.paneID = paneID
        self.paneNumber = paneNumber
        _browser = StateObject(wrappedValue: PaneBrowserModel(paneID: paneID))
    }

    var body: some View {
        if let pane = workspace.pane(id: paneID) {
            VStack(spacing: 0) {
                header(pane)
                tabBar(pane)
                Divider()
                content(pane)
                    .contextMenu {
                        fileContextMenu(
                            urls: pane.selectedURLs.sorted { $0.path < $1.path },
                            pane: pane
                        )
                    }
                Divider()
                statusBar(pane)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(workspace.state.activePaneID == paneID ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.12))
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [7]))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                PaneInputRouter(
                    isActivePane: { workspace.state.activePaneID == paneID },
                    activate: { workspace.activate(paneID) },
                    toggleQuickLook: { toggleQuickLook() },
                    selectAllVisible: {
                        workspace.setSelection(Set(browser.items.map(\.url)), in: paneID)
                    }
                )
                .allowsHitTesting(false)
            }
            .onAppear { load(pane) }
            .onDisappear { browser.cancel() }
            .onChange(of: pane.currentURL) { _, _ in loadCurrent() }
            .onChange(of: pane.activeTabID) { _, _ in loadCurrent() }
            .onChange(of: pane.showsHiddenFiles) { _, _ in loadCurrent() }
            .onReceive(NotificationCenter.default.publisher(for: .quadFinderDirectoryDidChange)) { note in
                guard let changed = note.object as? URL else { return }
                Task { await FolderSizeCalculator.invalidate(url: changed) }
                guard changed.standardizedFileURL == pane.currentURL.standardizedFileURL else { return }
                browser.load(url: pane.currentURL, showsHiddenFiles: pane.showsHiddenFiles, bookmark: pane.accessBookmark, bypassCache: true)
            }
            .dropDestination(for: URL.self) { urls, _ in
                workspace.prepareDrop(sourcePaneID: nil, targetPaneID: paneID, urls: urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .dropDestination(for: PaneFileDragPayload.self) { payloads, _ in
                guard let sourcePaneID = payloads.first?.sourcePaneID,
                      payloads.allSatisfy({ $0.sourcePaneID == sourcePaneID }) else { return false }
                workspace.prepareDrop(
                    sourcePaneID: sourcePaneID,
                    targetPaneID: paneID,
                    urls: payloads.map(\.url)
                )
                return true
            } isTargeted: { isDropTargeted = $0 }
            .dropDestination(for: PaneFileDragBatchPayload.self) { batches, _ in
                let payloads = batches.flatMap(\.payloads)
                guard let sourcePaneID = payloads.first?.sourcePaneID,
                      !payloads.isEmpty,
                      payloads.allSatisfy({ $0.sourcePaneID == sourcePaneID }) else { return false }
                workspace.prepareDrop(sourcePaneID: sourcePaneID, targetPaneID: paneID, urls: payloads.map(\.url))
                return true
            } isTargeted: { isDropTargeted = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("ペイン\(paneNumber)、\(pane.currentURL.lastPathComponent)、\(workspace.state.activePaneID == paneID ? "アクティブ" : "非アクティブ")")
            .sheet(item: $getInfoModel) { GetInfoSheet(model: $0) }
        }
    }

    private func tabBar(_ pane: PaneState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(pane.tabs) { tab in
                    HStack(spacing: 4) {
                        Button {
                            workspace.selectTab(tab.id, in: paneID)
                        } label: {
                            Label(tab.currentURL.lastPathComponent.isEmpty ? "/" : tab.currentURL.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            if workspace.state.panes.count > 1 {
                                Menu("別ペインへ移動") {
                                    ForEach(workspace.destinationCandidates(excluding: paneID)) { destination in
                                        Button("ペイン\(destination.paneNumber): \(destination.folderName)") {
                                            workspace.transferTab(tab.id, from: paneID, to: destination.paneID, copy: false)
                                        }
                                        .disabled(pane.tabs.count == 1)
                                    }
                                }
                                Menu("別ペインへ複製") {
                                    ForEach(workspace.destinationCandidates(excluding: paneID)) { destination in
                                        Button("ペイン\(destination.paneNumber): \(destination.folderName)") {
                                            workspace.transferTab(tab.id, from: paneID, to: destination.paneID, copy: true)
                                        }
                                    }
                                }
                                Divider()
                            }
                            Button("タブを閉じる") { workspace.closeTab(tab.id, in: paneID) }
                                .disabled(pane.tabs.count == 1)
                        } label: {
                            // A borderless macOS Menu supplies its own disclosure
                            // indicator.  Drawing another chevron here produces two
                            // adjacent triangles.
                            EmptyView()
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(TabMenuPresentation.accessibilityLabel)
                        .help(TabMenuPresentation.accessibilityLabel)
                        Button { workspace.closeTab(tab.id, in: paneID) } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .disabled(pane.tabs.count == 1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(tab.id == pane.activeTabID ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("タブ、\(tab.currentURL.lastPathComponent)、\(tab.id == pane.activeTabID ? "選択中" : "非選択")")
                }
                Button { workspace.addTab(to: paneID) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("新規タブ")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 31)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
    }

    @ViewBuilder
    private func header(_ pane: PaneState) -> some View {
        HStack(spacing: 6) {
            Text("\(paneNumber)")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(workspace.state.activePaneID == paneID ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                .foregroundStyle(workspace.state.activePaneID == paneID ? .white : .primary)
            Button { workspace.goBack(paneID: paneID) } label: { Image(systemName: "chevron.left") }
                .disabled(pane.backwardHistory.isEmpty)
                .help("戻る")
            Button { workspace.goForward(paneID: paneID) } label: { Image(systemName: "chevron.right") }
                .disabled(pane.forwardHistory.isEmpty)
                .help("進む")
            Button { workspace.goUp(paneID: paneID) } label: { Image(systemName: "arrow.up") }
                .disabled(pane.currentURL.path == "/")
                .help("上位フォルダ")
            PathBreadcrumbView(url: pane.currentURL) { destination in
                workspace.navigate(paneID: paneID, to: destination)
            }
            if let notice = workspace.paneNotifications[paneID] {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                    .help(notice)
                    .accessibilityLabel(notice)
            }
            Spacer(minLength: 2)
            if browser.isLoading { ProgressView().controlSize(.small) }
            Button { chooseFolder() } label: { Image(systemName: "folder.badge.gearshape") }
                .help("フォルダを選択…")
            Menu {
                Button { setViewStyle(.list) } label: { Label("リスト", systemImage: "list.bullet") }
                Button { setViewStyle(.icons) } label: { Label("アイコン", systemImage: "square.grid.2x2") }
                Button { setViewStyle(.columns) } label: { Label("カラム", systemImage: "rectangle.split.3x1") }
                Button { setViewStyle(.tree) } label: { Label("ツリー", systemImage: "list.bullet.indent") }
            } label: {
                Image(systemName: viewStyleIcon(pane.viewStyle))
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("表示形式")
            Menu {
                Button("リストを再読み込み") { load(pane, bypassCache: true) }
                Toggle("隠しファイルを表示", isOn: Binding(
                    get: { pane.showsHiddenFiles },
                    set: { value in workspace.updatePane(id: paneID) { $0.showsHiddenFiles = value } }
                ))
                Divider()
                Button("一時最大化") { workspace.activate(paneID); workspace.toggleMaximize() }
                Button("このペインを閉じる") { workspace.closePane(paneID) }
                    .disabled(!workspace.canClosePane)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(workspace.state.activePaneID == paneID ? Color.accentColor.opacity(0.10) : Color.clear)
        .draggable(paneID.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first, let source = UUID(uuidString: raw) else { return false }
            workspace.activate(source)
            workspace.swapActive(with: paneID)
            return true
        }
    }

    @ViewBuilder
    private func content(_ pane: PaneState) -> some View {
        if let error = browser.loadError {
            ContentUnavailableView {
                Label(error.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("再試行") { load(pane) }
                Button("別の場所を選ぶ…") { chooseFolder() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.items.isEmpty && !browser.isLoading {
            ContentUnavailableView("空のフォルダ", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pane.viewStyle == .list {
                NativeFileTableView(
                    paneID: paneID,
                    items: pane.sortDescriptor.sorted(browser.items),
                    selection: selectionBinding(pane),
                    activate: { workspace.activate(paneID) },
                    open: open,
                    receiveDrop: { urls, sourcePaneID in
                        workspace.prepareDrop(sourcePaneID: sourcePaneID, targetPaneID: paneID, urls: urls)
                    },
                    trashDropped: { urls in
                        workspace.prepareTrash(urls, origin: .dragAndDrop, accessBookmark: pane.accessBookmark)
                    },
                    showsHeader: true,
                    sortDescriptor: pane.sortDescriptor,
                    selectSort: { field in workspace.updatePane(id: paneID) { $0.sortDescriptor.select(field) } },
                    contextMenu: nativeContextMenu(for: pane)
                )
        } else if pane.viewStyle == .icons {
            NativeFileCollectionView(
                paneID: paneID,
                items: pane.sortDescriptor.sorted(browser.items),
                selection: selectionBinding(pane),
                activate: { workspace.activate(paneID) },
                open: open,
                receiveDrop: { urls, sourcePaneID in
                    workspace.prepareDrop(sourcePaneID: sourcePaneID, targetPaneID: paneID, urls: urls)
                },
                trashDropped: { urls in
                    workspace.prepareTrash(urls, origin: .dragAndDrop, accessBookmark: pane.accessBookmark)
                },
                isClipboardMarked: { clipboard.isMarked($0) },
                contextMenu: nativeContextMenu(for: pane)
            )
        } else if pane.viewStyle == .columns {
            ColumnFileView(
                paneID: paneID,
                rootURL: pane.currentURL,
                items: browser.items,
                selection: selectionBinding(pane),
                bookmark: pane.accessBookmark,
                open: open,
                activate: { workspace.activate(paneID) },
                clipboardMarked: { clipboard.isMarked($0) },
                clipboardIsCut: clipboard.markedAsCut,
                receiveDrop: { urls, sourcePaneID in
                    workspace.prepareDrop(sourcePaneID: sourcePaneID, targetPaneID: paneID, urls: urls)
                },
                trashDropped: { urls in
                    workspace.prepareTrash(urls, origin: .dragAndDrop, accessBookmark: pane.accessBookmark)
                },
                contextMenu: nativeContextMenu(for: pane)
            )
        } else {
                TreeFileView(
                    paneID: paneID, rootItems: browser.items, showsHiddenFiles: pane.showsHiddenFiles,
                    sortDescriptor: pane.sortDescriptor,
                    selection: selectionBinding(pane), bookmark: pane.accessBookmark, open: open,
                    activate: { workspace.activate(paneID) },
                    clipboardMarked: { clipboard.isMarked($0) }, clipboardIsCut: clipboard.markedAsCut,
                    receiveDrop: { urls, sourcePaneID in
                        workspace.prepareDrop(sourcePaneID: sourcePaneID, targetPaneID: paneID, urls: urls)
                    },
                    trashDropped: { urls in
                        workspace.prepareTrash(urls, origin: .dragAndDrop, accessBookmark: pane.accessBookmark)
                    },
                    selectSort: { field in workspace.updatePane(id: paneID) { $0.sortDescriptor.select(field) } },
                    contextMenu: nativeContextMenu(for: pane)
                )
        }
    }


    private func compactRow(_ item: FileItem) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 14, height: 14)
                Text(item.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                .foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
            Group {
                if let date = item.modificationDate {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                } else { Text("—") }
            }
            .foregroundStyle(.secondary).frame(width: 125, alignment: .leading)
            Text(NativeFileMetadataText.cloud(item))
                .foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity)
    }

    private func contextTargets(for clicked: URL, pane: PaneState) -> [URL] {
        Array(PaneSelectionPolicy.contextTargets(clicked: clicked, selection: pane.selectedURLs))
            .sorted { $0.path < $1.path }
    }

    private func nativeContextMenu(for pane: PaneState) -> NativeFinderContextMenuConfiguration {
        NativeFinderContextMenuConfiguration(
            model: { clicked, selection in
                let urls = Array(PaneSelectionPolicy.contextTargets(clicked: clicked, selection: selection))
                return FinderContextActionModel(context: FinderContext(
                    selectedURLs: urls, clickedURL: clicked, currentDirectory: pane.currentURL,
                    otherPaneCount: workspace.state.panes.count - 1,
                    clipboardContainsFiles: !FinderClipboard.shared.read().urls.isEmpty
                ))
            },
            perform: { action, clicked, selection in
                let urls = Array(PaneSelectionPolicy.contextTargets(clicked: clicked, selection: selection)).sorted { $0.path < $1.path }
                performContextAction(action, urls: urls, pane: pane)
            },
            openWith: { applicationURL, clicked, selection in
                let urls = Array(PaneSelectionPolicy.contextTargets(clicked: clicked, selection: selection))
                open(urls: urls, with: applicationURL)
            }
        )
    }

    private func open(urls: [URL], with applicationURL: URL?) {
        guard !urls.isEmpty else { return }
        let launch: (URL) -> Void = { appURL in
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
        }
        if let applicationURL { launch(applicationURL); return }
        let panel = NSOpenPanel()
        panel.title = "アプリケーションを選択"
        panel.prompt = "選択"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let appURL = panel.url { launch(appURL) }
    }

    private func statusBar(_ pane: PaneState) -> some View {
        let selected = browser.items.filter { pane.selectedURLs.contains($0.url) }
        let bytes = selected.compactMap(\.size).reduce(0, +)
        return HStack(spacing: 8) {
            Text("\(browser.items.count)項目")
            if !selected.isEmpty {
                Text("\(selected.count)項目を選択")
                if bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }
            Spacer()
            Text(pane.currentURL.path(percentEncoded: false))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(paneID) }
    }

    @ViewBuilder
    private func fileContextMenu(urls: [URL], pane: PaneState) -> some View {
        let context = FinderContext(
            selectedURLs: urls, clickedURL: urls.first, currentDirectory: pane.currentURL,
            otherPaneCount: workspace.state.panes.count - 1,
            clipboardContainsFiles: !FinderClipboard.shared.read().urls.isEmpty
        )
        FinderContextMenuView(
            model: FinderContextActionModel(context: context),
            destinations: workspace.destinationCandidates(excluding: paneID),
            perform: { action in performContextAction(action, urls: urls, pane: pane) },
            openInPane: { destinationID in
                guard let url = urls.first else { return }
                workspace.navigate(paneID: destinationID, to: url, bookmark: pane.accessBookmark)
            },
            onPresented: {
                workspace.activate(paneID)
                workspace.setSelection(Set(urls), in: paneID)
            }
        )
    }

    private func performContextAction(_ action: FinderContextAction, urls: [URL], pane: PaneState) {
        workspace.activate(paneID)
        workspace.setSelection(Set(urls), in: paneID)
        switch action {
        case .open:
            urls.forEach(openURL)
        case .quickLook: QuickLookPresenter.shared.preview(urls)
        case .openInNewTab:
            guard let url = urls.first else { return }
            workspace.addTab(to: paneID)
            workspace.navigate(paneID: paneID, to: url)
        case .openInOtherPane: break
        case .cut: FinderClipboard.shared.write(urls: urls, cut: true)
        case .copy: FinderClipboard.shared.write(urls: urls, cut: false)
        case .paste: workspace.preparePasteFromClipboard()
        case .duplicate: duplicate(urls, in: pane)
        case .rename:
            if let url = urls.first { rename(url, in: pane) }
        case .newFolder: createFolder(in: pane)
        case .trash: workspace.prepareTrash(urls: urls, paneID: paneID)
        case .getInfo:
            let model = GetInfoModel()
            model.load(urls: urls, bookmark: pane.accessBookmark)
            getInfoModel = model
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .showPackageContents:
            if let url = urls.first { workspace.navigate(paneID: paneID, to: url) }
        }
    }

    private func createFolder(in pane: PaneState) {
        let field = NSTextField(string: "名称未設定フォルダ")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let alert = NSAlert()
        alert.messageText = "新規フォルダ"
        alert.accessoryView = field
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let scope = try beginSecurityScope(
                bookmark: pane.accessBookmark, requestedURLs: [pane.currentURL]
            )
            defer { scope?.stopAccessingSecurityScopedResource() }
            let destination = pane.currentURL.appendingPathComponent(field.stringValue, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FinderActionError.destinationConflict(destination)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            workspace.operationHistory.record(.init(kind: .newFolder, summary: "フォルダを作成", steps: [.createdDirectory(destination)], itemCount: 1,
                                                    sourceBookmark: pane.accessBookmark, targetBookmark: pane.accessBookmark))
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: pane.currentURL)
        } catch { workspace.report("フォルダを作成できません", error: error) }
    }

    private func duplicate(_ urls: [URL], in pane: PaneState) {
        var created: [HistoryStep] = []
        do {
            let scope = try beginSecurityScope(bookmark: pane.accessBookmark, requestedURLs: urls)
            defer { scope?.stopAccessingSecurityScopedResource() }
            for url in urls {
                let target = try FinderActionService().duplicate(url)
                if let sourceFP = HistoryFingerprint.capture(url), let targetFP = HistoryFingerprint.capture(target) {
                    created.append(.duplicated(source: url, target: target, sourceFingerprint: sourceFP, targetFingerprint: targetFP))
                }
            }
            workspace.operationHistory.record(.init(kind: .duplicate, summary: "\(created.count)項目を複製", steps: created, itemCount: created.count,
                                                    sourceBookmark: pane.accessBookmark, targetBookmark: pane.accessBookmark))
            for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
                NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: directory)
            }
        } catch {
            if !created.isEmpty {
                workspace.operationHistory.record(.init(kind: .duplicate, summary: "\(created.count)項目を複製（一部完了）",
                    steps: created, itemCount: created.count, sourceBookmark: pane.accessBookmark, targetBookmark: pane.accessBookmark))
            }
            workspace.report("複製できません", error: error)
        }
    }

    private func rename(_ url: URL, in pane: PaneState) {
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let alert = NSAlert()
        alert.messageText = "名前を変更"
        alert.informativeText = "新しい名前を入力してください。"
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let scope = try beginSecurityScope(bookmark: pane.accessBookmark, requestedURLs: [url])
            defer { scope?.stopAccessingSecurityScopedResource() }
            let destination = try FinderActionService().rename(url, to: field.stringValue)
            workspace.operationHistory.record(.init(kind: .rename, summary: "名前を変更", steps: [.moved(from: url, to: destination)], itemCount: 1,
                                                    sourceBookmark: pane.accessBookmark, targetBookmark: pane.accessBookmark))
            workspace.setSelection([], in: paneID)
            NotificationCenter.default.post(name: .quadFinderDirectoryDidChange, object: url.deletingLastPathComponent())
        } catch { workspace.report("名前を変更できません", error: error) }
    }

    private func beginSecurityScope(bookmark: Data?, requestedURLs: [URL]) throws -> URL? {
        guard AppSecurityEnvironment.current.isSandboxed else { return nil }
        guard let bookmark else { return nil }
        guard let url = try? FileSystemService.resolveBookmark(bookmark),
              requestedURLs.allSatisfy({ SecurityScopeAccess().contains(scopeURL: url, requestedURL: $0) }) else { return nil }
        if url.startAccessingSecurityScopedResource() { return url }
        return nil
    }

    private func selectionBinding(_ pane: PaneState) -> Binding<Set<URL>> {
        Binding(
            get: { pane.selectedURLs },
            set: { selected in
                workspace.activate(paneID)
                workspace.setSelection(selected, in: paneID)
            }
        )
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            workspace.navigate(paneID: paneID, to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
            var info: [String: Any] = ["kind": SidebarRecentItem.Kind.file.rawValue]
            if let bookmark = workspace.pane(id: paneID)?.accessBookmark { info["bookmark"] = bookmark }
            NotificationCenter.default.post(name: .quadFinderRecentAccess, object: item.url, userInfo: info)
        }
    }

    private func toggleQuickLook() {
        if QuickLookPresenter.shared.isVisible { QuickLookPresenter.shared.close() }
        else { workspace.quickLookSelection() }
    }

    private func setViewStyle(_ style: FileViewStyle) {
        workspace.updatePane(id: paneID) { $0.viewStyle = style }
    }

    private func viewStyleIcon(_ style: FileViewStyle) -> String {
        switch style {
        case .list: "list.bullet"
        case .icons: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .tree: "list.bullet.indent"
        }
    }

    private func openURL(_ url: URL) {
        if let item = browser.items.first(where: { $0.url == url }) {
            open(item)
            return
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory { workspace.navigate(paneID: paneID, to: url) }
        else {
            NSWorkspace.shared.open(url)
            var info: [String: Any] = ["kind": SidebarRecentItem.Kind.file.rawValue]
            if let bookmark = workspace.pane(id: paneID)?.accessBookmark { info["bookmark"] = bookmark }
            NotificationCenter.default.post(name: .quadFinderRecentAccess, object: url, userInfo: info)
        }
    }

    private func load(_ pane: PaneState, bypassCache: Bool = false) {
        browser.load(
            url: pane.currentURL,
            showsHiddenFiles: pane.showsHiddenFiles,
            bookmark: pane.accessBookmark,
            bypassCache: bypassCache
        )
    }

    private func loadCurrent() {
        guard let pane = workspace.pane(id: paneID) else { return }
        load(pane)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.pane(id: paneID)?.currentURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel-returned URL is the authority for this interaction.
            // Navigate/retry immediately even if persistence happens to fail;
            // bookmark persistence is for subsequent launches only.
            let bookmark = try? FileSystemService.bookmark(for: url)
            workspace.navigate(paneID: paneID, to: url, bookmark: bookmark)
            browser.load(url: url, showsHiddenFiles: workspace.pane(id: paneID)?.showsHiddenFiles ?? false,
                         bookmark: bookmark, bypassCache: true)
        }
    }
}
