import Foundation
import SwiftUI

enum HistoryOperationKind: String, Codable, Sendable {
    case copy, move, rename, newFolder, duplicate, trash, symbolicLink, sync, transfer, textEdit
}

struct HistoryReplayPlan: Sendable {
    enum Direction: Sendable { case undo, redo }
    let entryID: UUID
    let direction: Direction
}

struct OperationHistoryView: View {
    @ObservedObject var store: OperationHistoryStore
    let undo: () -> Void
    let redo: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ファイル操作の履歴").font(.title2.bold())
                Spacer()
                Button("取り消す", action: undo).disabled(store.nextUndo == nil)
                Button("やり直す", action: redo).disabled(store.nextRedo == nil)
                Button("閉じる") { dismiss() }
            }
            List {
              ForEach(store.entries) { entry in
                HStack {
                    Image(systemName: entry.isUndone ? "arrow.uturn.forward.circle" : (entry.undoable ? "checkmark.circle" : "exclamationmark.triangle"))
                    VStack(alignment: .leading) {
                        Text(entry.summary)
                        Text("\(entry.timestamp.formatted()) · \(entry.itemCount)項目" + (entry.reason.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.id == store.nextUndo?.id { Button("Undo", action: undo) }
                    if entry.id == store.nextRedo?.id { Button("Redo", action: redo) }
                }
              }
            }
            HStack { Button("履歴を消去", role: .destructive) { store.clear() }; Spacer() }
        }.padding().frame(minWidth: 650, minHeight: 420)
    }
}

enum HistoryStep: Codable, Equatable, Sendable {
    case created(URL)
    case copied(source: URL, target: URL, sourceFingerprint: HistoryFingerprint, targetFingerprint: HistoryFingerprint)
    case createdDirectory(URL)
    case duplicated(source: URL, target: URL, sourceFingerprint: HistoryFingerprint, targetFingerprint: HistoryFingerprint)
    case symbolicLink(source: URL, target: URL, targetFingerprint: HistoryFingerprint)
    case moved(from: URL, to: URL)
    case trashed(original: URL, trashURL: URL?)
    case replaced(source: URL, target: URL, oldTrashURL: URL?, sourceFingerprint: HistoryFingerprint, newFingerprint: HistoryFingerprint, movesSource: Bool)
    case edited(file: URL, beforeBackup: URL, afterBackup: URL, beforeFingerprint: HistoryFingerprint, afterFingerprint: HistoryFingerprint)
}

extension HistoryStep {
    var undoabilityReason: String? {
        switch self {
        case .trashed(_, nil): "OSからゴミ箱内の復元URLを取得できませんでした"
        case .replaced(_, _, nil, _, _, _): "置換前項目のゴミ箱URLを取得できませんでした"
        case .edited(_, let before, let after, _, _) where !FileManager.default.fileExists(atPath: before.path) || !FileManager.default.fileExists(atPath: after.path): "編集履歴のバックアップがありません"
        default: nil
        }
    }
}

struct HistoryFingerprint: Codable, Equatable, Sendable {
    let type: String
    let size: Int64
    let modificationDate: Date?

    static func capture(_ url: URL) -> HistoryFingerprint? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = a[.type] as? FileAttributeType else { return nil }
        return .init(type: type.rawValue, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                     modificationDate: a[.modificationDate] as? Date)
    }
}

struct OperationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: HistoryOperationKind
    let summary: String
    var steps: [HistoryStep]
    let itemCount: Int
    let byteCount: Int64
    let sourceBookmark: Data?
    let targetBookmark: Data?
    var isUndone: Bool
    var undoable: Bool
    var reason: String?

    init(id: UUID = UUID(), timestamp: Date = .now, kind: HistoryOperationKind,
         summary: String, steps: [HistoryStep], itemCount: Int, byteCount: Int64 = 0,
         sourceBookmark: Data? = nil, targetBookmark: Data? = nil,
         isUndone: Bool = false, undoable: Bool = true, reason: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.summary = summary
        self.steps = steps; self.itemCount = itemCount; self.byteCount = byteCount
        self.sourceBookmark = sourceBookmark; self.targetBookmark = targetBookmark
        self.isUndone = isUndone; self.undoable = undoable; self.reason = reason
    }
}

