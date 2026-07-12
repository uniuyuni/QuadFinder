import SwiftUI

struct TransferTargetSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let transfer: WorkspaceStore.PendingTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("他ペインへ\(transfer.kind.rawValue)").font(.title2.bold())
            Text("\(transfer.sourceURLs.count)項目の宛先を選択してください。")
            List(transfer.destinations) { destination in
                Button {
                    workspace.confirmExplicitTransfer(to: destination.paneID)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ペイン\(destination.paneNumber) — \(destination.folderName)").bold()
                        Text(destination.directoryURL.path(percentEncoded: false))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            HStack { Spacer(); Button("キャンセル") { workspace.pendingTransfer = nil; dismiss() } }
        }
        .padding(20)
        .frame(width: 560, height: 330)
    }
}

struct PaneSetSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ペインセット").font(.title2.bold())
            HStack {
                TextField("新しいセット名", text: $name)
                Button("現在の構成を保存") {
                    workspace.savePaneSet(named: name)
                    name = ""
                }
            }
            if workspace.paneSets.sets.isEmpty {
                ContentUnavailableView("保存済みセットなし", systemImage: "square.grid.2x2")
            } else {
                List(workspace.paneSets.sets) { paneSet in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(paneSet.name).bold()
                            Text("\(paneSet.workspace.panes.count)ペイン・\(paneSet.workspace.layout.title)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("適用") { workspace.applyPaneSet(paneSet.id); dismiss() }
                        Button("削除", role: .destructive) { workspace.deletePaneSet(paneSet.id) }
                    }
                }
            }
            if !workspace.paneSets.loadErrors.isEmpty {
                VStack(alignment: .leading) {
                    Text("読み込めないセット: \(workspace.paneSets.loadErrors.count)件").bold()
                    ForEach(workspace.paneSets.loadErrors, id: \.self) { Text($0).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.red)
            }
            HStack { Spacer(); Button("閉じる") { dismiss() } }
        }
        .padding(20)
        .frame(width: 600, height: 420)
    }
}
