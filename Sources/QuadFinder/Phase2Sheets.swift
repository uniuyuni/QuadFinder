import SwiftUI

struct TransferTargetSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let transfer: WorkspaceStore.PendingTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("他ペインへ%@", transfer.kind.localizedTitle)).font(.title2.bold())
            Text(L10n.format("%lld項目の宛先を選択してください。", Int64(transfer.sourceURLs.count)))
            List(transfer.destinations) { destination in
                Button {
                    workspace.confirmExplicitTransfer(to: destination.paneID)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.format("ペイン%1$lld — %2$@", Int64(destination.paneNumber), destination.folderName)).bold()
                        Text(destination.directoryURL.path(percentEncoded: false))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            HStack { Spacer(); Button(L10n.tr("キャンセル")) { workspace.pendingTransfer = nil; dismiss() } }
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
            Text(L10n.tr("ペインセット")).font(.title2.bold())
            HStack {
                TextField(L10n.tr("新しいセット名"), text: $name)
                Button(L10n.tr("現在の構成を保存")) {
                    workspace.savePaneSet(named: name)
                    name = ""
                }
            }
            if workspace.paneSets.sets.isEmpty {
                ContentUnavailableView(L10n.tr("保存済みセットなし"), systemImage: "square.grid.2x2")
            } else {
                List(workspace.paneSets.sets) { paneSet in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(paneSet.name).bold()
                            Text(L10n.format("%1$lldペイン・%2$@", Int64(paneSet.workspace.panes.count), paneSet.workspace.layout.title))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("適用")) { workspace.applyPaneSet(paneSet.id); dismiss() }
                        Button(L10n.tr("削除"), role: .destructive) { workspace.deletePaneSet(paneSet.id) }
                    }
                }
            }
            if !workspace.paneSets.loadErrors.isEmpty {
                VStack(alignment: .leading) {
                    Text(L10n.format("読み込めないセット: %lld件", Int64(workspace.paneSets.loadErrors.count))).bold()
                    ForEach(workspace.paneSets.loadErrors, id: \.self) { Text($0).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.red)
            }
            HStack { Spacer(); Button(L10n.tr("閉じる")) { dismiss() } }
        }
        .padding(20)
        .frame(width: 600, height: 420)
    }
}
