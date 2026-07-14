import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ImagePreviewSupport {
    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func firstSupported(in urls: Set<URL>) -> URL? {
        urls.sorted { $0.path < $1.path }.first(where: isSupported)
    }
}

struct ImagePreviewDecoded: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImagePreviewLoadError: LocalizedError, Equatable {
    case unsupported
    case cannotOpen
    case cannotDecode

    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.tr("対応している画像を選択してください")
        case .cannotOpen: L10n.tr("画像ファイルを開けません")
        case .cannotDecode: L10n.tr("画像を表示できません")
        }
    }
}

enum ImagePreviewLoader {
    /// ImageIO creates a bounded thumbnail directly from the source. It never
    /// asks AppKit to synchronously decode the full-resolution image.
    static func load(url: URL, maxPixel: Int) throws -> ImagePreviewDecoded {
        guard ImagePreviewSupport.isSupported(url) else { throw ImagePreviewLoadError.unsupported }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImagePreviewLoadError.cannotOpen
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImagePreviewLoadError.cannotDecode
        }
        return ImagePreviewDecoded(
            image: thumbnail,
            pixelWidth: width > 0 ? width : thumbnail.width,
            pixelHeight: height > 0 ? height : thumbnail.height
        )
    }
}

@MainActor
final class ImagePreviewModel: ObservableObject {
    typealias Loader = @Sendable (URL, Int) async throws -> ImagePreviewDecoded
    typealias ModificationDateProvider = (URL) -> Date?
    enum State {
        case empty
        case unsupported
        case loading
        case loaded(ImagePreviewDecoded)
        case failed(String)
    }

    @Published private(set) var state: State = .empty
    @Published var zoom: CGFloat = 1
    @Published var fitsWindow = true
    private(set) var url: URL?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var modificationDate: Date?
    private let loader: Loader
    private let modificationDateProvider: ModificationDateProvider

    init(
        loader: @escaping Loader = { url, maxPixel in
            try await Task.detached(priority: .userInitiated) {
                try ImagePreviewLoader.load(url: url, maxPixel: maxPixel)
            }.value
        },
        modificationDateProvider: @escaping ModificationDateProvider = { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    ) {
        self.loader = loader
        self.modificationDateProvider = modificationDateProvider
    }

    deinit { loadTask?.cancel() }

    func select(_ url: URL?, maxPixel: Int) {
        generation += 1
        let requestGeneration = generation
        loadTask?.cancel()
        self.url = url
        zoom = 1
        fitsWindow = true
        guard let url else {
            state = .empty
            modificationDate = nil
            return
        }
        guard ImagePreviewSupport.isSupported(url) else {
            state = .unsupported
            modificationDate = nil
            return
        }
        state = .loading
        modificationDate = modificationDateProvider(url)
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<ImagePreviewDecoded, Error>
            do { result = .success(try await loader(url, maxPixel)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            switch result {
            case .success(let decoded): self.state = .loaded(decoded)
            case .failure(let error): self.state = .failed(error.localizedDescription)
            }
        }
    }

    func reloadIfChanged(maxPixel: Int) {
        guard let url else { return }
        let current = modificationDateProvider(url)
        guard current != modificationDate else { return }
        select(url, maxPixel: maxPixel)
    }

    func showActualSize() { fitsWindow = false; zoom = 1 }
    func fit() { fitsWindow = true; zoom = 1 }
    func zoomIn() { fitsWindow = false; zoom = min(zoom * 1.25, 8) }
    func zoomOut() { fitsWindow = false; zoom = max(zoom / 1.25, 0.1) }

}

struct ImagePreviewModuleView: View {
    let pane: PaneState?
    let onClose: () -> Void
    @StateObject private var model = ImagePreviewModel()

    private var imageURL: URL? {
        pane.flatMap {
            ImagePreviewSupport.firstSupported(in: $0.selectedURLs)
                ?? $0.selectedURLs.sorted(by: { $0.path < $1.path }).first
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(L10n.tr("画像表示"), systemImage: "photo").font(.headline)
                Spacer()
                Button { model.fit() } label: { Text(L10n.tr("全体")) }.help(L10n.tr("ウインドウに合わせる"))
                Button { model.showActualSize() } label: { Text(L10n.tr("100%")) }.help(L10n.tr("実寸表示"))
                Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                Button(action: onClose) { Image(systemName: "xmark") }.help(L10n.tr("画像表示を閉じる"))
            }
            .buttonStyle(.borderless)
            Divider()
            GeometryReader { proxy in
                imageContent(size: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: imageURL) {
                        model.select(imageURL, maxPixel: thumbnailLimit(for: proxy.size))
                    }
                    .task(id: imageURL) {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            model.reloadIfChanged(maxPixel: thumbnailLimit(for: proxy.size))
                        }
                    }
            }
            footer
        }
        .padding(10)
        .frame(minWidth: ModulePanelLayout.imagePolicy.minimumWidth,
               idealWidth: ModulePanelLayout.imagePolicy.idealWidth,
               maxWidth: ModulePanelLayout.imagePolicy.maximumWidth,
               alignment: .topLeading)
        .background(.regularMaterial)
    }

    @ViewBuilder private func imageContent(size: CGSize) -> some View {
        switch model.state {
        case .empty:
            ContentUnavailableView(L10n.tr("画像を選択してください"), systemImage: "photo")
        case .unsupported:
            ContentUnavailableView(L10n.tr("対応している画像を選択してください"), systemImage: "photo.badge.exclamationmark")
        case .loading:
            ProgressView(L10n.tr("画像を読み込み中…"))
        case .failed(let message):
            ContentUnavailableView(L10n.tr("画像を表示できません"), systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let decoded):
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: decoded.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: model.fitsWindow ? size.width : CGFloat(decoded.image.width) * model.zoom,
                        height: model.fitsWindow ? size.height : CGFloat(decoded.image.height) * model.zoom
                    )
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let url = model.url {
            HStack {
                Text(url.lastPathComponent).lineLimit(1)
                Spacer()
                if case .loaded(let decoded) = model.state {
                    Text(L10n.format("%1$lld × %2$lld px", Int64(decoded.pixelWidth), Int64(decoded.pixelHeight)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(url.path(percentEncoded: false))
        }
    }

    private func thumbnailLimit(for size: CGSize) -> Int {
        min(8192, max(512, Int(max(size.width, size.height) * 2)))
    }
}
