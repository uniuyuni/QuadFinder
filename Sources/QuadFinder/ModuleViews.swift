import AppKit
import SwiftUI

struct SelectionInfoModuleView: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    private var referencedPane: PaneState? {
        switch workspace.state.moduleSettings.selectionInfo.context {
        case .active: workspace.activePane
        case .pinned(let id): workspace.pane(id: id)
        case .pair(let source, _): workspace.pane(id: source)
        case .window: workspace.activePane
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("選択情報", systemImage: "info.circle")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("アクティブペインに追従") {
                        workspace.updateModuleSettings { $0.selectionInfo.context = .active }
                    }
                    Divider()
                    ForEach(Array(workspace.state.orderedPaneIDs.enumerated()), id: \.element) { index, id in
                        Button("ペイン\(index + 1)に固定") {
                            workspace.updateModuleSettings { $0.selectionInfo.context = .pinned(id) }
                        }
                    }
                } label: { Image(systemName: "pin") }
                .menuStyle(.borderlessButton)
                Button {
                    workspace.updateModuleSettings { $0.selectionInfo.isVisible = false }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            Divider()
            if let pane = referencedPane {
                Text(pane.currentURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if pane.selectedURLs.isEmpty {
                    ContentUnavailableView("選択なし", systemImage: "cursorarrow")
                } else {
                    List(Array(pane.selectedURLs).sorted(by: { $0.path < $1.path }), id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                Text(url.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 230, idealWidth: 280)
        .background(.regularMaterial)
    }
}

struct OperationQueueModuleView: View {
    @ObservedObject var queue: FileOperationQueue
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("操作キュー", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Text("Window").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完了履歴を消去") { queue.clearCompleted() }
                    .disabled(!queue.jobs.contains { $0.status.isFinished })
                Button {
                    workspace.updateModuleSettings { $0.operationQueue.isVisible = false }
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if queue.jobs.isEmpty {
                Text("ファイル操作はありません").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(job.operation.kind.rawValue).bold()
                                    Text(job.status.rawValue).foregroundStyle(statusColor(job.status))
                                    if !job.status.isFinished {
                                        Button("中止") { queue.stop(job.id) }.controlSize(.small)
                                    }
                                }
                                Text(job.sourceDescription).lineLimit(1)
                                Text("→ \(job.operation.targetDirectoryURL.path(percentEncoded: false))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let error = job.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                            }
                            .padding(7)
                            .frame(width: 310, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(minHeight: 74, idealHeight: 125, maxHeight: 170)
        .background(.regularMaterial)
    }

    private func statusColor(_ status: FileOperationStatus) -> Color {
        switch status {
        case .queued, .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .cancelled, .stopped: .secondary
        }
    }
}

/// Compact, always-visible feedback for a long copy/move. Detailed jobs stay
/// in the operation queue module; this badge occupies the requested top-right
/// toolbar position.
struct FileOperationProgressBadge: View {
    @ObservedObject var queue: FileOperationQueue
    @State private var showsQueue = false

    var body: some View {
        let summary = queue.progressSummary
        if summary.isActive, summary.totalCount > 0 {
            Button { showsQueue.toggle() } label: {
              HStack(spacing: 5) {
                ProgressView(value: summary.fractionCompleted).frame(width: 42)
                Text("\(Int(summary.fractionCompleted * 100))%")
                    .font(.caption.monospacedDigit())
                if summary.totalBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: summary.completedBytes, countStyle: .file))/\(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if summary.waitingCount > 0 { Text("待機 \(summary.waitingCount)").font(.caption2) }
              }
            }.buttonStyle(.plain)
            .popover(isPresented: $showsQueue, arrowEdge: .bottom) {
                FileOperationQueuePopover(queue: queue)
            }
            .frame(maxWidth: 190)
            .help("ファイル操作の進捗")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("ファイル操作の進捗 \(Int(summary.fractionCompleted * 100))パーセント")
        }
    }
}

private struct FileOperationQueuePopover: View {
    @ObservedObject var queue: FileOperationQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label("ファイル操作キュー", systemImage: "list.bullet.rectangle").font(.headline); Spacer(); Button("完了を消去") { queue.clearCompleted() } }
            if queue.jobs.isEmpty { Text("ファイル操作はありません").foregroundStyle(.secondary) }
            else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(job.operation.kind.rawValue).bold()
                                    Text(job.status.rawValue).foregroundStyle(job.status == .failed ? .red : .secondary)
                                    Spacer()
                                    if !job.status.isFinished { Button("中止") { queue.stop(job.id) }.controlSize(.small) }
                                }
                                Text(job.sourceDescription).lineLimit(1).help(job.sourceDescription)
                                if let progress = job.progress {
                                    ProgressView(value: progress.fractionCompleted)
                                    HStack {
                                        Text("\(progress.completedItems)/\(progress.totalItems)項目")
                                        Spacer()
                                        if progress.totalBytes > 0 { Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))") }
                                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let error = job.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                            }
                            .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }.padding(12).frame(width: 430, height: 330)
    }
}
