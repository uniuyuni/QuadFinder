import Foundation
import Testing
@testable import QuadFinder

@Suite("File operation progress")
struct FileOperationProgressTests {
    private func job(_ status: FileOperationStatus) -> FileOperationJob {
        FileOperationJob(
            id: UUID(),
            operation: PendingFileOperation(
                kind: .copy,
                sourcePaneID: nil,
                targetPaneID: UUID(),
                sourceURLs: [URL(fileURLWithPath: "/tmp/source")],
                targetDirectoryURL: URL(fileURLWithPath: "/tmp/target")
            ),
            enqueuedAt: Date(),
            status: status
        )
    }

    @Test func summaryCountsQueueAndRunningWork() {
        let summary = FileOperationProgressSummary(jobs: [
            job(.succeeded), job(.running), job(.queued), job(.cancelled)
        ])
        #expect(summary.totalCount == 3)
        #expect(summary.completedCount == 1)
        #expect(summary.runningJobID != nil)
        #expect(summary.isActive)
        #expect(summary.fractionCompleted == 1.0 / 3.0)
    }

    @Test func emptySummaryIsInactiveAndFinite() {
        let summary = FileOperationProgressSummary(jobs: [])
        #expect(!summary.isActive)
        #expect(summary.fractionCompleted == 0)
    }
}