struct LargeHistoryOperationPolicy: Sendable {
    static let itemThreshold = 20
    static let byteThreshold: Int64 = 100 * 1_000_000
    static func requiresConfirmation(_ entry: OperationHistoryEntry) -> Bool {
        entry.itemCount >= itemThreshold || entry.byteCount >= byteThreshold
    }
}

@MainActor
final class OperationHistoryStore: ObservableObject {
    @Published private(set) var entries: [OperationHistoryEntry] = []
    private let fileURL: URL?
    private let limit: Int
    private struct Journal: Codable { var version: Int; var entries: [OperationHistoryEntry] }

    init(fileURL: URL? = nil, limit: Int = 200) {
        self.limit = max(1, limit)
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    var nextUndo: OperationHistoryEntry? { entries.last { !$0.isUndone && $0.undoable } }
    var nextRedo: OperationHistoryEntry? { entries.last { $0.isUndone && $0.undoable } }

    func record(_ entry: OperationHistoryEntry) {
        // A new branch invalidates redo history.
        entries.removeAll { $0.isUndone }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
    }

    func clear() { entries.removeAll(); save() }

    func undo() throws {
        guard let entry = nextUndo, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        try entry.steps.reversed().forEach(validateInverse)
        for step in entry.steps.reversed() { try applyInverse(step) }
        entries[index].isUndone = true
        save()
    }

    func replay(_ plan: HistoryReplayPlan) throws {
        guard let entry = entries.first(where: { $0.id == plan.entryID }) else { throw HistoryError.orderChanged }
        var scopes: [URL] = []
        if AppSecurityEnvironment.current.isSandboxed {
            for bookmark in [entry.sourceBookmark, entry.targetBookmark].compactMap({ $0 }) {
                if let url = try? FileSystemService.resolveBookmark(bookmark),
                   url.startAccessingSecurityScopedResource() { scopes.append(url) }
            }
        }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        switch plan.direction {
        case .undo:
            guard nextUndo?.id == plan.entryID else { throw HistoryError.orderChanged }
            try undo()
        case .redo:
            guard nextRedo?.id == plan.entryID else { throw HistoryError.orderChanged }
            try redo()
        }
    }

    func redo() throws {
        guard let entry = nextRedo, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        try entry.steps.forEach(validateForward)
        var replayed: [HistoryStep] = []
        for step in entry.steps { replayed.append(try applyForward(step)) }
        entries[index].steps = replayed
        entries[index].isUndone = false
        save()
    }

    private func validateInverse(_ step: HistoryStep) throws {
        switch step {
        case .created(let u), .createdDirectory(let u):
            guard FileManager.default.fileExists(atPath: u.path) else { throw HistoryError.stale(u) }
        case .copied(_, let t, _, let fp), .duplicated(_, let t, _, let fp), .symbolicLink(_, let t, let fp):
            guard HistoryFingerprint.capture(t) == fp else { throw HistoryError.stale(t) }
        case .moved(let from, let to):
            guard FileManager.default.fileExists(atPath: to.path), !FileManager.default.fileExists(atPath: from.path) else { throw HistoryError.conflict(from) }
        case .trashed(let original, let trash):
            guard let trash, FileManager.default.fileExists(atPath: trash.path), !FileManager.default.fileExists(atPath: original.path) else { throw HistoryError.unrestorable(original) }
        case .replaced(let source, let target, let old, _, let newFP, let moves):
            guard HistoryFingerprint.capture(target) == newFP, let old, FileManager.default.fileExists(atPath: old.path),
                  !moves || !FileManager.default.fileExists(atPath: source.path) else { throw HistoryError.unrestorable(target) }
        case .edited(let file, let before, _, _, let afterFP):
            guard HistoryFingerprint.capture(file) == afterFP, FileManager.default.fileExists(atPath: before.path) else { throw HistoryError.stale(file) }
        }
    }

    private func validateForward(_ step: HistoryStep) throws {
        switch step {
        case .created(let u): throw HistoryError.unrestorable(u)
        case .createdDirectory(let t): guard !FileManager.default.fileExists(atPath: t.path) else { throw HistoryError.conflict(t) }
        case .copied(let s, let t, let fp, _), .duplicated(let s, let t, let fp, _):
            guard HistoryFingerprint.capture(s) == fp, !FileManager.default.fileExists(atPath: t.path) else { throw HistoryError.conflict(t) }
        case .symbolicLink(let s, let t, _):
            guard FileManager.default.fileExists(atPath: s.path), !FileManager.default.fileExists(atPath: t.path) else { throw HistoryError.conflict(t) }
        case .moved(let from, let to):
            guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { throw HistoryError.conflict(to) }
        case .trashed(let original, _): guard FileManager.default.fileExists(atPath: original.path) else { throw HistoryError.stale(original) }
        case .replaced(let source, let target, _, let sourceFP, _, _):
            guard HistoryFingerprint.capture(source) == sourceFP, FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.stale(source) }
        case .edited(let file, _, let after, let beforeFP, _):
            guard HistoryFingerprint.capture(file) == beforeFP, FileManager.default.fileExists(atPath: after.path) else { throw HistoryError.stale(file) }
        }
    }

