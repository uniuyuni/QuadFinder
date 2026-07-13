import AppKit
import SwiftUI

enum TextDocumentEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 BOM"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case utf32LE = "UTF-32 LE"
    case utf32BE = "UTF-32 BE"
    case shiftJIS = "Shift_JIS"
    case eucJP = "EUC-JP"
    case iso2022JP = "ISO-2022-JP"

    var id: String { rawValue }
    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .utf32LE: .utf32LittleEndian
        case .utf32BE: .utf32BigEndian
        case .shiftJIS: .shiftJIS
        case .eucJP: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_JP.rawValue)))
        case .iso2022JP: .iso2022JP
        }
    }
    var core: TextFileEncoding {
        switch self {
        case .utf8: .utf8
        case .utf8BOM: .utf8BOM
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .utf32LE: .utf32LittleEndian
        case .utf32BE: .utf32BigEndian
        case .shiftJIS: .shiftJIS
        case .eucJP: .eucJP
        case .iso2022JP: .iso2022JP
        }
    }
    init(core: TextFileEncoding) {
        switch core {
        case .utf8: self = .utf8
        case .utf8BOM: self = .utf8BOM
        case .utf16LittleEndian: self = .utf16LE
        case .utf16BigEndian: self = .utf16BE
        case .utf32LittleEndian: self = .utf32LE
        case .utf32BigEndian: self = .utf32BE
        case .shiftJIS: self = .shiftJIS
        case .eucJP: self = .eucJP
        case .iso2022JP: self = .iso2022JP
        }
    }
}

enum TextNewline: String, CaseIterable, Sendable {
    case lf = "LF", crlf = "CRLF", cr = "CR"
    var sequence: String { switch self { case .lf: "\n"; case .crlf: "\r\n"; case .cr: "\r" } }
    var core: TextNewlineStyle { switch self { case .lf: .lf; case .crlf: .crlf; case .cr: .cr } }
    init(core: TextNewlineStyle) { self = core == .crlf ? .crlf : core == .cr ? .cr : .lf }
}

struct TextLoadResult: Sendable {
    let text: String
    let encoding: TextDocumentEncoding
    let newline: TextNewline
    let byteCount: UInt64
    let isBinary: Bool
    let isWindowed: Bool
}

enum TextModuleIO {
    static let normalLimit: UInt64 = 100 * 1_000_000
    static let windowSize = 2 * 1_024 * 1_024

    static func load(_ url: URL, forcedEncoding: TextDocumentEncoding? = nil) throws -> TextLoadResult {
        let scoped = AppSecurityEnvironment.current.isSandboxed && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var isLarge = size > normalLimit
        if !isLarge, size > 8 * 1_000_000 {
            var lines = 1
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                lines += chunk.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
                if lines > 1_000_000 { isLarge = true; break }
            }
            try handle.seek(toOffset: 0)
        }
        let targetCount = isLarge ? windowSize : Int(size)
        var data = Data(); data.reserveCapacity(targetCount)
        while data.count < targetCount {
            let chunk = try handle.read(upToCount: min(64 * 1_024, targetCount - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if forcedEncoding == nil, TextFileCodec.isLikelyBinary(data) {
            return TextLoadResult(text: "", encoding: .utf8, newline: .lf,
                                  byteCount: size, isBinary: true, isWindowed: isLarge)
        }
        if forcedEncoding == nil {
            do {
                let decoded = try TextFileCodec.decode(data)
                return TextLoadResult(text: decoded.text, encoding: TextDocumentEncoding(core: decoded.encoding),
                                      newline: TextNewline(core: decoded.newlines.preferredStyle), byteCount: size,
                                      isBinary: false, isWindowed: isLarge)
            } catch TextFileDecodeError.binary {
                return TextLoadResult(text: "", encoding: .utf8, newline: .lf, byteCount: size,
                                      isBinary: true, isWindowed: isLarge)
            }
        }
        let encoding = forcedEncoding ?? .utf8
        let skip = 0
        guard let text = String(data: data.dropFirst(skip), encoding: encoding.stringEncoding) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return TextLoadResult(text: normalizeNewlines(text), encoding: encoding,
                              newline: detectNewline(text), byteCount: size,
                              isBinary: false, isWindowed: isLarge)
    }

    static func detectEncoding(_ data: Data) -> (TextDocumentEncoding, Int) {
        let b = Array(data.prefix(4))
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BE, 4) }
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LE, 4) }
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if b.starts(with: [0xFE, 0xFF]) { return (.utf16BE, 2) }
        if b.starts(with: [0xFF, 0xFE]) { return (.utf16LE, 2) }
        if String(data: data, encoding: .utf8) != nil { return (.utf8, 0) }
        for candidate in [TextDocumentEncoding.shiftJIS, .eucJP, .iso2022JP] {
            if String(data: data, encoding: candidate.stringEncoding) != nil { return (candidate, 0) }
        }
        return (.utf8, 0)
    }

    static func detectNewline(_ value: String) -> TextNewline {
        if value.contains("\r\n") { return .crlf }
        if value.contains("\r") { return .cr }
        return .lf
    }

    static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func isProbablyBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.prefix(4096).contains(0) {
            let b = Array(data.prefix(4))
            return !(b.starts(with: [0xFE, 0xFF]) || b.starts(with: [0xFF, 0xFE]) ||
                     b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || b.starts(with: [0xFF, 0xFE, 0x00, 0x00]))
        }
        let controls = data.prefix(4096).filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return controls * 20 > min(4096, data.count)
    }
}

