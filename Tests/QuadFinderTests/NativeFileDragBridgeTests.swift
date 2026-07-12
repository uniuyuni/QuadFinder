import AppKit
import Testing
import UniformTypeIdentifiers
@testable import QuadFinder

@Suite("Native file drag bridge")
struct NativeFileDragBridgeTests {
    @Test func pasteboardIncludesNativeURLAndPrivatePayload() throws {
        let payload = PaneFileDragPayload(sourcePaneID: UUID(), url: URL(fileURLWithPath: "/tmp/example"))
        let item = NativeFileDragPasteboard.item(for: payload)
        #expect(item.types.contains(.fileURL))
        #expect(item.types.contains(NativeFileDragPasteboard.paneItemType))
        #expect(item.string(forType: .fileURL) == payload.url.absoluteString)
        let data = try #require(item.data(forType: NativeFileDragPasteboard.paneItemType))
        #expect(try JSONDecoder().decode(PaneFileDragPayload.self, from: data).url == payload.url)
    }

    @Test func singleAndMultipleSelectionRoundTripEveryNativeItem() throws {
        let paneID = UUID()
        for count in [1, 3] {
            let payloads = (0..<count).map {
                PaneFileDragPayload(sourcePaneID: paneID, url: URL(fileURLWithPath: "/tmp/item-\($0)"))
            }
            let items = NativeFileDragPasteboard.items(for: payloads)
            #expect(items.count == count)
            #expect(items.allSatisfy { $0.types.contains(.fileURL) })
            let decoded = NativeFileDragPasteboard.payloads(from: items)
            #expect(decoded.map(\.url) == payloads.map(\.url))
            #expect(decoded.allSatisfy { $0.sourcePaneID == paneID })
        }
    }

    @Test func hitTestedBatchProviderRoundTripsAllInternalURLs() async throws {
        let paneID = UUID()
        let payloads = (0..<3).map { PaneFileDragPayload(sourcePaneID: paneID, url: URL(fileURLWithPath: "/tmp/batch-\($0)")) }
        let provider = PaneDragItemProvider.makeBatch(payloads)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.quadFinderPaneBatch.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        let decoded = try JSONDecoder().decode(PaneFileDragBatchPayload.self, from: data)
        #expect(decoded.payloads.map(\.url) == payloads.map(\.url))
    }

    @Test func operationMasksRespectContextAndLinkModifier() {
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: false, modifiers: []) == [.copy, .move, .link, .delete])
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: true, modifiers: []) == [.copy, .move, .link])
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: true, modifiers: [.option]) == .copy)
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: true, modifiers: [.command]) == .move)
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: false, modifiers: [.command, .option]) == .link)
        #expect(NativeFileDragOperationPolicy.mask(isInsideApplication: true, modifiers: [.command, .option]) == .link)
    }

    @Test func finderDestinationSemanticsMatchVolumeAndModifiers() {
        #expect(FinderDragOperationPolicy.operation(modifiers: [], sameVolume: true) == .move)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.option], sameVolume: true) == .copy)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command, .option], sameVolume: true) == .link)
        #expect(FinderDragOperationPolicy.operation(modifiers: [], sameVolume: false) == .copy)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command], sameVolume: false) == .move)
        #expect(FinderDragOperationPolicy.operation(modifiers: [.command, .option], sameVolume: false) == .link)
    }

    @Test func volumeComparisonRequiresEverySourceOnTargetVolume() {
        let sources = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let target = URL(fileURLWithPath: "/target")
        let ids: [String: AnyHashable] = ["/a": 1, "/b": 1, "/target": 1]
        #expect(FinderDragOperationPolicy.sameVolume(sourceURLs: sources, targetDirectory: target,
            resourceValues: { ids[$0.path] }))
        let mixed: [String: AnyHashable] = ["/a": 1, "/b": 2, "/target": 1]
        #expect(!FinderDragOperationPolicy.sameVolume(sourceURLs: sources, targetDirectory: target,
            resourceValues: { mixed[$0.path] }))
    }

}
