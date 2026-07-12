import SwiftUI

struct PaneGridView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    // The visible divider is intentionally subtle.  The cursor communicates the
    // larger interaction affordance without drawing a heavy gutter between panes.
    private let dividerThickness: CGFloat = DividerMetrics.visibleThickness

    var body: some View {
        GeometryReader { geometry in
            if let maximized = workspace.state.maximizedPaneID,
               let index = workspace.state.orderedPaneIDs.firstIndex(of: maximized) {
                pane(maximized, index: index)
                    .padding(2)
            } else {
                layout(in: geometry.size)
            }
        }
        .background(Color(nsColor: .separatorColor))
    }

    @ViewBuilder
    private func layout(in size: CGSize) -> some View {
        let ids = workspace.state.orderedPaneIDs
        switch workspace.state.layout {
        case .single:
            if let first = ids.first { pane(first, index: 0) }
        case .vertical:
            axisSplit(.horizontal, first: ids[safe: 0], second: ids[safe: 1], ratio: workspace.state.verticalRatio, size: size)
        case .horizontal:
            axisSplit(.vertical, first: ids[safe: 0], second: ids[safe: 1], ratio: workspace.state.horizontalRatio, size: size)
        case .leading:
            if ids.count >= 3 { splitLeading(ids: ids, size: size) } else { defensiveFallback(ids) }
        case .trailing:
            if ids.count >= 3 { splitTrailing(ids: ids, size: size) } else { defensiveFallback(ids) }
        case .top:
            if ids.count >= 3 { splitTop(ids: ids, size: size) } else { defensiveFallback(ids) }
        case .bottom:
            if ids.count >= 3 { splitBottom(ids: ids, size: size) } else { defensiveFallback(ids) }
        case .grid:
            if ids.count >= 4 { grid(ids: ids, size: size) } else { defensiveFallback(ids) }
        }
    }

    @ViewBuilder
    private func axisSplit(_ axis: Axis, first: UUID?, second: UUID?, ratio: Double, size: CGSize) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                if let first { pane(first).frame(width: max(1, size.width * ratio - dividerThickness / 2)) }
                DividerHandle(axis: .horizontal, ratio: ratio, containerExtent: size.width) { workspace.setRatios(vertical: $0) } reset: { workspace.setRatios(vertical: 0.5) }
                    .frame(width: dividerThickness)
                if let second { pane(second).frame(maxWidth: .infinity) }
            }
        } else {
            VStack(spacing: 0) {
                if let first { pane(first).frame(height: max(1, size.height * ratio - dividerThickness / 2)) }
                DividerHandle(axis: .vertical, ratio: ratio, containerExtent: size.height) { workspace.setRatios(horizontal: $0) } reset: { workspace.setRatios(horizontal: 0.5) }
                    .frame(height: dividerThickness)
                if let second { pane(second).frame(maxHeight: .infinity) }
            }
        }
    }

    private func splitLeading(ids: [UUID], size: CGSize) -> some View {
        HStack(spacing: 0) {
            pane(ids[0]).frame(width: size.width * workspace.state.verticalRatio - dividerThickness / 2)
            verticalHandle(containerWidth: size.width)
            VStack(spacing: 0) {
                pane(ids[1]).frame(height: size.height * workspace.state.horizontalRatio - dividerThickness / 2)
                horizontalHandle(containerHeight: size.height)
                pane(ids[2])
            }
        }
    }

    private func splitTrailing(ids: [UUID], size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                pane(ids[0]).frame(height: size.height * workspace.state.horizontalRatio - dividerThickness / 2)
                horizontalHandle(containerHeight: size.height)
                pane(ids[1])
            }
            verticalHandle(containerWidth: size.width)
            pane(ids[2])
        }
    }

    private func splitTop(ids: [UUID], size: CGSize) -> some View {
        VStack(spacing: 0) {
            pane(ids[0]).frame(height: size.height * workspace.state.horizontalRatio - dividerThickness / 2)
            horizontalHandle(containerHeight: size.height)
            HStack(spacing: 0) {
                pane(ids[1]).frame(width: size.width * workspace.state.verticalRatio - dividerThickness / 2)
                verticalHandle(containerWidth: size.width)
                pane(ids[2])
            }
        }
    }

    private func splitBottom(ids: [UUID], size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pane(ids[0]).frame(width: size.width * workspace.state.verticalRatio - dividerThickness / 2)
                verticalHandle(containerWidth: size.width)
                pane(ids[1])
            }
            horizontalHandle(containerHeight: size.height)
            pane(ids[2])
        }
    }

    private func grid(ids: [UUID], size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pane(ids[0]).frame(width: size.width * workspace.state.verticalRatio - dividerThickness / 2)
                verticalHandle(containerWidth: size.width)
                pane(ids[1])
            }.frame(height: size.height * workspace.state.horizontalRatio - dividerThickness / 2)
            horizontalHandle(containerHeight: size.height)
            HStack(spacing: 0) {
                pane(ids[2]).frame(width: size.width * workspace.state.verticalRatio - dividerThickness / 2)
                verticalHandle(containerWidth: size.width)
                pane(ids[3])
            }
        }
    }

    private func verticalHandle(containerWidth: CGFloat) -> some View {
        DividerHandle(axis: .horizontal, ratio: workspace.state.verticalRatio, containerExtent: containerWidth) { workspace.setRatios(vertical: $0) } reset: { workspace.setRatios(vertical: 0.5) }
            .frame(width: dividerThickness)
    }

    private func horizontalHandle(containerHeight: CGFloat) -> some View {
        DividerHandle(axis: .vertical, ratio: workspace.state.horizontalRatio, containerExtent: containerHeight) { workspace.setRatios(horizontal: $0) } reset: { workspace.setRatios(horizontal: 0.5) }
            .frame(height: dividerThickness)
    }

    @ViewBuilder
    private func defensiveFallback(_ ids: [UUID]) -> some View {
        if ids.isEmpty {
            ContentUnavailableView("ペインを復元できません", systemImage: "exclamationmark.triangle")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    pane(id, index: index)
                }
            }
        }
    }

    private func pane(_ id: UUID, index: Int? = nil) -> some View {
        let resolvedIndex = index ?? workspace.state.orderedPaneIDs.firstIndex(of: id) ?? 0
        return PaneView(paneID: id, paneNumber: resolvedIndex + 1)
            .id(id)
            .padding(1)
    }
}

struct DividerHandle: View {
    let axis: Axis
    let ratio: Double
    let containerExtent: CGFloat
    let changed: (Double) -> Void
    let reset: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .overlay {
                DividerInteractionView(
                    axis: axis, ratio: ratio, containerExtent: containerExtent,
                    changed: changed, reset: reset
                )
                // This overlay extends outside the 2pt layout slot. It keeps a
                // 10pt pointer target while the visible/layout divider remains 2pt.
                .frame(
                    width: axis == .horizontal ? DividerMetrics.pointerHitThickness : nil,
                    height: axis == .vertical ? DividerMetrics.pointerHitThickness : nil
                )
            }
            .accessibilityLabel(axis == .horizontal ? "縦ディバイダ" : "横ディバイダ")
            .accessibilityAdjustableAction { direction in
                changed(ratio + (direction == .increment ? 0.01 : -0.01))
            }
    }
}

enum DividerMath {
    static func updatedRatio(start: Double, translation: CGFloat, containerExtent: CGFloat) -> Double {
        start + translation / max(containerExtent, 1)
    }
}

enum DividerMetrics {
    static let visibleThickness: CGFloat = 2
    static let pointerHitThickness: CGFloat = 10
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
