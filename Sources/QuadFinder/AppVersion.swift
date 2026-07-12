import AppKit

/// Single source of truth for development builds. Distribution builds may
/// override these values with MARKETING_VERSION/CURRENT_PROJECT_VERSION.
enum AppVersion {
    static let marketing = "1.2.1"
    static let build = "4"

    static var display: String { "Version \(marketing) (\(build))" }

    @MainActor
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "QuadFinder",
            .applicationVersion: marketing,
            .version: build,
            .credits: NSAttributedString(string: "最大4ペインのmacOSファイルマネージャ")
        ])
    }
}
