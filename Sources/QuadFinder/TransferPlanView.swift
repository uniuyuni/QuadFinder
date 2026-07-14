import SwiftUI

@MainActor
final class TransferPlanController: ObservableObject, Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case queued
        case executing
        case completed
        case cancelled
        case failed(String)
    }

    let id = UUID()
    let request: TransferPlanRequest
    @Published var policy: TransferConflictPolicy = .newerOnly
    @Published var plan: TransferExecutionPlan?
    @Published private(set) var state: State = .loading
    private let planner = TransferPlanningService()
    private let queue: FileOperationQueue
    private let sourcePaneID: UUID?
    private let targetPaneID: UUID
    private let clipboardCutReceipt: ClipboardCutReceipt?
    private var task: Task<Void, Never>?
    private var submittedJobID: UUID?

    init(
        request: TransferPlanRequest,
        queue: FileOperationQueue,
        sourcePaneID: UUID?,
        targetPaneID: UUID,
        clipboardCutReceipt: ClipboardCutReceipt?
    ) {
        self.request = request
        self.queue = queue
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
        self.clipboardCutReceipt = clipboardCutReceipt
        rebuild()
    }

    deinit { task?.cancel() }

    func rebuild() {
        task?.cancel()
        submittedJobID = nil
        state = .loading
        let request = request
        let policy = policy
        let planner = planner
        task = Task { [weak self] in
            do {
                let plan = try await planner.makePlan(request, policy: policy)
                guard !Task.isCancelled, let self, self.policy == policy else { return }
                self.plan = plan
                self.state = .ready
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func setSelected(_ selected: Bool, actionID: UUID) {
        guard let index = plan?.actions.firstIndex(where: { $0.id == actionID }) else { return }
        plan?.actions[index].isSelected = selected
    }

    func executeConfirmed() {
        guard var plan else { return }
        plan.confirmationStage = 2
        let confirmedPlan = plan
        let operation = PendingFileOperation(
            kind: confirmedPlan.kind,
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            sourceURLs: confirmedPlan.sourceURLs,
            targetDirectoryURL: confirmedPlan.targetDirectoryURL,
            sourceAccessBookmark: confirmedPlan.sourceAccessBookmark,
            targetAccessBookmark: confirmedPlan.targetAccessBookmark,
            transferPlan: confirmedPlan,
            clipboardCutReceipt: confirmedPlan.kind == .move ? clipboardCutReceipt : nil
        )
        let jobID = queue.enqueue(operation)
        submittedJobID = jobID
        state = .queued
        task = Task { [weak self] in
            while let self, let job = self.queue.job(id: jobID) {
                switch job.status {
                case .queued: self.state = .queued
                case .running: self.state = .executing
                case .succeeded:
                    self.state = .completed
                    return
                case .cancelled:
                    self.state = .cancelled
                    return
                case .stopped:
                    self.state = .cancelled
                    return
                case .failed:
                    self.state = .failed(job.errorMessage ?? L10n.tr("ファイル操作に失敗しました。"))
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func cancel() {
        if let submittedJobID { queue.cancel(submittedJobID) }
        else { task?.cancel() }
    }
}

struct TransferPlanSheet: View {
    @ObservedObject var controller: TransferPlanController
    @Environment(\.dismiss) private var dismiss
    @State private var showsFinalConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.format("比較%@", controller.request.kind.localizedTitle)).font(.title2.bold())
                Spacer()
                Picker(L10n.tr("処理"), selection: $controller.policy) {
                    ForEach(TransferConflictPolicy.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                }
                .frame(width: 230)
                .onChange(of: controller.policy) { _, _ in controller.rebuild() }
                .disabled(isSubmitted)
            }
            Text(policyExplanation)
                .font(.callout).foregroundStyle(.secondary)
            pathSummary
            actionSummary
            Group {
                switch controller.state {
                case .loading:
                    ProgressView(L10n.tr("比較しています…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(L10n.tr("プランを作成または実行できませんでした"), systemImage: "exclamationmark.triangle", description: Text(message))
                case .completed:
                    ContentUnavailableView(L10n.tr("完了しました"), systemImage: "checkmark.circle")
                case .cancelled:
                    ContentUnavailableView(L10n.tr("キャンセルしました"), systemImage: "xmark.circle")
                case .ready, .queued, .executing:
                    actionList
                }
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 500, idealHeight: 620)
        .interactiveDismissDisabled(isSubmitted)
        .confirmationDialog(
            L10n.tr("選択したファイル操作を実行しますか？"),
            isPresented: $showsFinalConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("実行"), role: controller.plan?.hasDestructiveActions == true ? .destructive : nil) {
                controller.executeConfirmed()
            }
            Button(L10n.tr("キャンセル"), role: .cancel) {}
        } message: {
            Text(finalConfirmationMessage)
        }
    }

    private var pathSummary: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                Text(L10n.tr("元:")).foregroundStyle(.secondary)
                Text(controller.request.sourceURLs.map(\.path).joined(separator: "\n")).lineLimit(2)
            }
            GridRow {
                Text(L10n.tr("先:")).foregroundStyle(.secondary)
                Text(controller.request.targetDirectoryURL.path).lineLimit(1)
            }
        }
        .font(.caption.monospaced())
    }

    private var actionList: some View {
        Table(controller.plan?.actions ?? []) {
            TableColumn(L10n.tr("実行")) { action in
                Toggle(L10n.tr(""), isOn: Binding(
                    get: { action.isSelected },
                    set: { controller.setSelected($0, actionID: action.id) }
                ))
                .labelsHidden()
                .disabled(!action.kind.isExecutable || isSubmitted)
            }.width(45)
            TableColumn(L10n.tr("操作")) { action in
                Label(action.kind.localizedTitle, systemImage: icon(for: action.kind))
                    .foregroundStyle(action.kind.isDestructive ? .red : (action.kind == .skip ? .secondary : .primary))
            }.width(130)
            TableColumn(L10n.tr("項目")) { action in
                Text(action.targetURL.path.replacingOccurrences(
                    of: controller.request.targetDirectoryURL.path + "/", with: ""
                )).lineLimit(1)
            }
            TableColumn(L10n.tr("コピー元")) { action in
                Text(action.sourceURL?.path ?? "—").font(.caption).lineLimit(1)
            }
        }
        .overlay {
            if isSubmitted {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView(L10n.tr(controller.state == .queued ? "キューで待機しています…" : "実行しています…"))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let plan = controller.plan {
                Text(L10n.format("実行 %1$lld件 / 全%2$lld件", Int64(plan.selectedActions.count), Int64(plan.actions.count)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.state == .failed("") || isFailed {
                Button(L10n.tr("再比較")) { controller.rebuild() }
            }
            Button(L10n.tr(isSubmitted ? "処理をキャンセル" : (controller.state == .completed ? "閉じる" : "キャンセル"))) {
                if isSubmitted { controller.cancel() }
                else { controller.cancel(); dismiss() }
            }
            if controller.state == .ready {
                Button(L10n.tr("実行…")) { showsFinalConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.plan?.selectedActions.isEmpty != false)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.state { return true }
        return false
    }

    private var isSubmitted: Bool {
        controller.state == .queued || controller.state == .executing
    }

    private var actionSummary: some View {
        HStack(spacing: 14) {
            if let plan = controller.plan {
                summaryLabel(L10n.tr("コピー"), count: plan.copyCount, color: .blue)
                summaryLabel(L10n.tr("統合"), count: plan.mergeCount, color: .teal)
                summaryLabel(L10n.tr("上書き"), count: plan.replaceCount, color: .orange)
                summaryLabel(L10n.tr("移動元削除"), count: plan.sourceDeleteCount, color: .purple)
                summaryLabel(L10n.tr("ターゲットTrash"), count: plan.deleteCount, color: .red)
                summaryLabel(L10n.tr("変更なし"), count: plan.skipCount, color: .secondary)
            }
        }
        .font(.caption.bold())
    }

    private func summaryLabel(_ title: String, count: Int, color: Color) -> some View {
        Text("\(title) \(count)")
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var policyExplanation: String {
        switch controller.policy {
        case .missingOnly:
            L10n.tr("ターゲットにない項目だけを追加します。同名フォルダは中身を再帰的に統合し、既存項目は変更しません。")
        case .newerOnly:
            L10n.tr("同名フォルダは中身を再帰的に統合し、コピー元の更新日時が新しいファイルだけを上書きします。")
        case .replace:
            L10n.tr("同名のファイルまたはフォルダ全体を置き換えます。置換前の項目はゴミ箱へ移動します。")
        case .synchronize:
            L10n.tr("同名フォルダを再帰的に統合し、ターゲットだけにある項目をゴミ箱へ移してコピー元と一致させます。")
        case .autoRename:
            L10n.tr("同名項目がある場合は「copy」「copy 2」などの重複しない名前へ変更します。既存項目は変更しません。")
        }
    }

    private var finalConfirmationMessage: String {
        guard let plan = controller.plan else { return "" }
        let destructive = plan.selectedActions.filter { $0.kind.isDestructive }.count
        return L10n.format("%1$lld件を実行します。上書き・削除: %2$lld件\nターゲット: %3$@\n削除対象はゴミ箱へ移動し、完全削除しません。", Int64(plan.selectedActions.count), Int64(destructive), plan.targetDirectoryURL.path)
    }

    private func icon(for kind: TransferPlanActionKind) -> String {
        switch kind {
        case .copy: "doc.on.doc"
        case .merge: "arrow.triangle.merge"
        case .replace: "arrow.triangle.2.circlepath"
        case .trashTarget: "trash"
        case .skip: "minus.circle"
        case .autoRename: "character.cursor.ibeam"
        }
    }
}
