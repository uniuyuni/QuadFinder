import Foundation
import Testing
@testable import QuadFinder

@Suite("Folder size calculation")
struct FolderSizeTests {
    @Test func nestedFilesCountLogicalBytesWithoutFollowingSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 123).write(to: root.appendingPathComponent("a"))
        try Data(repeating: 2, count: 77).write(to: nested.appendingPathComponent("b"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)

        let result = try await FolderSizeCalculator().calculate(urls: [root])
        #expect(result.logicalBytes == 200)
        #expect(result.itemCount >= 3)
        #expect(result.errorCount == 0)
    }

    @Test func cancellationIsObserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<30 { try Data([1]).write(to: root.appendingPathComponent("\(index)")) }
        let task = Task {
            try await FolderSizeCalculator().calculate(urls: [root], useCache: false) { progress in
                if progress.itemCount > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func largeFolderCoalescesProgressAndReportsExactFinalCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("\(index)").path,
                                           contents: Data([1]))
        }
        let updates = ProgressRecorder()
        let result = try await FolderSizeCalculator().calculate(urls: [root], useCache: false) { value in
            await updates.append(value)
        }
        let recorded = await updates.values
        #expect(result.itemCount == 2_000)
        #expect(recorded.last?.itemCount == result.itemCount)
        #expect(recorded.count < 20)
        #expect(zip(recorded, recorded.dropFirst()).allSatisfy { pair in
            pair.0.itemCount <= pair.1.itemCount
        })
    }

    @Test func immediateRepeatUsesCachedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 42).write(to: root.appendingPathComponent("file"))
        let calculator = FolderSizeCalculator()
        let first = try await calculator.calculate(urls: [root])
        let updates = ProgressRecorder()
        let second = try await calculator.calculate(urls: [root]) { await updates.append($0) }
        #expect(second == first)
        let cachedUpdates = await updates.values
        #expect(cachedUpdates.count == 1)
        #expect(cachedUpdates.first?.isCached == true)
    }

    @Test func directoryChangeInvalidatesCachedAncestorForDeepMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("file")
        try Data(repeating: 1, count: 10).write(to: file)
        let calculator = FolderSizeCalculator()
        #expect(try await calculator.calculate(urls: [root]).logicalBytes == 10)

        try Data(repeating: 2, count: 99).write(to: file)
        await FolderSizeCalculator.invalidate(url: nested)
        let updates = ProgressRecorder()
        let refreshed = try await calculator.calculate(urls: [root]) { await updates.append($0) }
        #expect(refreshed.logicalBytes == 99)
        #expect(await updates.values.last?.isCached == false)
    }
}

private actor ProgressRecorder {
    private(set) var values: [FolderSizeProgress] = []
    func append(_ value: FolderSizeProgress) { values.append(value) }
}
