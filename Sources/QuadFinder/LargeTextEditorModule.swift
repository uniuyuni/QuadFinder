import AppKit
import SwiftUI

@MainActor
final class LargeTextEditorController: ObservableObject {
    static let windowBytes: UInt64 = 2 * 1_024 * 1_024
    @Published private(set) var url: URL?
    @Published private(set) var size: UInt64 = 0
    @Published private(set) var offset: UInt64 = 0
    @Published var text = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isEditing = false
    @Published private(set) var isDirty = false
    @Published private(set) var error: String?
    @Published var searchText = ""
    @Published private(set) var searchProgress: Double?
    @Published private(set) var matches: [LargeTextSearchMatch] = []
    @Published private(set) var currentMatch = 0
    @Published private(set) var lineIndex: LargeTextLineIndex?

    private let reader = LargeTextPageReader()
    private let scanner = LargeTextScanner()
    private var table: LargeTextPieceTable?
    private var windowRange: Range<UInt64> = 0..<0
    private var loadedText = ""
    private var bomPrefix = Data()
    private var stamp: ExternalFileStamp?
    private var task: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var documentEncoding: TextDocumentEncoding = .utf8

    var canEdit: Bool { size < 1_000_000_000 && (documentEncoding == .utf8 || documentEncoding == .utf8BOM) }
    var hasPrevious: Bool { offset > 0 }
    var hasNext: Bool { windowRange.upperBound < (table == nil ? size : max(size, windowRange.upperBound)) }

    deinit { task?.cancel(); scanTask?.cancel() }

    func select(_ newURL: URL?, encoding: TextDocumentEncoding) async {
        guard url != newURL else { return }
        task?.cancel(); scanTask?.cancel(); url = newURL; text = ""; isDirty = false; isEditing = false
        documentEncoding = encoding
        guard let newURL else { return }
        do {
            let snapshot = try await reader.snapshot(of: newURL)
            size = snapshot.size; table = LargeTextPieceTable(originalLength: snapshot.size)
            stamp = try? ExternalFileStamp.capture(at: newURL)
            await loadWindow(at: 0)
        } catch { self.error = error.localizedDescription }
    }

    func enableEditing() { guard canEdit else { return }; isEditing = true }
    func userChanged(_ value: String) { text = value; if isEditing && value != loadedText { isDirty = true } }

    func loadWindow(at requested: UInt64) async {
        guard let url, let table else { return }
        do {
            if isDirty { await commitWindow() }
            isLoading = true; defer { isLoading = false }
            let logicalLength = await table.length
            let safe = min(requested, logicalLength)
            let range = safe..<min(logicalLength, safe + Self.windowBytes)
            let data = try await table.read(range, originalURL: url, reader: reader)
            windowRange = range; offset = safe
            var body = data
            bomPrefix = Data()
            if safe == 0, body.starts(with: [0xEF, 0xBB, 0xBF]) { bomPrefix = body.prefix(3); body = body.dropFirst(3) }
            text = String(data: body, encoding: documentEncoding.stringEncoding) ?? String(decoding: body, as: UTF8.self)
            loadedText = text; isDirty = false
        } catch { self.error = error.localizedDescription }
    }

    func previous() { Task { await loadWindow(at: offset > Self.windowBytes ? offset - Self.windowBytes : 0) } }
    func next() { Task { await loadWindow(at: windowRange.upperBound) } }
    func goToOffset(_ value: UInt64) { Task { await loadWindow(at: value) } }

    func buildIndexAndGo(to line: Int) {
        guard let url else { return }; scanTask?.cancel()
        scanTask = Task {
            do {
                let generation = await scanner.beginGeneration()
                let index = try await scanner.buildLineIndex(url: url, reader: reader, generation: generation) { [weak self] done, total in
                    await MainActor.run { self?.searchProgress = total == 0 ? 1 : Double(done) / Double(total) }
                }
                guard !Task.isCancelled else { return }
                lineIndex = index; searchProgress = nil
                let number = min(max(1, line), index.lineCount)
                await loadWindow(at: index.lineStarts[number - 1])
            } catch is CancellationError { searchProgress = nil }
            catch { self.error = error.localizedDescription; searchProgress = nil }
        }
    }

    func search() {
        guard let url, let query = searchText.data(using: documentEncoding.stringEncoding), !query.isEmpty else { return }
        scanTask?.cancel(); matches = []; currentMatch = 0; searchProgress = 0
        scanTask = Task {
            do {
                let generation = await scanner.beginGeneration()
                let found = try await scanner.search(url: url, query: query, reader: reader, generation: generation) { [weak self] done, total in
                    await MainActor.run { self?.searchProgress = total == 0 ? 1 : Double(done) / Double(total) }
                }
                guard !Task.isCancelled else { return }
                matches = found; searchProgress = nil
                if let first = found.first { await loadWindow(at: first.byteRange.lowerBound) }
            } catch is CancellationError { searchProgress = nil }
            catch { self.error = error.localizedDescription; searchProgress = nil }
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }; currentMatch = (currentMatch + 1) % matches.count
        Task { await loadWindow(at: matches[currentMatch].byteRange.lowerBound) }
    }
    func cancelScan() { scanTask?.cancel(); scanTask = nil; searchProgress = nil }

