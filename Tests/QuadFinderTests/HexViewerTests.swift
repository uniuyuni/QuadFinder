import Foundation
import AppKit
import Testing
@testable import QuadFinder

struct HexViewerTests {
    @Test func formatsAddressHexAndPrintableASCII() {
        let data = Data([0x00, 0x20, 0x41, 0x7e, 0x7f, 0xff])
        let rendered = HexFormatter.string(data: data, startingAt: 0x20)
        #expect(rendered.hasPrefix("00000020  00 20 41 7E 7F FF"))
        #expect(rendered.hasSuffix("|. A~..|"))
    }

    @Test func formatsMultipleLinesWithAbsoluteOffsets() {
        let rendered = HexFormatter.string(data: Data(0..<20), startingAt: 0x100)
        let lines = rendered.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00000100"))
        #expect(lines[1].hasPrefix("00000110"))
    }

    @Test func supportsEightAndThirtyTwoByteRows() {
        let data = Data(0..<32)
        #expect(HexFormatter.string(data: data, startingAt: 0, bytesPerLine: 8).split(separator: "\n").count == 4)
        #expect(HexFormatter.string(data: data, startingAt: 0, bytesPerLine: 32).split(separator: "\n").count == 1)
    }

    @Test func fullRowsUseFormatterTextAsTheLayoutSourceOfTruth() {
        for bytes in [8, 16, 32] {
            let expected = HexFormatter.rows(
                data: Data(repeating: 0xff, count: bytes), startingAt: 0,
                bytesPerLine: bytes
            )[0].hex
            #expect(HexColumnLayout.longestHexText(bytesPerLine: bytes) == expected)
            #expect(expected.split(separator: " ", omittingEmptySubsequences: true).count == bytes)
            #expect(expected.hasSuffix("FF"))
        }
    }

    @Test func measuredColumnsContainEveryFullRowIncludingLastByte() {
        for fontSize: CGFloat in [9, 11, 13, 15] {
            for bytes in [8, 16, 32] {
                let layout = HexColumnLayout.calculate(
                    availableWidth: 0, bytesPerLine: bytes,
                    usesWideAddress: false, fontSize: fontSize
                )
                let fullRow = HexColumnLayout.longestHexText(bytesPerLine: bytes)
                let rawWidth = (fullRow as NSString).size(withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                ]).width
                #expect(rawWidth < layout.hex)
            }
        }
    }

    @Test func partialFinalRowNeverNeedsMoreWidthThanFullRow() {
        for bytes in [8, 16, 32] {
            let rows = HexFormatter.rows(
                data: Data(repeating: 0xab, count: bytes + bytes - 1),
                startingAt: 0, bytesPerLine: bytes
            )
            #expect(rows.count == 2)
            #expect(rows[1].hex.count < rows[0].hex.count)
            #expect(rows[1].hex.hasSuffix("AB"))
        }
    }

    @Test func columnLayoutLeavesWideViewportSlackAfterASCII() {
        let layout = HexColumnLayout.calculate(availableWidth: 900, bytesPerLine: 16, usesWideAddress: false)
        #expect(layout.contentWidth == 900)
        #expect(layout.requiredWidth == layout.address + layout.hex + layout.ascii + layout.spacing * 2)
        #expect(layout.asciiEnd == layout.requiredWidth)
        #expect(layout.asciiEnd <= 900)
        #expect(layout.trailingSlack == 900 - layout.requiredWidth)
        #expect(layout.spacing == 8)
    }

    @Test func columnLayoutUsesHorizontalOverflowWhenViewportIsTooNarrow() {
        let layout = HexColumnLayout.calculate(availableWidth: 220, bytesPerLine: 32, usesWideAddress: true)
        #expect(layout.contentWidth > 220)
        #expect(layout.requiredWidth == layout.contentWidth)
        #expect(layout.asciiEnd == layout.contentWidth)
    }

    @Test func columnOriginsAndGapsAreStableForAllRowWidths() {
        for bytes in [8, 16, 32] {
            let layout = HexColumnLayout.calculate(availableWidth: 2_000, bytesPerLine: bytes,
                                                   usesWideAddress: false)
            #expect(layout.hexOrigin - layout.address == 8)
            #expect(layout.asciiOrigin - (layout.hexOrigin + layout.hex) == 8)
            #expect(layout.trailingSlack > 0)
        }
    }

    @Test func wideAddressAndFontSizeUseMeasuredMonospacedMetrics() {
        let narrow = HexColumnLayout.calculate(availableWidth: 0, bytesPerLine: 16,
                                               usesWideAddress: false, fontSize: 11)
        let wide = HexColumnLayout.calculate(availableWidth: 0, bytesPerLine: 16,
                                             usesWideAddress: true, fontSize: 11)
        let large = HexColumnLayout.calculate(availableWidth: 0, bytesPerLine: 16,
                                              usesWideAddress: true, fontSize: 15)
        #expect(wide.address > narrow.address)
        #expect(large.address > wide.address)
        #expect(large.hex > wide.hex)
        #expect(large.ascii > wide.ascii)
    }

    @Test func sideModuleNeverConsumesThePaneGrid() {
        let available: CGFloat = 520
        let width = ModulePanelLayout.moduleWidth(availableWidth: available)
        #expect(width == 320)
        #expect(available - width - 1 >= 180)
        #expect(width <= ModulePanelLayout.maximumWidth)
    }

    @Test func sideModuleShrinksBeforeHidingPaneInANarrowWindow() {
        let available: CGFloat = 360
        let width = ModulePanelLayout.moduleWidth(availableWidth: available)
        #expect(width == 179)
        #expect(available - width - 1 == 180)
    }

    @Test func sideModuleHasAFiniteMaximumInAWideWindow() {
        let width = ModulePanelLayout.moduleWidth(availableWidth: 2_000)
        #expect(width == ModulePanelLayout.idealWidth)
        #expect(ModulePanelLayout.maximumWidth.isFinite)
    }

    @Test func readsBoundedPagesAndReportsNextOffset() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((0..<100).map(UInt8.init)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = HexPageReader()
        let first = try await reader.page(url: url, offset: 10, count: 16)
        #expect(first.data == Data((10..<26).map(UInt8.init)))
        #expect(first.fileSize == 100)
        #expect(first.nextOffset == 26)
        let end = try await reader.page(url: url, offset: 96, count: 16)
        #expect(end.data.count == 4)
        #expect(end.nextOffset == nil)
    }

    @Test func clampsReadsAndBoundsLRUCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0xaa, count: HexPageReader.maximumPageSize + 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = HexPageReader(cacheLimit: 2)
        let bounded = try await reader.page(url: url, offset: 0, count: Int.max)
        #expect(bounded.data.count == HexPageReader.maximumPageSize)
        _ = try await reader.page(url: url, offset: 1, count: 8)
        _ = try await reader.page(url: url, offset: 2, count: 8)
        #expect(await reader.cachedPageCount() == 2)
    }

    @Test func sparseHugeFileStillReadsOnlyRequestedPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 * 1_024)
        try handle.close()
        let page = try await HexPageReader().page(url: url, offset: 7 * 1_024 * 1_024 * 1_024, count: 4_096)
        #expect(page.fileSize == 8 * 1_024 * 1_024 * 1_024)
        #expect(page.data.count == 4_096)
    }

    @Test func modificationFingerprintInvalidatesCachedPage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = HexPageReader()
        #expect(try await reader.page(url: url, offset: 0).data == Data([1, 2, 3]))
        try Data([9, 8, 7]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        #expect(try await reader.page(url: url, offset: 0).data == Data([9, 8, 7]))
    }
}