struct TextFileStamp: Equatable, Sendable {
    let size: UInt64
    let modified: Date?
    static func capture(_ url: URL) -> TextFileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return .init(size: (a[.size] as? NSNumber)?.uint64Value ?? 0, modified: a[.modificationDate] as? Date)
    }
}

struct TextSaveHistoryOutcome: Sendable {
    let target: URL
    let beforeBackup: URL?
    let afterBackup: URL?
    let beforeFingerprint: HistoryFingerprint?
    let afterFingerprint: HistoryFingerprint
    let byteCount: Int64
}

struct TextEditorSelectionTarget: Equatable, Sendable {
    let paneID: UUID?
    let selection: Set<URL>

    var textFile: URL? {
        guard selection.count == 1, let url = selection.first,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

enum TextDirtyTransitionRequest: Equatable {
    case unchanged
    case switchNow(TextEditorSelectionTarget)
    case closeNow
    case showPrompt
    case pendingUpdated
}

/// A UI-independent transition state machine. The pane selection may change
/// before the editor can ask about unsaved text, so the document remains
/// loaded until one of the three explicit decisions completes.
struct TextDirtyTransitionCoordinator: Equatable {
    private(set) var origin: TextEditorSelectionTarget?
    private(set) var pending: TextEditorSelectionTarget?
    private(set) var isClosePending = false
    private(set) var isPrompting = false

    mutating func request(currentURL: URL?, currentPaneID: UUID?, isDirty: Bool,
                          target: TextEditorSelectionTarget) -> TextDirtyTransitionRequest {
        if target.textFile?.standardizedFileURL == currentURL?.standardizedFileURL { return .unchanged }
        guard isDirty, let currentURL else { return .switchNow(target) }
        pending = target
        isClosePending = false
        if isPrompting { return .pendingUpdated }
        origin = TextEditorSelectionTarget(paneID: currentPaneID, selection: [currentURL])
        isPrompting = true
        return .showPrompt
    }

    mutating func requestClose(currentURL: URL?, currentPaneID: UUID?, isDirty: Bool) -> TextDirtyTransitionRequest {
        guard isDirty, let currentURL else { return .closeNow }
        pending = nil
        isClosePending = true
        if isPrompting { return .pendingUpdated }
        origin = TextEditorSelectionTarget(paneID: currentPaneID, selection: [currentURL])
        isPrompting = true
        return .showPrompt
    }

    mutating func acceptPending() -> TextEditorSelectionTarget? {
        let result = pending
        clear()
        return result
    }

    mutating func acceptClose() -> Bool {
        guard isClosePending else { return false }
        clear()
        return true
    }

    mutating func cancelOrFail() -> TextEditorSelectionTarget? {
        let result = origin
        clear()
        return result
    }

    private mutating func clear() {
        origin = nil
        pending = nil
        isClosePending = false
        isPrompting = false
    }
}

/// Routes every hide request through the live editor before ContentView
/// removes it, so the Modules menu cannot bypass the dirty-document guard.
@MainActor
final class TextEditorModuleCloseRouter: ObservableObject {
    private var registration: (id: UUID, handler: () -> Void)?

    func install(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        registration = (id, handler)
        return id
    }
    func uninstall(_ id: UUID?) {
        guard registration?.id == id else { return }
        registration = nil
    }

    @discardableResult
    func requestClose() -> Bool {
        guard let registration else { return false }
        registration.handler()
        return true
    }
}

@MainActor
final class TextEditorDocumentModel: ObservableObject {
    enum State: Equatable { case empty, loading, ready, binary, failed(String) }
    @Published private(set) var state: State = .empty
    @Published var text = ""
    @Published private(set) var isDirty = false
    @Published private(set) var isLarge = false
    @Published private(set) var conflict = false
    @Published private(set) var byteCount: UInt64 = 0
    @Published var encoding: TextDocumentEncoding = .utf8
    @Published var newline: TextNewline = .lf
    @Published var wraps = true
    @Published var fontSize: CGFloat = 12
    @Published var tabWidth = 4
    @Published var showsInvisibles = false
    @Published var line = 1
    @Published var column = 1
    @Published var selectionCount = 0
    private(set) var url: URL?
    private var stamp: TextFileStamp?
    private var externalStamp: ExternalFileStamp?
    private var generation = UUID()
    private var suppressDirty = false

    func select(_ url: URL?) async {
        guard url != self.url else { return }
        self.url = url; state = url == nil ? .empty : .loading; isDirty = false; isLarge = false; conflict = false
        guard let url else { text = ""; return }
        let token = UUID(); generation = token
        do {
            let loaded = try await Task.detached { try TextModuleIO.load(url) }.value
            guard generation == token else { return }
            apply(loaded); stamp = TextFileStamp.capture(url); externalStamp = try? ExternalFileStamp.capture(at: url)
        } catch { guard generation == token else { return }; state = .failed(error.localizedDescription) }
    }

    func reload(forced: TextDocumentEncoding? = nil) async {
        guard let url else { return }
        state = .loading; conflict = false
        do {
            let loaded = try await Task.detached { try TextModuleIO.load(url, forcedEncoding: forced) }.value
            apply(loaded); stamp = TextFileStamp.capture(url); externalStamp = try? ExternalFileStamp.capture(at: url); isDirty = false
        } catch { state = .failed(error.localizedDescription) }
    }

    private func apply(_ result: TextLoadResult) {
        suppressDirty = true; text = result.text; suppressDirty = false
        encoding = result.encoding; newline = result.newline; byteCount = result.byteCount
        isLarge = result.isWindowed; state = result.isBinary ? .binary : .ready
    }

    func textChanged(_ value: String) {
        text = value
        if !suppressDirty { isDirty = true }
    }

    func save(to destination: URL? = nil, overwriteExternal: Bool = false) async throws -> TextSaveHistoryOutcome? {
        guard let target = destination ?? url else { return nil }
        guard !isLarge else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let value = text; let fileEncoding = encoding.core; let lineStyle = newline.core
        let expected = destination == nil && !overwriteExternal ? externalStamp : nil
        let outcome = try await Task.detached { () throws -> TextSaveHistoryOutcome in
            let scoped = AppSecurityEnvironment.current.isSandboxed && target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() } }
            let existed = FileManager.default.fileExists(atPath: target.path)
            let beforeFP = HistoryFingerprint.capture(target)
            let beforeBackup = existed ? try Self.historyBackup(of: target, suffix: "before") : nil
            var completed = false
            defer { if !completed, let beforeBackup { try? FileManager.default.removeItem(at: beforeBackup) } }
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try SafeAtomicFileWriter.replaceItem(at: target, expectedStamp: expected) { handle in
                    try TextFileCodec.write(normalizedTextChunks: [value], encoding: fileEncoding, newline: lineStyle, to: handle)
                }
            } else {
                let bytes = try TextFileCodec.encode(value, encoding: fileEncoding, newline: lineStyle)
                try Self.atomicWrite(bytes, to: target)
            }
            guard let afterFP = HistoryFingerprint.capture(target) else { throw CocoaError(.fileWriteUnknown) }
            let afterBackup = existed ? try Self.historyBackup(of: target, suffix: "after") : nil
            completed = true
            return .init(target: target, beforeBackup: beforeBackup, afterBackup: afterBackup,
                         beforeFingerprint: beforeFP, afterFingerprint: afterFP, byteCount: afterFP.size)
        }.value
        if destination == nil { isDirty = false; stamp = TextFileStamp.capture(target); externalStamp = try? ExternalFileStamp.capture(at: target); conflict = false }
        return outcome
    }

    nonisolated private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).quadfinder-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        try data.write(to: temp, options: [.atomic])
        if let attrs = try? fm.attributesOfItem(atPath: url.path) { try? fm.setAttributes(attrs, ofItemAtPath: temp.path) }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: url) }
    }

    nonisolated private static func historyBackup(of url: URL, suffix: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuadFinder/TextEditHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let result = base.appendingPathComponent("\(UUID().uuidString)-\(suffix)")
        try FileManager.default.copyItem(at: url, to: result)
        return result
    }

    func pollExternalChange() async {
        guard let url, let old = stamp, let current = TextFileStamp.capture(url), current != old else { return }
        if isDirty { conflict = true } else { await reload() }
    }

    func dismissConflict() { conflict = false; stamp = url.flatMap(TextFileStamp.capture) }
}

