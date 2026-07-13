import Foundation

enum LargeTextScanError: Error, Equatable {
    case staleGeneration
}

struct LargeTextLineIndex: Equatable, Sendable {
    /// Byte offsets of line starts. The first line always begins at zero.
    let lineStarts: [UInt64]
    let indexedByteCount: UInt64

    var lineCount: Int { lineStarts.count }

    func lineNumber(containingByteOffset offset: UInt64) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }
}

struct LargeTextSearchMatch: Equatable, Sendable {
    let byteRange: Range<UInt64>
}

/// Runs progressive scans. Calling `invalidate()` makes in-flight work stale at
/// its next page suspension, independently from cooperative Task cancellation.
actor LargeTextScanner {
    typealias Progress = @Sendable (_ completed: UInt64, _ total: UInt64) async -> Void
    private var generation: UInt64 = 0

    func beginGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    func invalidate() { generation &+= 1 }

    func buildLineIndex(
        url: URL,
        reader: LargeTextPageReader,
        generation expected: UInt64,
        progress: Progress? = nil
    ) async throws -> LargeTextLineIndex {
        let size = try await reader.snapshot(of: url).size
        var starts: [UInt64] = [0]
        var cursor: UInt64 = 0
        var hasPendingCR = false
        while cursor < size {
            try Task.checkCancellation()
            guard expected == generation else { throw LargeTextScanError.staleGeneration }
            let upper = min(size, cursor + UInt64(LargeTextPageReader.pageSize))
            let data = try await reader.read(url: url, range: cursor..<upper)
            for (index, byte) in data.enumerated() {
                let absolute = cursor + UInt64(index)
                if hasPendingCR {
                    let next = byte == 0x0A ? absolute + 1 : absolute
                    if next < size { starts.append(next) }
                    hasPendingCR = false
                    if byte == 0x0A { continue }
                }
                if byte == 0x0D {
                    hasPendingCR = true
                } else if byte == 0x0A {
                    let next = absolute + 1
                    if next < size { starts.append(next) }
                }
            }
            cursor = upper
            await progress?(cursor, size)
        }
        guard expected == generation else { throw LargeTextScanError.staleGeneration }
        return LargeTextLineIndex(lineStarts: starts, indexedByteCount: size)
    }

    func search(
        url: URL,
        query: Data,
        reader: LargeTextPageReader,
        generation expected: UInt64,
        progress: Progress? = nil
    ) async throws -> [LargeTextSearchMatch] {
        guard !query.isEmpty else { return [] }
        let size = try await reader.snapshot(of: url).size
        var results: [LargeTextSearchMatch] = []
        var cursor: UInt64 = 0
        var overlap = Data()
        while cursor < size {
            try Task.checkCancellation()
            guard expected == generation else { throw LargeTextScanError.staleGeneration }
            let upper = min(size, cursor + UInt64(LargeTextPageReader.pageSize))
            let page = try await reader.read(url: url, range: cursor..<upper)
            // Normalize indices: Data suffixes can retain a non-zero startIndex.
            var window = Data(overlap)
            window.append(page)
            let windowStart = cursor - UInt64(overlap.count)
            if window.count >= query.count {
                var searchStart = window.startIndex
                while searchStart <= window.endIndex - query.count,
                      let found = window.range(of: query, options: [], in: searchStart..<window.endIndex) {
                    let absolute = windowStart + UInt64(found.lowerBound - window.startIndex)
                    // Matches fully contained in the overlap were reported on the preceding iteration.
                    if absolute + UInt64(query.count) > cursor {
                        results.append(.init(byteRange: absolute..<(absolute + UInt64(query.count))))
                    }
                    searchStart = found.lowerBound + 1
                }
            }
            let overlapCount = min(max(0, query.count - 1), window.count)
            overlap = Data(window.suffix(overlapCount))
            cursor = upper
            await progress?(cursor, size)
        }
        guard expected == generation else { throw LargeTextScanError.staleGeneration }
        return results
    }
}
