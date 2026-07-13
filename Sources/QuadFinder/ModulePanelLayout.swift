import CoreGraphics

/// One sizing contract for every side module. Keeping this outside an
/// individual module prevents Image, Hex and Text from drifting apart again.
struct ModulePanelWidthPolicy: Equatable, Sendable {
    let minimumWidth: CGFloat
    let idealWidth: CGFloat
    let maximumWidth: CGFloat

    func clamp(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return idealWidth }
        return min(maximumWidth, max(minimumWidth, width))
    }
}

enum ModulePanelLayout {
    static let policy = ModulePanelWidthPolicy(
        minimumWidth: 240,
        idealWidth: 320,
        maximumWidth: 560
    )

    // Named policies make the equality an explicit, testable contract.
    static let imagePolicy = policy
    static let hexPolicy = policy
    static let textPolicy = policy

    static let paneMinimumWidth: CGFloat = 180
    static let dividerWidth: CGFloat = 1

    // Compatibility names used by existing layout and tests.
    static var minimumWidth: CGFloat { policy.minimumWidth }
    static var idealWidth: CGFloat { policy.idealWidth }
    static var maximumWidth: CGFloat { policy.maximumWidth }

    static func normalizedPersistedWidth(_ width: CGFloat) -> CGFloat {
        policy.clamp(width)
    }

    /// Deterministic allocation used by tests and by future split-view work.
    /// The pane always keeps its minimum before a side module is expanded.
    static func moduleWidth(
        availableWidth: CGFloat,
        preferredWidth: CGFloat = idealWidth,
        dividerWidth: CGFloat = dividerWidth,
        paneMinimumWidth: CGFloat = paneMinimumWidth
    ) -> CGFloat {
        let room = max(0, availableWidth - dividerWidth - paneMinimumWidth)
        return min(policy.clamp(preferredWidth), room)
    }
}