struct NativePlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let wraps: Bool
    let fontSize: CGFloat
    let tabWidth: Int
    let showsInvisibles: Bool
    let onChange: (String) -> Void
    let onSelection: (Int, Int, Int) -> Void
    let onSave: () -> Void
    @Binding var requestedLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !wraps
        scroll.autoresizingMask = [.width, .height]
        let view = QuadFinderTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.delegate = context.coordinator; view.string = text
        view.saveHandler = onSave
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.verticalRulerView = TextLineNumberRulerView(textView: view)
        configure(view, scroll: scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        (view as? QuadFinderTextView)?.saveHandler = onSave
        if view.string != text { let range = view.selectedRange(); view.string = text; view.setSelectedRange(NSRange(location: min(range.location, view.string.utf16.count), length: 0)) }
        configure(view, scroll: scroll)
        if let requestedLine { context.coordinator.go(to: requestedLine, in: view); DispatchQueue.main.async { self.requestedLine = nil } }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? QuadFinderTextView else { return }
        if let window = view.window, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
        view.delegate = nil
        view.saveHandler = nil
        view.breakUndoCoalescing()
    }
    private func configure(_ view: NSTextView, scroll: NSScrollView) {
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 5)
        view.textContainer?.widthTracksTextView = wraps
        view.textContainer?.containerSize = NSSize(width: wraps ? scroll.contentSize.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isHorizontallyResizable = !wraps; view.autoresizingMask = wraps ? [.width] : []
        let style = NSMutableParagraphStyle(); style.defaultTabInterval = ceil(fontSize * 0.62) * CGFloat(tabWidth)
        view.defaultParagraphStyle = style; view.typingAttributes[.paragraphStyle] = style
        view.layoutManager?.showsInvisibleCharacters = showsInvisibles
        scroll.hasHorizontalScroller = !wraps
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePlainTextEditor
        init(_ parent: NativePlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let v = notification.object as? NSTextView else { return }; parent.onChange(v.string); report(v)
        }
        func textViewDidChangeSelection(_ notification: Notification) { if let v = notification.object as? NSTextView { report(v) } }
        private func report(_ view: NSTextView) {
            let p = view.selectedRange().location; let prefix = (view.string as NSString).substring(to: min(p, view.string.utf16.count))
            let pieces = prefix.split(separator: "\n", omittingEmptySubsequences: false)
            parent.onSelection(pieces.count, (pieces.last?.count ?? 0) + 1, view.selectedRange().length)
        }
        func go(to line: Int, in view: NSTextView) {
            var current = 1; var index = 0
            for c in view.string where current < max(1, line) { index += c.utf16.count; if c == "\n" { current += 1 } }
            view.setSelectedRange(NSRange(location: index, length: 0)); view.scrollRangeToVisible(NSRange(location: index, length: 0)); view.window?.makeFirstResponder(view)
        }
    }
}

