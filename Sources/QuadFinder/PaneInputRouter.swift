import AppKit
import SwiftUI

enum PaneInputRoutingPolicy {
    static func shouldHandleQuickLook(isActivePane: Bool, isTextEditing: Bool) -> Bool {
        isActivePane && !isTextEditing
    }

    static func shouldSelectAllInPane(isActivePane: Bool, firstResponderHandledAction: Bool) -> Bool {
        isActivePane && !firstResponderHandledAction
    }
}

/// Mouse-driven opening is intentionally URL-based, never selection-based.
/// Native browser views may emit a request only after their own exact content
/// hit test succeeds. Keyboard and menu commands use their separate selection
/// command path and do not manufacture this request.
struct PointerOpenRequest: Equatable, Sendable {
    enum HitRegion: Equatable, Sendable {
        case content
        case disclosure
        case rowWhitespace
        case metadataColumn
        case background
        case chrome
    }

    let url: URL
    let hitRegion: HitRegion

    var contentURL: URL? { hitRegion == .content ? url : nil }
}

extension Notification.Name {
    static let quadFinderSelectAllInActivePane = Notification.Name("QuadFinder.selectAllInActivePane")
}

/// Observes pane events without participating in hit testing.  Returning the
/// original NSEvent is important: native List selection and SwiftUI drag
/// recognition remain the sole owners of mouse input.
struct PaneInputRouter: NSViewRepresentable {
    let isActivePane: () -> Bool
    let activate: () -> Void
    let toggleQuickLook: () -> Void
    let selectAllVisible: () -> Void

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
        coordinator.toggleQuickLook = toggleQuickLook
        coordinator.selectAllVisible = selectAllVisible
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
        var toggleQuickLook: () -> Void = {}
        var selectAllVisible: () -> Void = {}
        var selectAllObserver: NSObjectProtocol?

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.observe(event) ?? false }
                return consumed ? nil : event
            }
            selectAllObserver = NotificationCenter.default.addObserver(
                forName: .quadFinderSelectAllInActivePane, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          PaneInputRoutingPolicy.shouldSelectAllInPane(
                            isActivePane: self.isActivePane(), firstResponderHandledAction: false
                          ) else { return }
                    self.selectAllVisible()
                }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let selectAllObserver { NotificationCenter.default.removeObserver(selectAllObserver) }
            selectAllObserver = nil
        }

        private func observe(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { return false }
                activate()
                // Opening is deliberately not routed here. This monitor covers
                // the whole pane, so using its double-click to open the current
                // selection makes unrelated whitespace, metadata columns and
                // disclosure controls open a previously selected file. Each
                // native browser owns hit-testing and sends an explicit item.
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
