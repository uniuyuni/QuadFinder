import AppKit

/// Single source of truth for development builds. Distribution builds may
/// override these values with MARKETING_VERSION/CURRENT_PROJECT_VERSION.
enum AppVersion {
    static let marketing = "1.4.0"
    static let build = "11"

    static var display: String { L10n.format("バージョン %@（%@）", marketing, build) }

    @MainActor
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "QuadFinder",
            .applicationVersion: marketing,
            .version: build,
            .credits: NSAttributedString(string: L10n.tr("最大4ペインのmacOSファイルマネージャ"))
        ])
    }
}
