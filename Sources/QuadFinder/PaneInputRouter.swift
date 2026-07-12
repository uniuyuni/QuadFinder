import AppKit
import SwiftUI

enum PaneInputRoutingPolicy {
    static func shouldHandleQuickLook(isActivePane: Bool, isTextEditing: Bool) -> Bool {
        isActivePane && !isTextEditing
    }
}

/// Observes pane events without participating in hit testing.  Returning the
/// original NSEvent is important: native List selection and SwiftUI drag
/// recognition remain the sole owners of mouse input.
struct PaneInputRouter: NSViewRepresentable {
    let isActivePane: () -> Bool
    let activate: () -> Void
    let openSelection: () -> Void
    let toggleQuickLook: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.install(for: view)
        updateCoordinator(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        updateCoordinator(context.coordinator)
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.isActivePane = isActivePane
        coordinator.activate = activate
        coordinator.openSelection = openSelection
        coordinator.toggleQuickLook = toggleQuickLook
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var isActivePane: () -> Bool = { false }
        var activate: () -> Void = {}
        var openSelection: () -> Void = {}
        var toggleQuickLook: () -> Void = {}

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.observe(event) ?? false }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func observe(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { return false }
                activate()
                if event.type == .leftMouseDown, event.clickCount == 2 {
                    // Native selection is committed by AppKit after the monitor
                    // returns the event, so open on the next main-loop turn.
                    DispatchQueue.main.async { [weak self] in self?.openSelection() }
                }
                return false
            case .keyDown:
                guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
                let responder = window.firstResponder
                let isTextEditing = responder is NSTextView || responder is NSTextField
                guard PaneInputRoutingPolicy.shouldHandleQuickLook(
                    isActivePane: isActivePane(), isTextEditing: isTextEditing
                ) else { return false }
                toggleQuickLook()
                return true
            default:
                return false
            }
        }
    }
}
