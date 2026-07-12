import Foundation
import Testing
@testable import QuadFinder

@Suite("Real file operation progress")
struct RealFileProgressTests {
    @Test func copyEmitsIntermediateMonotonicProgressAndTotals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 7, count: 3 * 1024 * 1024 + 17)
        try bytes.write(to: source.appendingPathComponent("large.bin"))
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("small.bin"))
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: target)
        let recorder = ProgressRecorder()

        let outcome = try await FileSystemService(cloneStrategy: .disabled).perform(operation) { recorder.append($0) }
        let values = recorder.snapshot()
        #expect(values.count >= 3)
        #expect(values.contains { $0.fractionCompleted > 0 && $0.fractionCompleted < 1 })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(values.last?.completedBytes == Int64(bytes.count + 3))
        #expect(outcome.completedBytes == Int64(bytes.count + 3))
        #expect(outcome.completedItems == 3)
    }

    @Test func multipleSourcesUseCombinedTotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"); let b = root.appendingPathComponent("b")
        try Data(repeating: 1, count: 11).write(to: a); try Data(repeating: 2, count: 29).write(to: b)
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [a, b], targetDirectoryURL: target)
        let recorder = ProgressRecorder()
        _ = try await FileSystemService(cloneStrategy: .disabled).perform(operation) { recorder.append($0) }
        #expect(recorder.snapshot().last?.totalBytes == 40)
        #expect(recorder.snapshot().last?.completedBytes == 40)
    }

    @Test func cancellationRemovesPartialOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("large.bin")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 3 * 1024 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: UUID(), targetPaneID: UUID(), sourceURLs: [source], targetDirectoryURL: target)
        await #expect(throws: CancellationError.self) {
            try await FileSystemService(cloneStrategy: .disabled).perform(operation) { value in
                if value.completedBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("large.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.path)
        #expect(leftovers.isEmpty)
    }

    @Test func eligibleFileUsesAtomicCloneAndReportsCompleteProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 4, count: 257).write(to: source)
        let recorder = CloneRecorder(result: true)
        let strategy = FileCloneStrategy(canClone: { _, _ in true }, clone: { source, destination in
            recorder.record()
            do { try FileManager.default.copyItem(at: source, to: destination); return true } catch { return false }
        })
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(),
                                             sourceURLs: [source], targetDirectoryURL: target)
        let progress = ProgressRecorder()
        let outcome = try await FileSystemService(cloneStrategy: strategy).perform(operation) { progress.append($0) }
        #expect(recorder.count == 1)
        #expect(outcome.completedBytes == 257)
        #expect(outcome.completedItems == 1)
        #expect(progress.snapshot().last?.fractionCompleted == 1)
        #expect(try Data(contentsOf: target.appendingPathComponent("source.bin")) == Data(repeating: 4, count: 257))
    }

    @Test func failedCloneFallsBackToStreamingCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 8, count: 1024 * 1024 + 9).write(to: source)
        let recorder = CloneRecorder(result: false)
        let strategy = FileCloneStrategy(canClone: { _, _ in true }, clone: { _, _ in recorder.record(); return false })
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(),
                                             sourceURLs: [source], targetDirectoryURL: target)
        let progress = ProgressRecorder()
        _ = try await FileSystemService(cloneStrategy: strategy).perform(operation) { progress.append($0) }
        #expect(recorder.count == 1)
        #expect(progress.snapshot().contains { $0.fractionCompleted > 0 && $0.fractionCompleted < 1 })
    }

    @Test func ineligibleVolumeNeverAttemptsClone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin"); try Data([1]).write(to: source)
        let recorder = CloneRecorder(result: true)
        let strategy = FileCloneStrategy(canClone: { _, _ in false }, clone: { _, _ in recorder.record(); return true })
        let operation = PendingFileOperation(kind: .copy, sourcePaneID: nil, targetPaneID: UUID(),
                                             sourceURLs: [source], targetDirectoryURL: target)
        _ = try await FileSystemService(cloneStrategy: strategy).perform(operation) { _ in }
        #expect(recorder.count == 0)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("source.bin").path))
    }
}

private extension FileCloneStrategy {
    static let disabled = FileCloneStrategy(canClone: { _, _ in false }, clone: { _, _ in false })
}

private final class CloneRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0
    init(result: Bool) { _ = result }
    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileOperationProgress] = []
    func append(_ value: FileOperationProgress) { lock.withLock { values.append(value) } }
    func snapshot() -> [FileOperationProgress] { lock.withLock { values } }
}