    private func applyInverse(_ step: HistoryStep) throws {
        switch step {
        case .created(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { throw HistoryError.stale(url) }
            var result: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        case .copied(_, let target, _, let targetFingerprint),
             .duplicated(_, let target, _, let targetFingerprint),
             .symbolicLink(_, let target, let targetFingerprint):
            guard HistoryFingerprint.capture(target) == targetFingerprint else { throw HistoryError.stale(target) }
            var result: NSURL?; try FileManager.default.trashItem(at: target, resultingItemURL: &result)
        case .createdDirectory(let target):
            guard FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.stale(target) }
            var result: NSURL?; try FileManager.default.trashItem(at: target, resultingItemURL: &result)
        case .moved(let from, let to):
            guard FileManager.default.fileExists(atPath: to.path), !FileManager.default.fileExists(atPath: from.path) else { throw HistoryError.conflict(from) }
            try FileManager.default.moveItem(at: to, to: from)
        case .trashed(let original, let trashURL):
            guard let trashURL, FileManager.default.fileExists(atPath: trashURL.path), !FileManager.default.fileExists(atPath: original.path) else { throw HistoryError.unrestorable(original) }
            try FileManager.default.moveItem(at: trashURL, to: original)
        case .replaced(let source, let target, let oldTrashURL, _, let newFingerprint, let movesSource):
            guard HistoryFingerprint.capture(target) == newFingerprint, let oldTrashURL,
                  FileManager.default.fileExists(atPath: oldTrashURL.path) else { throw HistoryError.unrestorable(target) }
            if movesSource {
                guard !FileManager.default.fileExists(atPath: source.path) else { throw HistoryError.conflict(source) }
                try FileManager.default.moveItem(at: target, to: source)
            } else {
                var removed: NSURL?; try FileManager.default.trashItem(at: target, resultingItemURL: &removed)
            }
            try FileManager.default.moveItem(at: oldTrashURL, to: target)
        case .edited(let file, let before, _, _, let afterFP):
            guard HistoryFingerprint.capture(file) == afterFP else { throw HistoryError.stale(file) }
            try restoreTextBackup(before, to: file)
        }
    }