@MainActor
final class QuadFinderTextView: NSTextView {
    var saveHandler: (() -> Void)?

    @objc func quadFinderSave(_ sender: Any?) { saveHandler?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveHandler?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // NSTextView remains the sole owner of ordinary text, IME/marked text,
        // editing keys and arrow-key movement. Command-S is handled above.
        super.keyDown(with: event)
    }
}

@MainActor
enum TextEditorFirstResponderLifecycle {
    static func resignEditor(in window: NSWindow?) {
        guard let window, window.firstResponder is QuadFinderTextView else { return }
        window.makeFirstResponder(nil)
    }

    static func focusEditor(in window: NSWindow?) {
        guard let window, let root = window.contentView,
              let editor = findEditor(in: root), editor.isEditable else { return }
        window.makeFirstResponder(editor)
    }

    private static func findEditor(in view: NSView) -> QuadFinderTextView? {
        if let editor = view as? QuadFinderTextView { return editor }
        for child in view.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }
}

final class TextLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 42
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func redraw() { needsDisplay = true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.enclosingScrollView?.contentView.bounds ?? textView.bounds
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let string = textView.string as NSString
        var line = 1
        if glyphRange.location > 0 {
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            line += string.substring(to: min(character, string.length)).reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        }
        var glyph = glyphRange.location
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while glyph < NSMaxRange(glyphRange) {
            var lineRange = NSRange(); let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            let label = "\(line)" as NSString; let size = label.size(withAttributes: attributes)
            let y = rect.minY - visible.minY + textView.textContainerOrigin.y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 5, y: y), withAttributes: attributes)
            glyph = NSMaxRange(lineRange); line += 1
        }
    }
}

