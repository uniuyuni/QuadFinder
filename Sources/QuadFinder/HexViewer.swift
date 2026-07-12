import Foundation
import AppKit
import SwiftUI

struct HexPage: Equatable, Sendable {
    let url: URL
    let offset: UInt64
    let fileSize: UInt64
    let data: Data

    var nextOffset: UInt64? {
        let next = offset + UInt64(data.count)
        return next < fileSize ? next : nil
    }
}

actor HexPageReader {
    static let defaultPageSize = 4_096
    static let maximumPageSize = 64 * 1_024

    private struct Key: Hashable {
        let url: URL; let offset: UInt64; let count: Int
        let fileSize: UInt64; let modificationTime: TimeInterval
    }
    private var cache: [Key: HexPage] = [:]
    private var recency: [Key] = []
    private let cacheLimit: Int

    init(cacheLimit: Int = 8) { self.cacheLimit = max(1, cacheLimit) }

    func page(url: URL, offset: UInt64, count requestedCount: Int = defaultPageSize) throws -> HexPage {
        let count = min(max(1, requestedCount), Self.maximumPageSize)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let safeOffset = min(offset, fileSize)
        let key = Key(url: url.standardizedFileURL, offset: safeOffset, count: count,
                      fileSize: fileSize, modificationTime: modificationTime)
        if let cached = cache[key] { touch(key); return cached }

        let usesScope = AppSecurityEnvironment.current.isSandboxed && url.startAccessingSecurityScopedResource()
        defer { if usesScope { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: safeOffset)
        let data = try handle.read(upToCount: count) ?? Data()
        let result = HexPage(url: url, offset: safeOffset, fileSize: fileSize, data: data)
        cache[key] = result
        touch(key)
        while recency.count > cacheLimit, let oldest = recency.first {
            recency.removeFirst(); cache.removeValue(forKey: oldest)
        }
        return result
    }

    func cachedPageCount() -> Int { cache.count }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

enum HexFormatter {
    struct Row: Equatable, Sendable {
        let address: String
        let hex: String
        let ascii: String
    }

    static func rows(data: Data, startingAt baseOffset: UInt64, bytesPerLine: Int = 16) -> [Row] {
        guard !data.isEmpty else { return [] }
        let addressWidth = baseOffset + UInt64(data.count) > UInt64(UInt32.max) ? 16 : 8
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: bytesPerLine).map { start in
            let slice = bytes[start..<min(start + bytesPerLine, bytes.count)]
            return Row(
                address: String(format: "%0*llX", addressWidth, baseOffset + UInt64(start)),
                hex: slice.enumerated().map { index, byte in
                    let value = String(format: "%02X", byte)
                    return index > 0 && index.isMultiple(of: 8) ? "  \(value)" : value
                }.joined(separator: " "),
                ascii: slice.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            )
        }
    }

    static func string(data: Data, startingAt baseOffset: UInt64, bytesPerLine: Int = 16) -> String {
        rows(data: data, startingAt: baseOffset, bytesPerLine: bytesPerLine).map { row in
            let hex = row.hex
                .padding(toLength: bytesPerLine * 3 - 1, withPad: " ", startingAt: 0)
            return "\(row.address)  \(hex)  |\(row.ascii)|"
        }.joined(separator: "\n")
    }
}

/// Sizes columns from their character counts. Extra viewport width deliberately
/// remains after ASCII instead of being distributed between the columns.
struct HexColumnLayout: Equatable, Sendable {
    let address: CGFloat
    let hex: CGFloat
    let ascii: CGFloat
    let spacing: CGFloat
    let requiredWidth: CGFloat
    let contentWidth: CGFloat

    var hexOrigin: CGFloat { address + spacing }
    var asciiOrigin: CGFloat { hexOrigin + hex + spacing }
    var asciiEnd: CGFloat { asciiOrigin + ascii }
    var trailingSlack: CGFloat { contentWidth - requiredWidth }

    /// Returns the exact longest text emitted by `HexFormatter` for one full
    /// row.  Keeping this here avoids a second, subtly different separator
    /// formula in the layout code.
    static func longestHexText(bytesPerLine: Int) -> String {
        HexFormatter.rows(
            data: Data(repeating: 0xFF, count: max(1, bytesPerLine)),
            startingAt: 0,
            bytesPerLine: max(1, bytesPerLine)
        ).first?.hex ?? ""
    }

    static func measuredWidth(of text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // SwiftUI can place a glyph on a fractional backing-pixel boundary.
        // Ceil the actual run advance and retain one point of breathing room;
        // exact-fit Text frames otherwise wrap the final byte on some scales.
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    static func calculate(availableWidth: CGFloat, bytesPerLine: Int,
                          usesWideAddress: Bool, fontSize: CGFloat = 11) -> Self {
        let spacing: CGFloat = 8
        let addressCharacters = usesWideAddress ? 16 : 8
        let address = measuredWidth(of: String(repeating: "F", count: addressCharacters), fontSize: fontSize)
        let hex = measuredWidth(of: longestHexText(bytesPerLine: bytesPerLine), fontSize: fontSize)
        let ascii = measuredWidth(of: String(repeating: "W", count: max(1, bytesPerLine)), fontSize: fontSize)
        let requiredWidth = address + spacing + hex + spacing + ascii
        let contentWidth = max(availableWidth, requiredWidth)
        return Self(address: address, hex: hex, ascii: ascii, spacing: spacing,
                    requiredWidth: requiredWidth, contentWidth: contentWidth)
    }
}

@MainActor
final class HexViewerController: ObservableObject {
    @Published private(set) var page: HexPage?
    @Published private(set) var rendered = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let reader: HexPageReader
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(reader: HexPageReader = HexPageReader()) { self.reader = reader }
    deinit { task?.cancel() }

    func load(url: URL?, offset: UInt64 = 0) {
        task?.cancel(); page = nil; rendered = ""; errorMessage = nil
        generation = UUID()
        let currentGeneration = generation
        guard let url else { isLoading = false; return }
        isLoading = true
        task = Task {
            defer { if generation == currentGeneration { isLoading = false } }
            do {
                let loaded = try await reader.page(url: url, offset: offset)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                page = loaded
                rendered = HexFormatter.string(data: loaded.data, startingAt: loaded.offset)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rerender(bytesPerLine: Int) {
        guard let page else { return }
        rendered = HexFormatter.string(data: page.data, startingAt: page.offset, bytesPerLine: bytesPerLine)
    }
}

struct HexViewerModuleView: View {
    @StateObject private var controller = HexViewerController()
    @State private var offsetText = "0"
    @State private var bytesPerLine = 16
    let selectedURLs: Set<URL>
    let onClose: () -> Void

    private var selectedFile: URL? {
        selectedURLs.sorted { $0.path < $1.path }.first(where: {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Hexビューアー", systemImage: "number.square") .font(.headline)
                if let page = controller.page {
                    Text("\(page.offset)–\(page.offset + UInt64(page.data.count)) / \(page.fileSize) bytes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("行", selection: $bytesPerLine) {
                    Text("8").tag(8); Text("16").tag(16); Text("32").tag(32)
                }
                .pickerStyle(.segmented).frame(width: 110).help("1行あたりのバイト数")
                TextField("オフセット", text: $offsetText)
                    .frame(width: 90).font(.system(.caption, design: .monospaced))
                    .onSubmit { goToOffset() }
                Button("移動") { goToOffset() }
                Button("前へ") { if let page = controller.page { controller.load(url: selectedFile, offset: page.offset >= 4_096 ? page.offset - 4_096 : 0) } }
                    .disabled(controller.page?.offset == 0 || controller.isLoading)
                Button("次へ") { if let next = controller.page?.nextOffset { controller.load(url: selectedFile, offset: next) } }
                    .disabled(controller.page?.nextOffset == nil || controller.isLoading)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            if controller.isLoading { ProgressView().controlSize(.small) }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if selectedFile == nil {
                ContentUnavailableView("ファイルを選択してください", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    let layout = HexColumnLayout.calculate(
                        availableWidth: max(0, viewport.size.width),
                        bytesPerLine: bytesPerLine,
                        usesWideAddress: (controller.page?.fileSize ?? 0) > UInt64(UInt32.max)
                    )
                    ScrollView([.horizontal, .vertical]) {
                        if let page = controller.page, !page.data.isEmpty {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: layout.spacing) {
                                    singleLine("ADDRESS", width: layout.address)
                                    singleLine("HEX", width: layout.hex)
                                    singleLine("ASCII", width: layout.ascii)
                                }
                                .foregroundStyle(.secondary)
                                .frame(width: layout.contentWidth, alignment: .leading)
                                ForEach(Array(HexFormatter.rows(data: page.data,
                                                               startingAt: page.offset,
                                                               bytesPerLine: bytesPerLine).enumerated()), id: \.offset) { _, row in
                                    HStack(alignment: .firstTextBaseline, spacing: layout.spacing) {
                                        singleLine(row.address, width: layout.address)
                                        singleLine(row.hex, width: layout.hex)
                                        singleLine(row.ascii, width: layout.ascii)
                                    }
                                    .frame(width: layout.contentWidth, alignment: .leading)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(width: layout.contentWidth, alignment: .topLeading)
                        } else if !controller.isLoading {
                            Text("空のファイル")
                                .frame(width: layout.contentWidth, alignment: .topLeading)
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
        }
        .padding(8)
        // This is a side module, just like ImagePreviewModuleView.  Do not ask
        // for all of the parent HStack's width or give the module a higher
        // layout priority: either makes SwiftUI compress PaneGridView to zero.
        // The GeometryReader and its scroll view still fill the width assigned
        // to this module, while narrow content scrolls horizontally.
        .frame(minWidth: ModulePanelLayout.minimumWidth,
               idealWidth: ModulePanelLayout.idealWidth,
               maxWidth: ModulePanelLayout.maximumWidth,
               alignment: .topLeading)
        .background(.regularMaterial)
        .task(id: selectedFile) { controller.load(url: selectedFile) }
        .onChange(of: bytesPerLine) { _, value in controller.rerender(bytesPerLine: value) }
        .onChange(of: controller.page?.offset) { _, value in
            if let value {
                offsetText = String(format: "0x%llX", value)
                controller.rerender(bytesPerLine: bytesPerLine)
            }
        }
    }

    private func goToOffset() {
        let input = offsetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: UInt64?
        if input.lowercased().hasPrefix("0x") { value = UInt64(input.dropFirst(2), radix: 16) }
        else { value = UInt64(input) }
        if let value { controller.load(url: selectedFile, offset: value) }
    }

    private func singleLine(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width, alignment: .leading)
    }
}

/// Shared side-module sizing contract.  A finite maximum prevents a module
/// from consuming the pane grid when the window is narrow.
enum ModulePanelLayout {
    static let minimumWidth: CGFloat = 240
    static let idealWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 560

    /// Deterministic allocation used by tests and by future split-view work.
    /// The pane always keeps its minimum before a side module is expanded.
    static func moduleWidth(availableWidth: CGFloat,
                            dividerWidth: CGFloat = 1,
                            paneMinimumWidth: CGFloat = 180) -> CGFloat {
        let room = max(0, availableWidth - dividerWidth - paneMinimumWidth)
        return min(maximumWidth, max(0, min(idealWidth, room)))
    }
}
