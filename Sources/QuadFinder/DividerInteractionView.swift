import AppKit
import SwiftUI

struct DividerInteractionView: NSViewRepresentable {
    let axis: Axis
    let ratio: Double
    let containerExtent: CGFloat
    let changed: (Double) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> DividerInteractionNSView {
        DividerInteractionNSView()
    }

    func updateNSView(_ view: DividerInteractionNSView, context: Context) {
        view.axis = axis
        view.ratio = ratio
        view.containerExtent = containerExtent
        view.changed = changed
        view.reset = reset
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class DividerInteractionNSView: NSView {
    var axis: Axis = .horizontal
    var ratio = 0.5
    var containerExtent: CGFloat = 1
    var changed: ((Double) -> Void)?
    var reset: (() -> Void)?
    private var initialPoint: NSPoint?
    private var initialRatio = 0.5

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            reset?()
            return
        }
        initialPoint = event.locationInWindow
        initialRatio = ratio
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialPoint else { return }
        let delta = axis == .horizontal
            ? event.locationInWindow.x - initialPoint.x
            : initialPoint.y - event.locationInWindow.y
        changed?(DividerMath.updatedRatio(
            start: initialRatio, translation: delta, containerExtent: containerExtent
        ))
    }

    override func mouseUp(with event: NSEvent) {
        initialPoint = nil
    }
}
