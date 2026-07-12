import Foundation

enum PaneSelectionPolicy {
    static func contextTargets(clicked: URL, selection: Set<URL>) -> Set<URL> {
        selection.contains(clicked) ? selection : [clicked]
    }

    static func range(
        anchor: URL, clicked: URL, orderedItems: [URL]
    ) -> Set<URL> {
        guard let first = orderedItems.firstIndex(of: anchor),
              let second = orderedItems.firstIndex(of: clicked) else { return [clicked] }
        return Set(orderedItems[min(first, second)...max(first, second)])
    }
}