    private func commitWindow() async {
        guard let table, isDirty else { return }
        var bytes = bomPrefix; bytes.append(text.data(using: .utf8) ?? Data())
        await table.delete(windowRange); await table.insert(bytes, at: windowRange.lowerBound)
        windowRange = windowRange.lowerBound..<(windowRange.lowerBound + UInt64(bytes.count))
        loadedText = text; isDirty = false
    }

    func save() async throws -> TextSaveHistoryOutcome? {
        guard let url, let table else { return nil }
        guard isEditing, canEdit else { throw CocoaError(.fileWriteNoPermission) }
        await commitWindow()
        if let stamp, ExternalFileState.compare(expected: stamp, url: url) != .unchanged {
            throw SafeTextSaveError.externalConflict(ExternalFileState.compare(expected: stamp, url: url))
        }
        let beforeFP = HistoryFingerprint.capture(url)
        let before = try Self.backup(url, "before")
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do { try await table.write(originalURL: url, reader: reader, to: handle); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) { try? FileManager.default.setAttributes(attrs, ofItemAtPath: temp.path) }
        if let stamp, ExternalFileState.compare(expected: stamp, url: url) != .unchanged { throw SafeTextSaveError.externalConflict(.modified(stamp)) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        guard let afterFP = HistoryFingerprint.capture(url) else { throw CocoaError(.fileWriteUnknown) }
        let after = try Self.backup(url, "after")
        self.stamp = try? ExternalFileStamp.capture(at: url); size = UInt64(afterFP.size); isDirty = false
        return .init(target: url, beforeBackup: before, afterBackup: after, beforeFingerprint: beforeFP,
                     afterFingerprint: afterFP, byteCount: afterFP.size)
    }

    nonisolated private static func backup(_ url: URL, _ suffix: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuadFinder/TextEditHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let result = base.appendingPathComponent("\(UUID().uuidString)-\(suffix)")
        try FileManager.default.copyItem(at: url, to: result); return result
    }
}

struct LargeTextEditorView: View {
    let url: URL
    let encoding: TextDocumentEncoding
    let history: OperationHistoryStore
    @ObservedObject var controller: LargeTextEditorController
    @State private var offset = "0"
    @State private var line = ""
    @State private var requestedLine: Int?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label(L10n.tr(controller.size >= 1_000_000_000 ? "1GB以上：読み取り専用" : (controller.isEditing ? "大容量編集モード" : "大容量読み取りモード")), systemImage: "doc.text.magnifyingglass")
                Spacer()
                if !controller.isEditing && controller.canEdit { Button(L10n.tr("編集モードへ切り替える")) { controller.enableEditing() } }
                Button(L10n.tr("保存")) { save() }.disabled(!controller.isEditing)
            }.font(.caption)
            HStack {
                Button(L10n.tr("前")) { controller.previous() }.disabled(!controller.hasPrevious)
                Button(L10n.tr("次")) { controller.next() }
                TextField("byte offset", text: $offset).frame(width: 90).onSubmit { if let n = UInt64(offset) { controller.goToOffset(n) } }
                TextField(L10n.tr("行"), text: $line).frame(width: 55).onSubmit { if let n = Int(line) { controller.buildIndexAndGo(to: n) } }
                TextField(L10n.tr("全体を検索"), text: $controller.searchText).onSubmit { controller.search() }
                Button(L10n.tr("検索")) { controller.search() }
                if controller.searchProgress != nil { Button(L10n.tr("中止")) { controller.cancelScan() } }
                if !controller.matches.isEmpty { Button(L10n.format("次 %1$lld/%2$lld", Int64(controller.currentMatch + 1), Int64(controller.matches.count))) { controller.nextMatch() } }
            }.controlSize(.small)
            if let progress = controller.searchProgress { ProgressView(value: progress) }
            NativePlainTextEditor(text: $controller.text, wraps: false, fontSize: 11, tabWidth: 4, showsInvisibles: false,
                onChange: controller.userChanged, onSelection: { _,_,_ in },
                onSave: { if controller.isDirty { save() } }, requestedLine: $requestedLine)
                .disabled(!controller.isEditing)
            HStack { Text("byte \(controller.offset) / \(controller.size)"); Spacer(); Text(L10n.tr("64KiB page・64MB LRU")) }.font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: url) { await controller.select(url, encoding: encoding) }
        .onChange(of: controller.offset) { _, value in offset = String(value) }
        .alert(L10n.tr("大容量ファイルを保存できません"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L10n.tr("OK")) {} } message: { Text(error ?? "") }
    }

    private func save() { Task { do { if let result = try await controller.save() { record(result) } } catch { self.error = error.localizedDescription } } }
    private func record(_ result: TextSaveHistoryOutcome) {
        guard let before = result.beforeBackup, let after = result.afterBackup, let beforeFP = result.beforeFingerprint else { return }
        history.record(.init(kind: .textEdit, summary: L10n.format("大容量テキストを保存: %@", result.target.lastPathComponent),
            steps: [.edited(file: result.target, beforeBackup: before, afterBackup: after,
                            beforeFingerprint: beforeFP, afterFingerprint: result.afterFingerprint)],
            itemCount: 1, byteCount: result.byteCount))
    }
}
