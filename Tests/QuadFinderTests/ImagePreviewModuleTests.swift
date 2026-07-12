import Foundation
import AppKit
import Testing
@testable import QuadFinder

struct ImagePreviewModuleTests {
    @Test func recognizesCommonAndModernImageTypes() {
        #expect(ImagePreviewSupport.isSupported(URL(fileURLWithPath: "/tmp/photo.jpg")))
        #expect(ImagePreviewSupport.isSupported(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(ImagePreviewSupport.isSupported(URL(fileURLWithPath: "/tmp/photo.heic")))
        #expect(!ImagePreviewSupport.isSupported(URL(fileURLWithPath: "/tmp/readme.txt")))
        #expect(!ImagePreviewSupport.isSupported(URL(fileURLWithPath: "/tmp/no-extension")))
    }

    @Test func choosesFirstSupportedSelectionInStablePathOrder() {
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/z.png"),
            URL(fileURLWithPath: "/tmp/readme.txt"),
            URL(fileURLWithPath: "/tmp/a.jpg")
        ]
        #expect(ImagePreviewSupport.firstSupported(in: urls)?.lastPathComponent == "a.jpg")
        #expect(ImagePreviewSupport.firstSupported(in: [URL(fileURLWithPath: "/tmp/a.txt")]) == nil)
    }

    @Test func imageIOLoaderBoundsThumbnailAndPreservesSourceDimensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.png")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)

        let decoded = try ImagePreviewLoader.load(url: url, maxPixel: 200)

        #expect(decoded.pixelWidth == 1000)
        #expect(decoded.pixelHeight == 500)
        #expect(max(decoded.image.width, decoded.image.height) <= 200)
    }

    @Test @MainActor func zoomModesAreBoundedAndExplicit() {
        let model = ImagePreviewModel()
        model.zoomOut()
        #expect(!model.fitsWindow)
        #expect(model.zoom < 1)
        for _ in 0..<100 { model.zoomOut() }
        #expect(model.zoom == 0.1)
        model.fit()
        #expect(model.fitsWindow)
        model.showActualSize()
        #expect(!model.fitsWindow)
        #expect(model.zoom == 1)
        for _ in 0..<100 { model.zoomIn() }
        #expect(model.zoom == 8)
    }

    @Test @MainActor func staleAsynchronousResultCannotReplaceNewSelection() async throws {
        let model = ImagePreviewModel(loader: { url, _ in
            if url.lastPathComponent == "slow.png" { try await Task.sleep(for: .milliseconds(120)) }
            else { try await Task.sleep(for: .milliseconds(10)) }
            return try Self.decoded(width: url.lastPathComponent == "slow.png" ? 10 : 20)
        })
        model.select(URL(fileURLWithPath: "/tmp/slow.png"), maxPixel: 100)
        model.select(URL(fileURLWithPath: "/tmp/fast.png"), maxPixel: 100)
        for _ in 0..<100 {
            if case .loaded = model.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .loaded(let decoded) = model.state else {
            Issue.record("new selection did not load")
            return
        }
        #expect(decoded.pixelWidth == 20)
    }

    @Test @MainActor func changedModificationDateTriggersReload() async throws {
        let counter = PreviewLoadCounter()
        var modificationDate = Date(timeIntervalSince1970: 1)
        let model = ImagePreviewModel(
            loader: { _, _ in
                await counter.increment()
                return try Self.decoded(width: 20)
            },
            modificationDateProvider: { _ in modificationDate }
        )
        let url = URL(fileURLWithPath: "/tmp/reload.png")
        model.select(url, maxPixel: 100)
        try await waitForCount(1, counter: counter)
        #expect(await counter.value == 1)
        model.reloadIfChanged(maxPixel: 100)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await counter.value == 1)
        modificationDate = Date(timeIntervalSince1970: 2)
        model.reloadIfChanged(maxPixel: 100)
        try await waitForCount(2, counter: counter)
        #expect(await counter.value == 2)
    }

    private func waitForCount(_ expected: Int, counter: PreviewLoadCounter) async throws {
        for _ in 0..<50 {
            if await counter.value == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func decoded(width: Int) throws -> ImagePreviewDecoded {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: 10, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return ImagePreviewDecoded(image: try #require(context.makeImage()), pixelWidth: width, pixelHeight: 10)
    }
}

private actor PreviewLoadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
