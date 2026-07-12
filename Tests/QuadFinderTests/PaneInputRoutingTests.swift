import Testing
@testable import QuadFinder

@Suite("Pane input routing")
struct PaneInputRoutingTests {
    @Test func spaceIsHandledOnlyByActivePaneOutsideTextEditing() {
        #expect(PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: true, isTextEditing: false))
        #expect(!PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: false, isTextEditing: false))
        #expect(!PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: true, isTextEditing: true))
    }
}
