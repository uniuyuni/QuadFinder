import Foundation
import Testing
@testable import QuadFinder

@Suite("Pane input routing")
struct PaneInputRoutingTests {
    @Test func pointerOpeningRequiresAnExplicitContentURL() {
        let url = URL(fileURLWithPath: "/tmp/selected")
        #expect(PointerOpenRequest(url: url, hitRegion: .content).contentURL == url)
        for region in [PointerOpenRequest.HitRegion.disclosure, .rowWhitespace,
                       .metadataColumn, .background, .chrome] {
            #expect(PointerOpenRequest(url: url, hitRegion: region).contentURL == nil)
        }
    }

    @Test func spaceIsHandledOnlyByActivePaneOutsideTextEditing() {
        #expect(PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: true, isTextEditing: false))
        #expect(!PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: false, isTextEditing: false))
        #expect(!PaneInputRoutingPolicy.shouldHandleQuickLook(isActivePane: true, isTextEditing: true))
    }

    @Test func selectAllFallsBackOnlyForTheActivePaneWhenResponderDidNotHandleIt() {
        #expect(PaneInputRoutingPolicy.shouldSelectAllInPane(isActivePane: true, firstResponderHandledAction: false))
        #expect(!PaneInputRoutingPolicy.shouldSelectAllInPane(isActivePane: false, firstResponderHandledAction: false))
        #expect(!PaneInputRoutingPolicy.shouldSelectAllInPane(isActivePane: true, firstResponderHandledAction: true))
    }
}
