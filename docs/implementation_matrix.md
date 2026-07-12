# QuadFinder 仕様対応表

基準仕様: `docs/quad_pane_product_spec.md` Draft 1.0

| 仕様領域 | Phase | 状態 | 実装 |
| --- | --- | --- | --- |
| 1〜4ペインと全8レイアウト | 1 | 実装済み | `PaneGridView`、`WorkspaceState` |
| ペイン独立状態とアクティブ切替 | 1 | 実装済み | `PaneState`、`WorkspaceStore` |
| 追加・閉鎖・交換・一時最大化 | 1 | 実装済み | `WorkspaceStore`、ペインUI |
| 分割比率 | 1 | 実装済み | 実コンテナ寸法基準の`DividerHandle` |
| ペイン間D&D | 1 | 実装済み | 内部型付きpayload／外部URLを安全に分離 |
| 状態保存・v1復元 | 1/2 | 実装済み | v1を単一タブへ移行するv2 Codable state |
| ペインごとの複数タブ | 2 | 実装済み | 独立履歴・選択・表示・bookmark |
| タブのペイン間移動・複製 | 2 | 実装済み | タブメニューから明示操作 |
| 他ペインへコピー・移動 | 2 | 実装済み | F5/F6、複数候補は番号・名前・完全パスで選択 |
| ウィンドウ共有操作キュー | 2 | 実装済み | 直列処理、右端の進捗ポップオーバー、個別中止、完了済み項目のUndo履歴、失敗継続 |
| ペインセット | 2 | 実装済み | 名前付き保存・適用・削除、ファイル単位の破損分離 |
| Active/Pinned/Windowモジュール | 2 | 実装済み | 選択情報と操作キュー、表示・文脈保存 |
| Pairモジュール文脈 | 3 | 実装済み | Active＋明示ペイン、永続化・不正Pair正規化 |
| ペインリンク | 3 | 実装済み | 2〜4ペイン、相対ナビゲーション、選択追従、欠落通知 |
| フォルダ比較 | 3 | 実装済み | 名前・種類・サイズ・日時・任意SHA-256、固定snapshot、cancel |
| 片方向同期 | 3 | 実装済み | 更新・ミラー・欠落のみ、preview、二段階確認、stale拒否、Trash限定 |
| 双方向同期 | 3 | 未実装 | 安全な競合規則を定義できないため意図的に対象外 |
| 大規模・クラウド最適化 | 3 | 一部実装済み | in-flight dedup、2秒TTL＋明示fresh reload、非表示cancel、進捗coalesce、async checksum、未download読取回避。download要求と高度な監視重複排除は未実装 |
| Window scope | 3 | 実装済み | 単一`Window` scene。共有stateを持つ複製Windowを禁止 |
| 細い境界とマウス操作 | 4 | 実装済み | visible 2pt／hit 10pt、NSView cursor rect、18pt全幅List、非消費event routing、行／空白部クリック |
| Finder基本操作 | 4 | 実装済み | 4表示共通action model/menu、Command+C/X/V、clipboard減光、Space Quick Look、確認なしTrash、Get Info |
| サイドバー・外部変更監視 | 4 | 実装済み | bookmark付きfavorite、既定100pt、非表示中の幅保持、mount通知、Trash、150ms debounce |
| 比較コピー・移動 | 4 | 実装済み | 専用sheet、4ポリシー、action summary、個別選択、stale再検証、Window Queue |
| パンくず・ステータス行 | 4 | 実装済み | 各階層へ移動／パスコピー、項目・選択・容量表示 |
| 4表示形式 | 4 | 実装済み | 全幅リスト、アイコン、任意深度カラム、lazy任意深度ツリー、symlink展開防止、狭幅対応表示メニュー |
| Trash／symbolic link D&D | 4 | 実装済み | AppKit優先Trash destination、内部／外部payload、Command+Option link、全件競合preflight |
| バージョン | 4 | 実装済み | `AppVersion.swift`と標準About panel |
| Sidebar履歴・列ソート | 5 | 実装済み | 最近のfolder/file永続履歴、List/Tree共通sort、タブ単位保存 |
| 外部drag・進捗 | 5 | 実装済み | native file URL provider、link cursor、右上Queue summary |
| 操作履歴・Undo/Redo | 5 | 実装・検証済み | versioned bounded journal、bookmark、fingerprint、実Trash URL、partial outcome、共有Queue、large確認。復元URL欠落stepのみ理由付き非Undo |
| フォルダサイズ | 5 | 実装済み | 明示開始、async progress/cancel、symlink非追跡、partial error |

## 自動テスト範囲

2026-07-12統合検証: `swift build`警告なし、27スイート・122テスト成功、失敗0件。

- Phase 1: 全レイアウト、正規化、ナビゲーション、ペイン操作、D&Dソース判定、永続化、ファイル安全性
- Phase 2: v1→v2移行、タブ独立性と移動・複製、宛先明示とURL固定、キュー順序・キャンセル・失敗継続、ペインセット破損分離、モジュール文脈
- Phase 3: link正規化・伝播・欠落、Pair、全比較分類・checksum・cancel、同期3モード・安全フラグ・stale、Queue同期、cache dedup、v2→v3、単一Window方針
- Phase 4: rename／duplicate／clipboard権限、転送4ポリシー、stale fingerprint、上書き・削除確認、self-copy／descendant拒否、move成功後source削除
- 入力回帰: active pane／text editingに基づくSpace Quick Lookルーティング
- Phase 5: Sidebar幅移行・履歴、List/Tree sort永続化、Queue進行集計、journal境界・破損分離・move undo/redo・large policy、folder size/cancel/symlink
- Finder drag: same/cross-volume×modifier操作マトリクス、native pasteboard、Dock delete mask、衝突時だけplannerへ遷移
- Conflict auto rename: preview、競合race時の次候補、copy/move outcomeとUndo/Redo
- APFS clone: clone高速経路、失敗時streaming fallback、対象外volumeのdeep-copy経路、atomic progress

実際のpasteboard表現選択、マウス操作、VoiceOver、署名済みSandbox環境の外部ボリューム権限は手動検証対象です。
