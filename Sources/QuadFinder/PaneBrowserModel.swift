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
    private var observedURL: URL?
    private var loadGeneration = UUID()

    init(paneID: UUID, fileSystem: FileSystemService = FileSystemService()) {
        self.paneID = paneID
        self.fileSystem = fileSystem
    }

    func load(url: URL, showsHiddenFiles: Bool, bookmark: Data?, bypassCache: Bool = false) {
        if observedURL != url { items = [] }
        observedURL = url
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        loadTask = Task {
            isLoading = true
            loadError = nil
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
                guard !Task.isCancelled, observedURL == url, loadGeneration == generation else { return }
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
        loadTask?.cancel()
        isLoading = false
    }

    deinit { loadTask?.cancel() }
}