struct TextEditorModuleView: View {
    let selectedURLs: Set<URL>
    let selectionPaneID: UUID?
    let restoreSelection: (UUID?, Set<URL>) -> Void
    let openHex: () -> Void
    let commitClose: () -> Void
    @ObservedObject var closeRouter: TextEditorModuleCloseRouter
    @ObservedObject var history: OperationHistoryStore
    @StateObject private var model = TextEditorDocumentModel()
    @StateObject private var largeController = LargeTextEditorController()
    @State private var requestedLine: Int?
    @State private var lineInput = ""
    @State private var error: String?
    @State private var showCompare = false
    @AppStorage("TextEditorModule.autosave") private var autosave = false
    @AppStorage("TextEditorModule.width") private var panelWidth = Double(ModulePanelLayout.idealWidth)
    @State private var resizeStart: (x: CGFloat, width: CGFloat)?
    @State private var transientWidth: CGFloat?
    @State private var transition = TextDirtyTransitionCoordinator()
    @State private var documentPaneID: UUID?
    @State private var showsDirtyPrompt = false
    @State private var autoSaveTransitionInFlight = false
    @State private var closeRegistration: UUID?

    private var selectedFile: URL? {
        guard selectedURLs.count == 1, let u = selectedURLs.first,
              (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return u
    }

    private var selectedTarget: TextEditorSelectionTarget {
        .init(paneID: selectionPaneID, selection: selectedURLs)
    }

    private var isDocumentDirty: Bool {
        model.isLarge ? largeController.isDirty : model.isDirty
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Label("テキストエディタ", systemImage: "doc.text").font(.headline)
                if isDocumentDirty { Circle().fill(.orange).frame(width: 7, height: 7).help("未保存") }
                Spacer()
                Button { save() } label: { Image(systemName: "square.and.arrow.down") }.disabled(!isDocumentDirty)
                Button("別名") { saveAs() }.disabled(model.state != .ready || model.isLarge)
                Button(action: requestClose) { Image(systemName: "xmark") }
            }.buttonStyle(.borderless)
            controls
            if model.conflict { conflictBanner }
            Divider()
            content
            status
        }
        .padding(8)
        .frame(minWidth: ModulePanelLayout.textPolicy.minimumWidth,
               idealWidth: effectivePanelWidth,
               maxWidth: effectivePanelWidth,
               alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(.clear).frame(width: 5).contentShape(Rectangle()).gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = (value.startLocation.x, effectivePanelWidth) }
                        if let start = resizeStart {
                            transientWidth = ModulePanelLayout.textPolicy.clamp(start.width + start.x - value.location.x)
                        }
                    }
                    .onEnded { _ in
                        if let width = transientWidth { panelWidth = ModulePanelLayout.normalizedPersistedWidth(width) }
                        transientWidth = nil
                        resizeStart = nil
                    }
            ).onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .onAppear {
            // Migrate widths saved by the earlier 240...800 implementation.
            panelWidth = ModulePanelLayout.normalizedPersistedWidth(panelWidth)
            closeRegistration = closeRouter.install(requestClose)
        }
        .onDisappear { closeRouter.uninstall(closeRegistration); closeRegistration = nil }
        .task {
            documentPaneID = selectionPaneID
            await model.select(selectedFile)
        }
        .onChange(of: selectedTarget) { _, target in handleSelectionTransition(to: target) }
        .task(id: model.url) {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); await model.pollExternalChange() }
        }
        .task(id: model.text) {
            guard autosave, model.isDirty, !model.isLarge else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if let outcome = try? await model.save() { record(outcome) }
        }
        .sheet(isPresented: $showCompare) { TextExternalComparisonView(url: model.url, edited: model.text) }
        .confirmationDialog(
            "変更内容を保存しますか？",
            isPresented: Binding(get: { showsDirtyPrompt }, set: { visible in
                if !visible, transition.isPrompting { cancelTransition() }
            }),
            titleVisibility: .visible
        ) {
            Button("保存") { saveAndContinueTransition() }
            Button("変更を破棄", role: .destructive) { discardAndContinueTransition() }
            Button("キャンセル", role: .cancel) { cancelTransition() }
        } message: {
            Text("\(model.url?.lastPathComponent ?? "このファイル")には保存されていない変更があります。")
        }
        .alert("保存できません", isPresented: Binding(get: { error != nil }, set: {
            if !$0 { error = nil; restoreEditorFocus() }
        })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private var controls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                Picker("文字コード", selection: $model.encoding) { ForEach(TextDocumentEncoding.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 105).onChange(of: model.encoding) { _, value in Task { await model.reload(forced: value) } }
                Picker("改行", selection: $model.newline) { ForEach(TextNewline.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 70)
                Toggle("折返", isOn: $model.wraps).toggleStyle(.button)
                Toggle("空白", isOn: $model.showsInvisibles).toggleStyle(.button)
                Stepper("\(Int(model.fontSize))", value: $model.fontSize, in: 9...28).frame(width: 70)
                Picker("Tab", selection: $model.tabWidth) { Text("2").tag(2); Text("4").tag(4); Text("8").tag(8) }.labelsHidden().frame(width: 55)
                TextField("行", text: $lineInput).frame(width: 45).onSubmit { requestedLine = Int(lineInput) }
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
    }

    private var effectivePanelWidth: CGFloat {
        ModulePanelLayout.textPolicy.clamp(transientWidth ?? panelWidth)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .empty:
            ContentUnavailableView(selectedURLs.count > 1 ? "1つのファイルを選択してください" : "テキストファイルを選択してください", systemImage: "doc.text")
        case .loading: ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            ContentUnavailableView { Label("バイナリファイルです", systemImage: "doc.badge.gearshape") } description: { Text("Hexビューアーで確認できます") } actions: { Button("Hexビューアーを開く", action: openHex) }
        case .failed(let message): ContentUnavailableView("開けません", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if model.isLarge, let url = model.url {
                LargeTextEditorView(url: url, encoding: model.encoding, history: history,
                                    controller: largeController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativePlainTextEditor(text: $model.text, wraps: model.wraps, fontSize: model.fontSize, tabWidth: model.tabWidth, showsInvisibles: model.showsInvisibles,
                    onChange: model.textChanged, onSelection: { model.line = $0; model.column = $1; model.selectionCount = $2 },
                    onSave: { if isDocumentDirty { save() } }, requestedLine: $requestedLine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var conflictBanner: some View {
        HStack { Label("外部で変更されました", systemImage: "exclamationmark.triangle.fill"); Spacer()
            Button("再読み込み") { Task { await model.reload() } }
            Button("上書き") { save(overwriteExternal: true) }
            Button("別名で保存") { saveAs() }
            Button("比較") { showCompare = true }
            Button("キャンセル") { model.dismissConflict() }
        }.font(.caption).padding(5).background(.orange.opacity(0.18))
    }

    private var status: some View {
        HStack { Text("行 \(model.line), 桁 \(model.column)"); if model.selectionCount > 0 { Text("選択 \(model.selectionCount)") }; Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(model.byteCount), countStyle: .file)); Text(model.encoding.rawValue); Text(model.newline.rawValue) }.font(.caption2).foregroundStyle(.secondary)
    }

    private func save(overwriteExternal: Bool = false) {
        Task {
            do { if let outcome = try await saveCurrent(overwriteExternal: overwriteExternal) { record(outcome) } }
            catch { self.error = error.localizedDescription }
        }
    }

    private func saveCurrent(overwriteExternal: Bool = false) async throws -> TextSaveHistoryOutcome? {
        if model.isLarge { return try await largeController.save() }
        return try await model.save(overwriteExternal: overwriteExternal)
    }

    private func handleSelectionTransition(to target: TextEditorSelectionTarget) {
        switch transition.request(currentURL: model.url, currentPaneID: documentPaneID,
                                  isDirty: isDocumentDirty, target: target) {
        case .unchanged, .pendingUpdated, .closeNow:
            break
        case .switchNow(let target):
            switchDocument(to: target)
        case .showPrompt:
            if autosave {
                autoSaveTransitionInFlight = true
                Task { await attemptAutoSaveAndContinue() }
            } else {
                showsDirtyPrompt = true
            }
        }
    }

    private func requestClose() {
        switch transition.requestClose(currentURL: model.url, currentPaneID: documentPaneID,
                                       isDirty: isDocumentDirty) {
        case .closeNow:
            finishClose()
        case .showPrompt:
            if autosave {
                autoSaveTransitionInFlight = true
                Task { await attemptAutoSaveAndContinue() }
            } else {
                showsDirtyPrompt = true
            }
        case .pendingUpdated, .unchanged, .switchNow:
            break
        }
    }

    private func attemptAutoSaveAndContinue() async {
        do {
            if let outcome = try await saveCurrent() { record(outcome) }
            autoSaveTransitionInFlight = false
            continueResolvedTransition()
        } catch {
            autoSaveTransitionInFlight = false
            // An external conflict or write failure needs the user's explicit
            // choice; never discard the in-memory document automatically.
            showsDirtyPrompt = true
        }
    }

    private func saveAndContinueTransition() {
        showsDirtyPrompt = false
        Task {
            do {
                if let outcome = try await saveCurrent() { record(outcome) }
                continueResolvedTransition()
            } catch {
                let restore = transition.cancelOrFail()
                if let restore { restoreSelection(restore.paneID, restore.selection) }
                self.error = error.localizedDescription
            }
        }
    }

    private func discardAndContinueTransition() {
        showsDirtyPrompt = false
        continueResolvedTransition()
    }

    private func cancelTransition() {
        showsDirtyPrompt = false
        guard let restore = transition.cancelOrFail() else { return }
        restoreSelection(restore.paneID, restore.selection)
        restoreEditorFocus()
    }

    private func switchDocument(to target: TextEditorSelectionTarget) {
        documentPaneID = target.paneID
        Task { await model.select(target.textFile) }
    }
    private func continueResolvedTransition() {
        if transition.isClosePending {
            _ = transition.acceptClose()
            finishClose()
        } else if let target = transition.acceptPending() {
            switchDocument(to: target)
        }
    }
    private func finishClose() {
        TextEditorFirstResponderLifecycle.resignEditor(in: NSApp.keyWindow)
        commitClose()
    }
    private func restoreEditorFocus() {
        DispatchQueue.main.async {
            TextEditorFirstResponderLifecycle.focusEditor(in: NSApp.keyWindow)
        }
    }
    private func saveAs() {
        guard let source = model.url else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = source.lastPathComponent; panel.directoryURL = source.deletingLastPathComponent()
        panel.begin { response in if response == .OK, let url = panel.url { Task { do { if let outcome = try await model.save(to: url) { record(outcome) } } catch { self.error = error.localizedDescription } } } }
    }

    private func record(_ outcome: TextSaveHistoryOutcome) {
        let step: HistoryStep
        if let before = outcome.beforeBackup, let after = outcome.afterBackup, let beforeFP = outcome.beforeFingerprint {
            step = .edited(file: outcome.target, beforeBackup: before, afterBackup: after,
                           beforeFingerprint: beforeFP, afterFingerprint: outcome.afterFingerprint)
        } else { step = .created(outcome.target) }
        history.record(.init(kind: .textEdit, summary: "テキストを保存: \(outcome.target.lastPathComponent)",
                             steps: [step], itemCount: 1, byteCount: outcome.byteCount))
    }
}

struct TextExternalComparisonView: View {
    let url: URL?
    let edited: String
    @Environment(\.dismiss) private var dismiss
    @State private var external = "読み込み中…"
    var body: some View {
        VStack {
            HStack { Text("外部版と編集中版の比較").font(.headline); Spacer(); Button("閉じる") { dismiss() } }
            HSplitView {
                VStack { Text("外部版").font(.caption); ScrollView { Text(external).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) } }
                VStack { Text("編集中版").font(.caption); ScrollView { Text(edited).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) } }
            }.font(.system(size: 11, design: .monospaced))
        }.padding().frame(minWidth: 760, minHeight: 480)
        .task { if let url { external = await Task.detached { (try? TextModuleIO.load(url).text) ?? "比較できません" }.value } }
    }
}
