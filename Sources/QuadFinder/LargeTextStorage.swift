import Foundation

/// A bounded, random-access reader for files which must not be loaded as one `Data` value.
actor LargeTextPageReader {
    static let pageSize = 64 * 1_024
    static let defaultCacheByteLimit = 64 * 1_024 * 1_024

    struct Snapshot: Equatable, Sendable {
        let url: URL
        let size: UInt64
        let modificationTime: TimeInterval
    }

    struct Statistics: Equatable, Sendable {
        var diskReadCount = 0
        var diskBytesRead: UInt64 = 0
        var cachedBytes = 0
        var cachedPages = 0
    }

    private struct Key: Hashable {
        let url: URL
        let offset: UInt64
        let size: UInt64
        let modificationTime: TimeInterval
    }

    private struct Entry {
        let data: Data
        var access: UInt64
    }

    private let cacheByteLimit: Int
    private var cache: [Key: Entry] = [:]
    private var cacheBytes = 0
    private var clock: UInt64 = 0
    private var statistics = Statistics()

    init(cacheByteLimit: Int = defaultCacheByteLimit) {
        self.cacheByteLimit = max(Self.pageSize, cacheByteLimit)
    }

    func snapshot(of url: URL) throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return Snapshot(
            url: url.standardizedFileURL,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    /// Reads at most one 64 KiB page. The supplied offset need not be page aligned.
    func page(url: URL, containing offset: UInt64) throws -> Data {
        let file = try snapshot(of: url)
        guard offset < file.size else { return Data() }
        let pageOffset = offset / UInt64(Self.pageSize) * UInt64(Self.pageSize)
        let key = Key(url: file.url, offset: pageOffset, size: file.size,
                      modificationTime: file.modificationTime)
        clock &+= 1
        if var hit = cache[key] {
            hit.access = clock
            cache[key] = hit
            return hit.data
        }

        let scoped = AppSecurityEnvironment.current.isSandboxed && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: pageOffset)
        let requested = Int(min(UInt64(Self.pageSize), file.size - pageOffset))
        let data = try handle.read(upToCount: requested) ?? Data()
        statistics.diskReadCount += 1
        statistics.diskBytesRead += UInt64(data.count)
        insert(data, for: key)
        return data
    }

    /// Reads up to 64 KiB from an arbitrary range using bounded pages. A range
    /// beyond EOF is clamped, and a large caller-supplied range cannot cause an
    /// accidental whole-file allocation.
    func read(url: URL, range: Range<UInt64>) throws -> Data {
        guard !range.isEmpty else { return Data() }
        let file = try snapshot(of: url)
        let lower = min(range.lowerBound, file.size)
        let requestedUpper = min(max(range.upperBound, lower), file.size)
        let upper = min(requestedUpper, lower + UInt64(Self.pageSize))
        guard lower < upper else { return Data() }
        var result = Data()
        result.reserveCapacity(Int(upper - lower))
        var cursor = lower
        while cursor < upper {
            let pageOffset = cursor / UInt64(Self.pageSize) * UInt64(Self.pageSize)
            let data = try page(url: url, containing: cursor)
            let start = Int(cursor - pageOffset)
            let amount = min(data.count - start, Int(upper - cursor))
            guard amount > 0 else { break }
            result.append(data[start..<(start + amount)])
            cursor += UInt64(amount)
        }
        return result
    }

    func currentStatistics() -> Statistics {
        var result = statistics
        result.cachedBytes = cacheBytes
        result.cachedPages = cache.count
        return result
    }

    func removeAllCachedPages() {
        cache.removeAll(keepingCapacity: true)
        cacheBytes = 0
    }

    private func insert(_ data: Data, for key: Key) {
        if let old = cache.updateValue(Entry(data: data, access: clock), forKey: key) {
            cacheBytes -= old.data.count
        }
        cacheBytes += data.count
        while cacheBytes > cacheByteLimit,
              let victim = cache.min(by: { $0.value.access < $1.value.access }) {
            cacheBytes -= victim.value.data.count
            cache.removeValue(forKey: victim.key)
        }
    }
}

