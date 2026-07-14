import AppKit
import Foundation

@MainActor
final class PaneBrowserModel: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: UserFacingError?

    let paneID: UUID
    private let fileSystem: FileSystemService
    private var loadTask: Task<Void, Never>?
    private var changeReloadTask: Task<Void, Never>?
    private var changeReloadPending = false
    private var latestChangeRequest: (url: URL, showsHiddenFiles: Bool, bookmark: Data?)?
    private var observedURL: URL?
    private var loadGeneration = UUID()

    init(paneID: UUID, fileSystem: FileSystemService = FileSystemService()) {
        self.paneID = paneID
        self.fileSystem = fileSystem
    }

    func load(url: URL, showsHiddenFiles: Bool, bookmark: Data?, bypassCache: Bool = false) {
        if observedURL.map({ !FileURLIdentity.isSame($0, url) }) ?? true { items = [] }
        observedURL = url
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadError = nil
        loadTask = Task {
            var scopedURL: URL?
            var startedSecurityScope = false
            defer {
                if startedSecurityScope { scopedURL?.stopAccessingSecurityScopedResource() }
                if loadGeneration == generation { isLoading = false }
            }
            do {
                if let bookmark {
                    scopedURL = try FileSystemService.resolveBookmark(bookmark)
                    startedSecurityScope = scopedURL?.startAccessingSecurityScopedResource() == true
                }
                let result = try await fileSystem.listDirectory(url, showsHiddenFiles: showsHiddenFiles, bypassCache: bypassCache)
                guard !Task.isCancelled, observedURL.map({ FileURLIdentity.isSame($0, url) }) == true,
                      loadGeneration == generation else { return }
                items = result
            } catch is CancellationError {
                // Cancellation is expected when this pane navigates again.
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                loadError = UserFacingError(title: L10n.tr("フォルダを開けません"), message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        loadGeneration = UUID()
        changeReloadTask?.cancel()
        changeReloadTask = nil
        changeReloadPending = false
        latestChangeRequest = nil
        loadTask?.cancel()
        isLoading = false
    }

    /// Coalesces filesystem bursts without leaving the two-second listing
    /// cache visible. Internal operation notifications and external FSEvents
    /// share this path so both refresh with identical ordering guarantees.
    func reloadAfterDirectoryChange(url: URL, showsHiddenFiles: Bool, bookmark: Data?) {
        guard observedURL.map({ FileURLIdentity.isSame($0, url) }) == true else { return }
        latestChangeRequest = (url, showsHiddenFiles, bookmark)
        changeReloadPending = true
        guard changeReloadTask == nil else { return }
        changeReloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.changeReloadTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let request = self.latestChangeRequest,
                      self.observedURL.map({ FileURLIdentity.isSame($0, request.url) }) == true else { return }
                self.changeReloadPending = false
                await self.fileSystem.invalidateListing(for: request.url)
                guard !Task.isCancelled else { return }
                self.load(url: request.url, showsHiddenFiles: request.showsHiddenFiles,
                          bookmark: request.bookmark, bypassCache: true)
                let activeLoad = self.loadTask
                await activeLoad?.value
                // Never cancel an in-progress directory read. Events received
                // during it request one more pass, so the final snapshot wins.
                if !self.changeReloadPending { return }
            }
        }
    }

    deinit { loadTask?.cancel(); changeReloadTask?.cancel() }
}
