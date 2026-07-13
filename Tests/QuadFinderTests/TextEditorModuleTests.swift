import AppKit
import Foundation
import Testing
@testable import QuadFinder

@Suite(.serialized)
struct TextEditorModuleTests {
    private func file(_ directory: URL, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("text".utf8).write(to: url)
        return url
    }

    @Test func detectsBOMsAndPreservesNewlineChoice() throws {
        #expect(TextModuleIO.detectEncoding(Data([0xEF, 0xBB, 0xBF, 0x41])).0 == .utf8)
        #expect(TextModuleIO.detectEncoding(Data([0xFF, 0xFE, 0x41, 0x00])).0 == .utf16LE)
        #expect(TextModuleIO.detectEncoding(Data([0x00, 0x00, 0xFE, 0xFF])).0 == .utf32BE)
        #expect(TextModuleIO.detectNewline("a\r\nb") == .crlf)
        #expect(TextModuleIO.detectNewline("a\rb") == .cr)
    }

    @Test func binaryContentIsNotPresentedAsText() {
        #expect(TextModuleIO.isProbablyBinary(Data([0, 1, 2, 3, 4])))
        #expect(!TextModuleIO.isProbablyBinary(Data("plain text\n".utf8)))
        #expect(!TextModuleIO.isProbablyBinary(Data([0xFF, 0xFE, 0x41, 0x00])))
    }

