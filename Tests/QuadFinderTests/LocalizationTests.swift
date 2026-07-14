import Foundation
import Testing
@testable import QuadFinder

@Suite("Localization")
struct LocalizationTests {
    private static let dynamicKeys: Set<String> = [
        "フォルダ", "ファイル", "キューで待機しています…", "実行しています…", "処理をキャンセル",
        "サイドバーを隠す", "サイドバーを表示", "最大化", "元に戻す", "アクティブ", "非アクティブ",
        "選択中", "非選択", "グリッドに戻す", "縦ディバイダ", "横ディバイダ",
        "1GB以上：読み取り専用", "大容量編集モード", "大容量読み取りモード",
        "1つのファイルを選択してください", "テキストファイルを選択してください",
        "ホーム", "デスクトップ", "書類", "ダウンロード", "ゴミ箱",
        "存在しない項目のみ", "新しい項目のみ", "同期（ターゲットを一致）", "自動で名前を変更",
        "フォルダを統合", "ターゲットから削除", "ソースのみ", "ターゲットのみ", "差異あり",
        "同一", "エラー", "片方向更新", "片方向ミラー", "欠落項目のみ", "待機中", "実行中", "完了", "失敗"
    ]

    @Test("Japanese is selected only when the primary system language is Japanese")
    func languageSelection() {
        #expect(AppLanguage.resolve(preferredLanguages: ["ja-JP", "en-US"]) == .japanese)
        #expect(AppLanguage.resolve(preferredLanguages: ["en-US", "ja-JP"]) == .english)
        #expect(AppLanguage.resolve(preferredLanguages: ["fr-FR"]) == .english)
        #expect(AppLanguage.resolve(preferredLanguages: []) == .english)
    }

    @Test("Both localization resources resolve known UI text")
    func resourceLookup() {
        #expect(L10n.tr("閉じる", language: .japanese) == "閉じる")
        #expect(L10n.tr("閉じる", language: .english) == "Close")
        #expect(L10n.tr("ファイルを選択してください", language: .english) == "Select a file")
    }

    @Test("Localized format strings keep their arguments")
    func formattedText() {
        #expect(L10n.format("%lld項目", Int64(4), language: .japanese) == "4項目")
        #expect(L10n.format("%lld項目", Int64(4), language: .english) == "4 items")
    }

    @Test("Every statically referenced key has complete Japanese and English resources")
    func resourcesAreComplete() throws {
        let required = try Self.sourceKeys().union(Self.dynamicKeys)
        let japanese = try Self.table(language: "ja")
        let english = try Self.table(language: "en")
        #expect(required.subtracting(japanese.keys).isEmpty)
        #expect(required.subtracting(english.keys).isEmpty)
        let japaneseCharacters = try NSRegularExpression(pattern: "[ぁ-んァ-ヶ一-龠]")
        for key in required {
            let value = try #require(english[key])
            let range = NSRange(value.startIndex..., in: value)
            #expect(japaneseCharacters.firstMatch(in: value, range: range) == nil, "English value remains Japanese for key: \(key)")
        }
    }

    @Test("Translations preserve printf argument types")
    func formatArgumentsMatch() throws {
        let english = try Self.table(language: "en")
        for key in try Self.sourceKeys() {
            let value = try #require(english[key])
            #expect(try Self.placeholderTypes(in: key).sorted() ==
                    Self.placeholderTypes(in: value).sorted(),
                    "Format arguments differ for key: \(key)")
        }
    }

    private static func table(language: String) throws -> [String: String] {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private static func sourceKeys() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/QuadFinder")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let expression = try NSRegularExpression(pattern: #"L10n\.(?:tr|format)\("((?:\\.|[^"\\])*)""#)
        var result: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in Self.matches(expression, in: source) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let encoded = Data(("\"" + source[range] + "\"").utf8)
                if let key = try? JSONDecoder().decode(String.self, from: encoded) { result.insert(key) }
            }
        }
        return result
    }

    private static func matches(_ expression: NSRegularExpression, in value: String) -> [NSTextCheckingResult] {
        expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func placeholderTypes(in value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(lld|d|@)")
        return Self.matches(expression, in: value).compactMap { match in
            Range(match.range(at: 1), in: value).map { String(value[$0]) }
        }
    }
}