    private func applyForward(_ step: HistoryStep) throws -> HistoryStep {
        switch step {
        case .moved(let from, let to):
            guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { throw HistoryError.conflict(to) }
            try FileManager.default.moveItem(at: from, to: to)
            return step
        case .created(let url): throw HistoryError.unrestorable(url)
        case .createdDirectory(let target):
            guard !FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.conflict(target) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return step
        case .copied(let source, let target, let sourceFingerprint, _),
             .duplicated(let source, let target, let sourceFingerprint, _):
            guard HistoryFingerprint.capture(source) == sourceFingerprint else { throw HistoryError.stale(source) }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.conflict(target) }
            try FileManager.default.copyItem(at: source, to: target)
            guard let targetFP = HistoryFingerprint.capture(target) else { throw HistoryError.stale(target) }
            if case .copied = step { return .copied(source: source, target: target, sourceFingerprint: sourceFingerprint, targetFingerprint: targetFP) }
            return .duplicated(source: source, target: target, sourceFingerprint: sourceFingerprint, targetFingerprint: targetFP)
        case .symbolicLink(let source, let target, _):
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.conflict(target) }
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            guard let targetFP = HistoryFingerprint.capture(target) else { throw HistoryError.stale(target) }
            return .symbolicLink(source: source, target: target, targetFingerprint: targetFP)
        case .trashed(let original, _):
            guard FileManager.default.fileExists(atPath: original.path) else { throw HistoryError.stale(original) }
            var result: NSURL?; try FileManager.default.trashItem(at: original, resultingItemURL: &result)
            return .trashed(original: original, trashURL: result as URL?)
        case .replaced(let source, let target, _, let sourceFingerprint, _, let movesSource):
            guard HistoryFingerprint.capture(source) == sourceFingerprint, FileManager.default.fileExists(atPath: target.path) else { throw HistoryError.stale(source) }
            var old: NSURL?; try FileManager.default.trashItem(at: target, resultingItemURL: &old)
            if movesSource { try FileManager.default.moveItem(at: source, to: target) }
            else { try FileManager.default.copyItem(at: source, to: target) }
            guard let newFP = HistoryFingerprint.capture(target) else { throw HistoryError.stale(target) }
            return .replaced(source: source, target: target, oldTrashURL: old as URL?,
                             sourceFingerprint: sourceFingerprint, newFingerprint: newFP, movesSource: movesSource)
        case .edited(let file, _, let after, let beforeFP, let afterFP):
            guard HistoryFingerprint.capture(file) == beforeFP else { throw HistoryError.stale(file) }
            try restoreTextBackup(after, to: file)
            guard HistoryFingerprint.capture(file) == afterFP else { throw HistoryError.stale(file) }
            return step
        }
    }

    private func restoreTextBackup(_ backup: URL, to file: URL) throws {
        guard FileManager.default.fileExists(atPath: backup.path) else { throw HistoryError.unrestorable(file) }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: backup, to: temporary)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let journal = try? decoder.decode(Journal.self, from: data), journal.version <= 3 {
            entries = Array(journal.entries.suffix(limit))
        } else if let legacy = try? decoder.decode([OperationHistoryEntry].self, from: data) {
            entries = Array(legacy.suffix(limit))
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Journal(version: 3, entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch { /* History failure must never fail the file operation itself. */ }
    }

    private static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuadFinder", isDirectory: true).appendingPathComponent("operation-history.json")
    }
}

enum HistoryError: LocalizedError {
    case stale(URL), conflict(URL), unrestorable(URL), orderChanged
    var errorDescription: String? {
        switch self {
        case .stale(let u): "操作後に項目が変更または削除されています: \(u.path)"
        case .conflict(let u): "復元先に同名項目があるため中止しました: \(u.path)"
        case .unrestorable(let u): "この項目は安全に復元できません: \(u.path)"
        case .orderChanged: "操作履歴の順序が変更されました。もう一度実行してください。"
        }
    }
}
