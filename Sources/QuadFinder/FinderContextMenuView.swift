import SwiftUI

struct FinderContextMenuView: View {
    let model: FinderContextActionModel
    let destinations: [WorkspaceStore.DestinationCandidate]
    let perform: (FinderContextAction) -> Void
    let openInPane: (UUID) -> Void
    var onPresented: () -> Void = {}

    var body: some View {
        Button(L10n.tr("開く")) { perform(.open) }
            .disabled(!model.isEnabled(.open))
            .onAppear(perform: onPresented)
        Button(L10n.tr("クイックルック")) { perform(.quickLook) }.disabled(!model.isEnabled(.quickLook))
        Button(L10n.tr("新規タブで開く")) { perform(.openInNewTab) }.disabled(!model.isEnabled(.openInNewTab))
        Menu(L10n.tr("別のペインで開く")) {
            ForEach(destinations) { destination in
                Button(L10n.format("ペイン%1$lld: %2$@", Int64(destination.paneNumber), destination.folderName)) {
                    openInPane(destination.paneID)
                }
            }
        }
        .disabled(!model.isEnabled(.openInOtherPane))
        Divider()
        Button(L10n.tr("カット")) { perform(.cut) }.disabled(!model.isEnabled(.cut))
        Button(L10n.tr("コピー")) { perform(.copy) }.disabled(!model.isEnabled(.copy))
        Button(L10n.tr("貼り付け")) { perform(.paste) }.disabled(!model.isEnabled(.paste))
        Button(L10n.tr("複製")) { perform(.duplicate) }.disabled(!model.isEnabled(.duplicate))
        Button(L10n.tr("名前を変更…")) { perform(.rename) }.disabled(!model.isEnabled(.rename))
        Button(L10n.tr("新規フォルダ…")) { perform(.newFolder) }.disabled(!model.isEnabled(.newFolder))
        Divider()
        Button(L10n.tr("情報を見る")) { perform(.getInfo) }.disabled(!model.isEnabled(.getInfo))
        Button(L10n.tr("パスをコピー")) { perform(.copyPath) }.disabled(!model.isEnabled(.copyPath))
        Button(L10n.tr("Finderに表示")) { perform(.revealInFinder) }.disabled(!model.isEnabled(.revealInFinder))
        if model.isEnabled(.showPackageContents) {
            Button(L10n.tr("パッケージの内容を表示")) { perform(.showPackageContents) }
        }
        Divider()
        Button(L10n.tr("ゴミ箱に入れる"), role: .destructive) { perform(.trash) }
            .disabled(!model.isEnabled(.trash))
    }
}