/// A piece table whose original pieces are byte ranges in a file. Inserted bytes are
/// retained in append-only storage; deletion only changes the piece list.
actor LargeTextPieceTable {
    enum Source: Equatable, Sendable { case original, added }
    struct Piece: Equatable, Sendable {
        let source: Source
        var offset: UInt64
        var length: UInt64
    }

    private(set) var length: UInt64
    private var pieces: [Piece]
    private var added = Data()
    private var undoStack: [[Piece]] = []
    private var redoStack: [[Piece]] = []

    init(originalLength: UInt64) {
        length = originalLength
        pieces = originalLength == 0 ? [] : [Piece(source: .original, offset: 0, length: originalLength)]
    }

    func currentPieces() -> [Piece] { pieces }
    func canUndo() -> Bool { !undoStack.isEmpty }
    func canRedo() -> Bool { !redoStack.isEmpty }

    func insert(_ bytes: Data, at position: UInt64) {
        guard !bytes.isEmpty, position <= length else { return }
        recordMutation()
        let newPiece = Piece(source: .added, offset: UInt64(added.count), length: UInt64(bytes.count))
        added.append(bytes)
        let boundary = split(at: position)
        pieces.insert(newPiece, at: boundary)
        length += UInt64(bytes.count)
        coalesce()
    }

    func delete(_ range: Range<UInt64>) {
        let lower = min(range.lowerBound, length)
        let upper = min(max(range.upperBound, lower), length)
        guard lower < upper else { return }
        recordMutation()
        let start = split(at: lower)
        let end = split(at: upper)
        pieces.removeSubrange(start..<end)
        length -= upper - lower
        coalesce()
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(pieces)
        restore(previous)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(pieces)
        restore(next)
        return true
    }

    func materialize(originalURL: URL, reader: LargeTextPageReader) async throws -> Data {
        guard length <= UInt64(Int.max) else { throw CocoaError(.fileReadTooLarge) }
        var result = Data()
        result.reserveCapacity(Int(length))
        try await forEachChunk(originalURL: originalURL, reader: reader) { result.append($0) }
        return result
    }

    /// Materializes only a logical range; callers use this for virtual editor windows.
    func read(_ requested: Range<UInt64>, originalURL: URL, reader: LargeTextPageReader) async throws -> Data {
        let lower = min(requested.lowerBound, length)
        let upper = min(max(requested.upperBound, lower), length)
        guard lower < upper else { return Data() }
        var result = Data(); result.reserveCapacity(Int(upper - lower))
        var logical: UInt64 = 0
        let snapshotAdded = added
        for piece in pieces {
            let pieceRange = logical..<(logical + piece.length)
            let start = max(lower, pieceRange.lowerBound)
            let end = min(upper, pieceRange.upperBound)
            if start < end {
                let relative = start - pieceRange.lowerBound
                let count = end - start
                switch piece.source {
                case .original:
                    result.append(try await reader.read(url: originalURL,
                        range: (piece.offset + relative)..<(piece.offset + relative + count)))
                case .added:
                    let first = Int(piece.offset + relative)
                    result.append(snapshotAdded[first..<(first + Int(count))])
                }
            }
            logical += piece.length
            if logical >= upper { break }
        }
        return result
    }

    /// Supplies ordered chunks without ever materializing the entire document.
    func forEachChunk(
        originalURL: URL,
        reader: LargeTextPageReader,
        maximumChunkSize: Int = LargeTextPageReader.pageSize,
        _ consume: (Data) async throws -> Void
    ) async throws {
        let chunkSize = max(1, min(maximumChunkSize, LargeTextPageReader.pageSize))
        let snapshotPieces = pieces
        let snapshotAdded = added
        for piece in snapshotPieces {
            var consumed: UInt64 = 0
            while consumed < piece.length {
                try Task.checkCancellation()
                let count = min(UInt64(chunkSize), piece.length - consumed)
                let chunk: Data
                switch piece.source {
                case .original:
                    chunk = try await reader.read(
                        url: originalURL,
                        range: (piece.offset + consumed)..<(piece.offset + consumed + count)
                    )
                case .added:
                    let start = Int(piece.offset + consumed)
                    chunk = snapshotAdded.subdata(in: start..<(start + Int(count)))
                }
                try await consume(chunk)
                consumed += count
            }
        }
    }

    /// Writes the logical document sequentially to an already-created output handle.
    /// This is suitable for the temporary handle used by an atomic-save implementation.
    func write(
        originalURL: URL,
        reader: LargeTextPageReader,
        to output: FileHandle,
        maximumChunkSize: Int = LargeTextPageReader.pageSize
    ) async throws {
        try await forEachChunk(originalURL: originalURL, reader: reader,
                               maximumChunkSize: maximumChunkSize) {
            try output.write(contentsOf: $0)
        }
    }

    @discardableResult
    private func split(at position: UInt64) -> Int {
        if position == length { return pieces.count }
        var logical: UInt64 = 0
        for index in pieces.indices {
            let end = logical + pieces[index].length
            if position == logical { return index }
            if position < end {
                let leftLength = position - logical
                let right = Piece(source: pieces[index].source,
                                  offset: pieces[index].offset + leftLength,
                                  length: pieces[index].length - leftLength)
                pieces[index].length = leftLength
                pieces.insert(right, at: index + 1)
                return index + 1
            }
            logical = end
        }
        return pieces.count
    }

    private func coalesce() {
        pieces.removeAll { $0.length == 0 }
        guard pieces.count > 1 else { return }
        var compact: [Piece] = []
        compact.reserveCapacity(pieces.count)
        for piece in pieces {
            if let last = compact.last,
               last.source == piece.source,
               last.offset + last.length == piece.offset {
                compact[compact.count - 1].length += piece.length
            } else {
                compact.append(piece)
            }
        }
        pieces = compact
    }

    private func recordMutation() {
        undoStack.append(pieces)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func restore(_ snapshot: [Piece]) {
        pieces = snapshot
        length = snapshot.reduce(0) { $0 + $1.length }
    }
}
