import SwiftUI

struct FinderContextMenuView: View {
    let model: FinderContextActionModel
    let destinations: [WorkspaceStore.DestinationCandidate]
    let perform: (FinderContextAction) -> Void
    let openInPane: (UUID) -> Void
    var onPresented: () -> Void = {}

    var body: some View {
        Button("開く") { perform(.open) }
            .disabled(!model.isEnabled(.open))
            .onAppear(perform: onPresented)
        Button("クイックルック") { perform(.quickLook) }.disabled(!model.isEnabled(.quickLook))
        Button("新規タブで開く") { perform(.openInNewTab) }.disabled(!model.isEnabled(.openInNewTab))
        Menu("別のペインで開く") {
            ForEach(destinations) { destination in
                Button("ペイン\(destination.paneNumber): \(destination.folderName)") {
                    openInPane(destination.paneID)
                }
            }
        }
        .disabled(!model.isEnabled(.openInOtherPane))
        Divider()
        Button("カット") { perform(.cut) }.disabled(!model.isEnabled(.cut))
        Button("コピー") { perform(.copy) }.disabled(!model.isEnabled(.copy))
        Button("貼り付け") { perform(.paste) }.disabled(!model.isEnabled(.paste))
        Button("複製") { perform(.duplicate) }.disabled(!model.isEnabled(.duplicate))
        Button("名前を変更…") { perform(.rename) }.disabled(!model.isEnabled(.rename))
        Button("新規フォルダ…") { perform(.newFolder) }.disabled(!model.isEnabled(.newFolder))
        Divider()
        Button("情報を見る") { perform(.getInfo) }.disabled(!model.isEnabled(.getInfo))
        Button("パスをコピー") { perform(.copyPath) }.disabled(!model.isEnabled(.copyPath))
        Button("Finderに表示") { perform(.revealInFinder) }.disabled(!model.isEnabled(.revealInFinder))
        if model.isEnabled(.showPackageContents) {
            Button("パッケージの内容を表示") { perform(.showPackageContents) }
        }
        Divider()
        Button("ゴミ箱に入れる", role: .destructive) { perform(.trash) }
            .disabled(!model.isEnabled(.trash))
    }
}
