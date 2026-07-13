import Foundation
import Testing
@testable import QuadFinder

struct LargeTextStorageTests {
    private func temporaryFile(_ data: Data = Data()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @Test func pageReaderAlignsReadsAndBoundsCacheByBytes() async throws {
        let data = Data((0..<(LargeTextPageReader.pageSize * 4)).map { UInt8($0 & 0xff) })
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = LargeTextPageReader(cacheByteLimit: LargeTextPageReader.pageSize * 2)
        let page = try await reader.page(url: url, containing: 123)
        #expect(page.count == LargeTextPageReader.pageSize)
        #expect(page[123] == data[123])
        _ = try await reader.page(url: url, containing: UInt64(LargeTextPageReader.pageSize + 7))
        _ = try await reader.page(url: url, containing: UInt64(LargeTextPageReader.pageSize * 2 + 7))
        let stats = await reader.currentStatistics()
        #expect(stats.cachedPages == 2)
        #expect(stats.cachedBytes <= LargeTextPageReader.pageSize * 2)
        #expect(stats.diskBytesRead == UInt64(LargeTextPageReader.pageSize * 3))
    }

    @Test func readerCombinesUnalignedRangesAcrossPageBoundaries() async throws {
        let data = Data((0..<(LargeTextPageReader.pageSize + 20)).map { UInt8($0 & 0xff) })
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let lower = UInt64(LargeTextPageReader.pageSize - 10)
        let result = try await LargeTextPageReader().read(url: url, range: lower..<(lower + 25))
        #expect(result == data.subdata(in: Int(lower)..<(Int(lower) + 25)))
    }

    @Test func oneGigabyteSparseFilePerformsOnlyOneBoundedDiskRead() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 1_024 * 1_024 * 1_024)
        try writer.close()
        let reader = LargeTextPageReader()
        let page = try await reader.page(url: url, containing: 900 * 1_024 * 1_024)
        let stats = await reader.currentStatistics()
        #expect(page.count == LargeTextPageReader.pageSize)
        #expect(stats.diskReadCount == 1)
        #expect(stats.diskBytesRead == UInt64(LargeTextPageReader.pageSize))
        #expect(stats.cachedBytes == LargeTextPageReader.pageSize)
    }

    @Test func pieceTableInsertsDeletesAndMaterializes() async throws {
        let url = try temporaryFile(Data("hello world".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let table = LargeTextPieceTable(originalLength: 11)
        await table.insert(Data(" swift".utf8), at: 5)
        await table.delete(5..<11)
        let value = try await table.materialize(originalURL: url, reader: LargeTextPageReader())
        #expect(String(decoding: value, as: UTF8.self) == "hello world")
        #expect(await table.length == 11)
    }

    @Test func pieceTableStreamsSmallChunksInLogicalOrder() async throws {
        let url = try temporaryFile(Data("abcdef".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let table = LargeTextPieceTable(originalLength: 6)
        await table.insert(Data("XYZ".utf8), at: 3)
        await table.delete(1..<2)
        var chunks: [Data] = []
        try await table.forEachChunk(originalURL: url, reader: LargeTextPageReader(), maximumChunkSize: 2) {
            chunks.append($0)
        }
        #expect(chunks.allSatisfy { $0.count <= 2 })
        #expect(String(decoding: chunks.joined(), as: UTF8.self) == "acXYZdef")
    }

    @Test func pieceTableUndoRedoCoversInsertAndDelete() async throws {
        let url = try temporaryFile(Data("abcdef".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let table = LargeTextPieceTable(originalLength: 6)
        let reader = LargeTextPageReader()
        await table.insert(Data("XY".utf8), at: 3)
        await table.delete(1..<3)
        #expect(String(decoding: try await table.materialize(originalURL: url, reader: reader), as: UTF8.self) == "aXYdef")
        #expect(await table.undo())
        #expect(String(decoding: try await table.materialize(originalURL: url, reader: reader), as: UTF8.self) == "abcXYdef")
        #expect(await table.undo())
        #expect(String(decoding: try await table.materialize(originalURL: url, reader: reader), as: UTF8.self) == "abcdef")
        #expect(await table.redo())
        #expect(await table.redo())
        #expect(String(decoding: try await table.materialize(originalURL: url, reader: reader), as: UTF8.self) == "aXYdef")
        #expect(!(await table.canRedo()))
    }

    @Test func newEditClearsPieceTableRedoHistory() async throws {
        let table = LargeTextPieceTable(originalLength: 4)
        await table.delete(0..<1)
        #expect(await table.undo())
        #expect(await table.canRedo())
        await table.insert(Data("!".utf8), at: 4)
        #expect(!(await table.canRedo()))
    }

    @Test func pieceTableWritesIncrementallyToAFileHandle() async throws {
        let original = try temporaryFile(Data("012345".utf8))
        let outputURL = try temporaryFile()
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: outputURL)
        }
        let table = LargeTextPieceTable(originalLength: 6)
        await table.insert(Data("ABC".utf8), at: 3)
        let output = try FileHandle(forWritingTo: outputURL)
        try await table.write(originalURL: original, reader: LargeTextPageReader(),
                              to: output, maximumChunkSize: 2)
        try output.close()
        #expect(try Data(contentsOf: outputURL) == Data("012ABC345".utf8))
    }

    @Test func progressiveLineIndexAndCrossPageSearch() async throws {
        var data = Data(repeating: 0x61, count: LargeTextPageReader.pageSize - 2)
        data.append(Data("\nNEEDLE\nlast".utf8))
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = LargeTextPageReader()
        let scanner = LargeTextScanner()
        let generation = await scanner.beginGeneration()
        let index = try await scanner.buildLineIndex(url: url, reader: reader, generation: generation)
        #expect(index.lineStarts == [0, UInt64(LargeTextPageReader.pageSize - 1), UInt64(LargeTextPageReader.pageSize + 6)])
        #expect(index.lineNumber(containingByteOffset: UInt64(LargeTextPageReader.pageSize)) == 2)
        let matches = try await scanner.search(url: url, query: Data("NEEDLE".utf8), reader: reader, generation: generation)
        #expect(matches.map(\.byteRange.lowerBound) == [UInt64(LargeTextPageReader.pageSize - 1)])
    }

    @Test func lineIndexHandlesCRLFAndCRAcrossPageBoundary() async throws {
        var data = Data(repeating: 0x61, count: LargeTextPageReader.pageSize - 1)
        data.append(Data("\r\nsecond\rthird".utf8))
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = LargeTextScanner()
        let generation = await scanner.beginGeneration()
        let index = try await scanner.buildLineIndex(
            url: url, reader: LargeTextPageReader(), generation: generation
        )
        #expect(index.lineStarts == [
            0,
            UInt64(LargeTextPageReader.pageSize + 1),
            UInt64(LargeTextPageReader.pageSize + 8)
        ])
    }

    @Test func invalidatedGenerationRejectsWork() async throws {
        let url = try temporaryFile(Data("one\ntwo\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = LargeTextScanner()
        let stale = await scanner.beginGeneration()
        await scanner.invalidate()
        await #expect(throws: LargeTextScanError.staleGeneration) {
            try await scanner.buildLineIndex(url: url, reader: LargeTextPageReader(), generation: stale)
        }
    }
}