    @Test func moduleMigrationDefaultsTextEditorHiddenAndNormalizesPinnedPane() throws {
        var initial = WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp"))
        initial.moduleSettings.textEditor.isVisible = true
        initial.moduleSettings.textEditor.context = .pinned(UUID())
        initial.normalize()
        #expect(initial.moduleSettings.textEditor.context == .active)

        let encoded = try JSONEncoder().encode(WorkspaceState.initial(homeURL: URL(fileURLWithPath: "/tmp")))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var modules = try #require(object["moduleSettings"] as? [String: Any])
        modules.removeValue(forKey: "textEditor")
        object["moduleSettings"] = modules
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: legacy)
        #expect(!decoded.moduleSettings.textEditor.isVisible)
        #expect(decoded.moduleSettings.textEditor.context == .active)
    }

    @Test func lineAndSizeThresholdConstantsAreBounded() {
        #expect(TextModuleIO.normalLimit == 100_000_000)
        #expect(TextModuleIO.windowSize <= 2 * 1_024 * 1_024)
        #expect(ModulePanelLayout.moduleWidth(availableWidth: 500) <= 560)
    }

    @Test func imageHexAndTextUseTheSameSideModuleWidthPolicy() {
        #expect(ModulePanelLayout.imagePolicy == ModulePanelLayout.hexPolicy)
        #expect(ModulePanelLayout.hexPolicy == ModulePanelLayout.textPolicy)
        #expect(ModulePanelLayout.textPolicy.maximumWidth.isFinite)
    }

    @Test func legacyTextWidthsAreMigratedIntoTheSharedRange() {
        #expect(ModulePanelLayout.normalizedPersistedWidth(120) == ModulePanelLayout.minimumWidth)
        #expect(ModulePanelLayout.normalizedPersistedWidth(440) == 440)
        #expect(ModulePanelLayout.normalizedPersistedWidth(800) == ModulePanelLayout.maximumWidth)
        #expect(ModulePanelLayout.normalizedPersistedWidth(.infinity) == ModulePanelLayout.idealWidth)
    }

    @Test func modulesReceiveEqualAllocationsAndKeepThePaneMinimum() {
        let available: CGFloat = 680
        let image = ModulePanelLayout.moduleWidth(
            availableWidth: available,
            preferredWidth: ModulePanelLayout.imagePolicy.idealWidth
        )
        let hex = ModulePanelLayout.moduleWidth(
            availableWidth: available,
            preferredWidth: ModulePanelLayout.hexPolicy.idealWidth
        )
        let text = ModulePanelLayout.moduleWidth(
            availableWidth: available,
            preferredWidth: ModulePanelLayout.textPolicy.idealWidth
        )
        #expect(image == hex)
        #expect(hex == text)
        #expect(available - text - ModulePanelLayout.dividerWidth >= ModulePanelLayout.paneMinimumWidth)
    }


    @Test func dirtySelectionTransitionWaitsForAnExplicitDecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try file(directory, "old.txt")
        let next = try file(directory, "next.txt")
        let pane = UUID()
        var transition = TextDirtyTransitionCoordinator()

        #expect(transition.request(currentURL: old, currentPaneID: pane, isDirty: true,
                                   target: .init(paneID: pane, selection: [next])) == .showPrompt)
        #expect(transition.isPrompting)
        #expect(transition.acceptPending()?.textFile == next)
        #expect(!transition.isPrompting)
    }

    @Test func discardAndSuccessfulSaveUseLatestRapidSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try file(directory, "old.txt")
        let first = try file(directory, "first.txt")
        let latest = try file(directory, "latest.txt")
        var transition = TextDirtyTransitionCoordinator()
        #expect(transition.request(currentURL: old, currentPaneID: nil, isDirty: true,
                                   target: .init(paneID: nil, selection: [first])) == .showPrompt)
        #expect(transition.request(currentURL: old, currentPaneID: nil, isDirty: true,
                                   target: .init(paneID: nil, selection: [latest])) == .pendingUpdated)
        #expect(transition.acceptPending()?.textFile == latest)
    }

    @Test func cancelOrSaveFailureRestoresOriginalDocumentWithoutReprompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try file(directory, "old.txt")
        let next = try file(directory, "next.txt")
        let pane = UUID()
        var transition = TextDirtyTransitionCoordinator()
        _ = transition.request(currentURL: old, currentPaneID: pane, isDirty: true,
                               target: .init(paneID: pane, selection: [next]))
        let restoration = transition.cancelOrFail()
        let restored = try #require(restoration)
        #expect(restored.paneID == pane)
        #expect(restored.selection == [old])
        #expect(transition.request(currentURL: old, currentPaneID: pane, isDirty: true,
                                   target: restored) == .unchanged)
    }

    @Test func folderMultipleAndEmptySelectionsAlsoRequireDirtyResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try file(directory, "old.txt")
        let another = try file(directory, "another.txt")
        for selection: Set<URL> in [[directory], [old, another], []] {
            var transition = TextDirtyTransitionCoordinator()
            #expect(transition.request(currentURL: old, currentPaneID: nil, isDirty: true,
                                       target: .init(paneID: nil, selection: selection)) == .showPrompt)
        }
    }

    @Test func dirtyCloseRequiresDecisionAndCleanCloseIsImmediate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try file(directory, "current.txt")
        let pane = UUID()

        var clean = TextDirtyTransitionCoordinator()
        #expect(clean.requestClose(currentURL: current, currentPaneID: pane, isDirty: false) == .closeNow)
        #expect(!clean.isPrompting)

        var dirty = TextDirtyTransitionCoordinator()
        #expect(dirty.requestClose(currentURL: current, currentPaneID: pane, isDirty: true) == .showPrompt)
        #expect(dirty.isPrompting)
        #expect(dirty.isClosePending)
        #expect(dirty.requestClose(currentURL: current, currentPaneID: pane, isDirty: true) == .pendingUpdated)
        let didAcceptClose = dirty.acceptClose()
        #expect(didAcceptClose)
        #expect(!dirty.isPrompting)
    }

    @Test func cancelOrSaveFailureKeepsDirtyCloseDocumentOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try file(directory, "current.txt")
        let pane = UUID()
        var transition = TextDirtyTransitionCoordinator()
        _ = transition.requestClose(currentURL: current, currentPaneID: pane, isDirty: true)
        let cancellationResult = transition.cancelOrFail()
        let restore = try #require(cancellationResult)
        #expect(restore.paneID == pane)
        #expect(restore.textFile == current)
        #expect(!transition.isPrompting)
        #expect(!transition.isClosePending)
    }

    @Test @MainActor func moduleMenuAndCloseButtonShareOneCloseRouter() {
        let router = TextEditorModuleCloseRouter()
        var requests = 0
        let registration = router.install { requests += 1 }
        #expect(router.requestClose())
        #expect(router.requestClose())
        #expect(requests == 2)
        let newerRegistration = router.install { requests += 10 }
        router.uninstall(registration)
        #expect(router.requestClose())
        #expect(requests == 12)
        router.uninstall(newerRegistration)
        #expect(!router.requestClose())
    }

    @Test @MainActor func nativeEditorRoutesCommandSaveAndRetainsStandardSelectAll() throws {
        let editor = QuadFinderTextView(frame: .zero)
        editor.string = "alpha\nbeta"
        var saves = 0
        editor.saveHandler = { saves += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1
        ))
        #expect(editor.performKeyEquivalent(with: event))
        #expect(saves == 1)
        editor.selectAll(nil)
        #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
        #expect(AppCommandRouting.isTextInput(editor))
        #expect(!AppCommandRouting.isTextInput(NSTableView()))
    }

    @Test @MainActor func nativeEditorInsertsOrdinaryKeysAndRecreatedEditorDoesNotMoveThroughOldText() throws {
        func key(_ characters: String, keyCode: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
        }
        func editor(_ value: String) -> QuadFinderTextView {
            let editor = QuadFinderTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            editor.isEditable = true
            editor.isSelectable = true
            editor.string = value
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            return editor
        }

        var mounted: QuadFinderTextView? = editor("")
        mounted!.keyDown(with: try key("a", keyCode: 0))
        #expect(mounted!.string == "a")
        mounted = nil

        let reopened = editor("old")
        reopened.keyDown(with: try key("b", keyCode: 11))
        #expect(reopened.string == "oldb")
        #expect(reopened.selectedRange().location == 4)

        let rightArrow = try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124)
        reopened.setSelectedRange(NSRange(location: 0, length: 0))
        reopened.keyDown(with: rightArrow)
        #expect(reopened.string == "oldb")
        #expect(reopened.selectedRange().location == 1)
    }
}
