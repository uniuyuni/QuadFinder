import SwiftUI

struct PaneLinkSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var followsNavigation: Bool
    @State private var followsSelection: Bool

    init(group: PaneLinkGroup?) {
        _selected = State(initialValue: group?.paneIDs ?? [])
        _followsNavigation = State(initialValue: group?.followsRelativeNavigation ?? true)
        _followsSelection = State(initialValue: group?.followsSelection ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ペインリンク").font(.title2.bold())
            Text("リンクする2〜4ペインを選択します。リンクはファイルを変更しません。")
            ForEach(Array(workspace.state.orderedPaneIDs.enumerated()), id: \.element) { index, id in
                Toggle(isOn: Binding(
                    get: { selected.contains(id) },
                    set: { value in if value { selected.insert(id) } else { selected.remove(id) } }
                )) {
                    let pane = workspace.pane(id: id)
                    VStack(alignment: .leading) {
                        Text("ペイン\(index + 1): \(pane?.currentURL.lastPathComponent ?? "")")
                        Text(pane?.currentURL.path(percentEncoded: false) ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Toggle("同名の子フォルダへ相対ナビゲーション", isOn: $followsNavigation)
            Toggle("同名項目の選択を追従", isOn: $followsSelection)
            HStack {
                Button("リンク解除", role: .destructive) { workspace.clearPaneLinkGroup(); dismiss() }
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("適用") {
                    workspace.setPaneLinkGroup(selected, followsNavigation: followsNavigation, followsSelection: followsSelection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.count < 2)
            }
        }
        .padding(20)
        .frame(width: 570, height: 430)
    }
}

struct ComparisonModuleView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var controller: ComparisonController
    @State private var usesChecksums = false
    @State private var syncMode = SyncMode.missingOnly
    @State private var allowsOverwrite = false
    @State private var allowsDelete = false
    @State private var showsPreview = false

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label("フォルダ比較", systemImage: "arrow.left.arrow.right.square")
                    .font(.headline)
                if let pair = workspace.comparisonPair {
                    Text(pairLabel(pair)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Checksum", isOn: $usesChecksums).toggleStyle(.checkbox)
                Button(controller.isRunning ? "キャンセル" : "比較") {
                    controller.isRunning ? controller.cancel() : workspace.startComparison(usesChecksums: usesChecksums)
                }
                Button {
                    workspace.updateModuleSettings { $0.comparison.isVisible = false }
                } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if controller.isRunning {
                ProgressView(value: controller.progress) { Text("比較中…") }
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            if let result = controller.result {
                HStack {
                    Picker("同期モード", selection: $syncMode) {
                        ForEach(SyncMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 210)
                    Toggle("上書きを許可", isOn: $allowsOverwrite).toggleStyle(.checkbox)
                    Toggle("削除を許可", isOn: $allowsDelete).toggleStyle(.checkbox)
                    Button("同期プレビュー") {
                        do {
                            _ = try controller.makePreview(mode: syncMode, allowsOverwrite: allowsOverwrite, allowsDelete: allowsDelete)
                            showsPreview = true
                        } catch {
                            workspace.report("同期プレビューを作成できません", error: error)
                        }
                    }
                    Spacer()
                    summary(result)
                }
                Table(result.entries) {
                    TableColumn("名前", value: \.name)
                    TableColumn("分類") { Text($0.classification.rawValue).foregroundStyle(color($0.classification)) }
                    TableColumn("種類") { Text(($0.source ?? $0.target)?.isDirectory == true ? "フォルダ" : "ファイル") }
                    TableColumn("サイズ") { entry in
                        Text(ByteCountFormatter.string(fromByteCount: entry.source?.size ?? entry.target?.size ?? 0, countStyle: .file))
                    }
                    TableColumn("状態") { Text($0.message ?? "") }
                }
                .frame(minHeight: 130, maxHeight: 230)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .sheet(isPresented: $showsPreview) {
            if let preview = controller.preview {
                SyncPreviewSheet(plan: preview, controller: controller).environmentObject(workspace)
            }
        }
    }

    private func pairLabel(_ pair: (UUID, UUID)) -> String {
        let ids = workspace.state.orderedPaneIDs
        return "ペイン\((ids.firstIndex(of: pair.0) ?? 0) + 1) → ペイン\((ids.firstIndex(of: pair.1) ?? 0) + 1)"
    }

    private func summary(_ result: FolderComparisonResult) -> some View {
        let changed = result.entries.count { $0.classification != .equal }
        return Text("\(result.entries.count)項目・差異\(changed)件").font(.caption).foregroundStyle(.secondary)
    }

    private func color(_ classification: ComparisonClassification) -> Color {
        switch classification {
        case .equal: .green
        case .error: .red
        case .onlySource, .onlyTarget: .blue
        case .different: .orange
        }
    }
}

struct SyncPreviewSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let plan: SyncExecutionPlan
    @ObservedObject var controller: ComparisonController
    @State private var reviewed = false

    private var blocked: Bool {
        (plan.overwriteCount > 0 && !plan.allowsOverwrite) || (plan.deleteCount > 0 && !plan.allowsDelete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("同期プレビュー — \(plan.mode.rawValue)").font(.title2.bold())
            Text("作成 \(plan.createCount)・上書き \(plan.overwriteCount)・削除 \(plan.deleteCount)")
            if blocked {
                Text("上書きまたは削除が許可されていません。前の画面で明示的に有効化してプレビューを作り直してください。")
                    .foregroundStyle(.red)
            }
            List(plan.actions) { action in
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.kind.rawValue).bold()
                    if let source = action.sourceURL { Text("元: \(source.path(percentEncoded: false))").font(.caption) }
                    Text("先: \(action.targetURL.path(percentEncoded: false))").font(.caption)
                }
            }
            Toggle("すべての完全パスと操作内容を確認しました", isOn: $reviewed)
            HStack {
                Text("削除と上書きはゴミ箱経由です。完全削除は行いません。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("戻る") { dismiss() }
                Button("キューへ投入") {
                    do {
                        workspace.enqueueSync(try controller.confirmedPlan())
                        dismiss()
                    } catch {
                        workspace.report("同期を開始できません", error: error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!reviewed || blocked || plan.actions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 540)
    }
}
