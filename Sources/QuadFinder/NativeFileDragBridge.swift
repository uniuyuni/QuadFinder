import AppKit
import UniformTypeIdentifiers

/// The pasteboard contract shared by every browser presentation. Keeping it in
/// one place prevents icon/column/tree drags from behaving differently.
enum NativeFileDragPasteboard {
    static let paneItemType = NSPasteboard.PasteboardType(UTType.quadFinderPaneItem.identifier)

    static func item(for payload: PaneFileDragPayload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(payload.url.absoluteString, forType: .fileURL)
        if let data = try? JSONEncoder().encode(payload) {
            item.setData(data, forType: paneItemType)
        }
        return item
    }

    static func items(for payloads: [PaneFileDragPayload]) -> [NSPasteboardItem] {
        payloads.map(item(for:))
    }

    static func payloads(from items: [NSPasteboardItem]) -> [PaneFileDragPayload] {
        items.compactMap { item in
            guard let data = item.data(forType: paneItemType) else { return nil }
            return try? JSONDecoder().decode(PaneFileDragPayload.self, from: data)
        }
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let native = (pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
        let privateURLs = payloads(from: pasteboard.pasteboardItems ?? []).map(\.url)
        return Array(Set(native + privateURLs)).sorted { $0.path < $1.path }
    }
}

/// Pure policy used by the AppKit source and unit tests. AppKit uses the
/// returned mask to draw its standard copy/move/link badge next to the cursor.
enum NativeFileDragOperationPolicy {
    static func mask(isInsideApplication: Bool, modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.command, .option]) { return .link }
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        // The Dock Trash proposes .delete, not .move. Advertising both for an
        // external drag lets normal file destinations negotiate move and lets
        // the Trash accept the same native file-URL pasteboard items.
        return isInsideApplication ? [.copy, .move, .link] : [.copy, .move, .link, .delete]
    }
}

/// Finder's destination-side decision. The destination must choose one
/// operation (rather than displaying a copy/move chooser), so AppKit can show
/// the matching standard cursor badge while modifiers change during a drag.
enum FinderDragOperationPolicy {
    static func operation(modifiers: NSEvent.ModifierFlags, sameVolume: Bool) -> NSDragOperation {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains([.command, .option]) { return .link }
        if flags.contains(.option) { return .copy }
        if !sameVolume, flags.contains(.command) { return .move }
        return sameVolume ? .move : .copy
    }

    static func sameVolume(sourceURLs: [URL], targetDirectory: URL,
                           resourceValues: (URL) -> AnyHashable? = volumeIdentifier) -> Bool {
        guard !sourceURLs.isEmpty, let target = resourceValues(targetDirectory) else { return false }
        return sourceURLs.allSatisfy { source in
            guard let sourceVolume = resourceValues(source) else { return false }
            return sourceVolume == target
        }
    }

    static func operation(sourceURLs: [URL], targetDirectory: URL,
                          modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        operation(modifiers: modifiers,
                  sameVolume: sameVolume(sourceURLs: sourceURLs, targetDirectory: targetDirectory))
    }

    private static func volumeIdentifier(_ url: URL) -> AnyHashable? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? AnyHashable
    }
}

/// The destination's final decision for a native file drop.  This value is
/// captured while AppKit is accepting the drag and carried through to the
/// operation queue; recomputing it later from `NSApp.currentEvent` can disagree
/// with the cursor AppKit just displayed.
enum FinderDropIntent: Equatable, Sendable {
    case copy
    case move
    case link

    init(_ operation: NSDragOperation) {
        if operation == .link { self = .link }
        else if operation == .move { self = .move }
        else { self = .copy }
    }
}

struct NativeValidatedDrop: Equatable, Sendable {
    let sourceURLs: Set<URL>
    let targetDirectory: URL
    let intent: FinderDropIntent

    init(sourceURLs: [URL], targetDirectory: URL, intent: FinderDropIntent) {
        self.sourceURLs = Set(sourceURLs.map(FileURLIdentity.canonical))
        self.targetDirectory = FileURLIdentity.canonical(targetDirectory)
        self.intent = intent
    }

    func matches(sourceURLs: [URL], targetDirectory: URL) -> Bool {
        matches(sourceURLs: sourceURLs) && FileURLIdentity.isSame(self.targetDirectory, targetDirectory)
    }

    func matches(sourceURLs: [URL]) -> Bool {
        self.sourceURLs == Set(sourceURLs.map(FileURLIdentity.canonical))
    }
}

enum NativeDropAcceptance {
    /// `validateDrop` is the point at which AppKit and the cursor agree on a
    /// destination. The pointer can move outside that row before `acceptDrop`,
    /// so acceptance must preserve the validated target and operation together.
    static func resolve(validated: NativeValidatedDrop?, sourceURLs: [URL],
                        fallbackTarget: URL, fallbackIntent: FinderDropIntent) -> NativeValidatedDrop {
        if let validated, validated.matches(sourceURLs: sourceURLs) { return validated }
        return NativeValidatedDrop(sourceURLs: sourceURLs, targetDirectory: fallbackTarget,
                                   intent: fallbackIntent)
    }
}
