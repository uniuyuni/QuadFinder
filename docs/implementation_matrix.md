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
| ペインごとの複数タブ | 2 | 実装済み | 独立履歴・選択・表示・bookmark、タブ操作メニューの標準indicator単一表示 |
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
| サイドバー・外部変更監視 | 4 | 実装済み | bookmark付きfavorite、既定100pt、非表示中の幅保持、全section共通20pt行・12pt文字・16pt icon、既定SF Symbolのappearance対応accent tintとcustom NSWorkspace color icon、グローバル座標基準の無振動リサイズ、mount通知、Trash、取り出し可能デバイスのeject UI・busy/error処理、成功時に該当全ペインをhomeへ復帰、device/recent-folder行はFinder準拠file-operation drop、Favoritesは単一NSTableViewが選択・private reorder・標準挿入線・row-on file operationを所有しfolder追加とfile拒否を分離、上端・左端・全幅固定の決定論的container geometry、150ms debounce |
| 比較コピー・移動 | 4 | 実装済み | 専用sheet、4ポリシー、action summary、個別選択、stale再検証、Window Queue |
| パンくず・ステータス行 | 4 | 実装済み | 各階層へ移動／パスコピー、項目・選択・容量表示 |
| 4表示形式 | 4 | 実装済み | 全幅リスト、アイコン、任意深度カラム、lazy任意深度ツリー、symlink展開防止、ツリー展開状態に同期する右／下矢印、狭幅対応表示メニュー |
| Trash／symbolic link D&D | 4 | 実装済み | AppKit優先Trash destination、内部／外部payload、Command+Option link、全件競合preflight |
| バージョン | 4 | 実装済み | `AppVersion.swift`と標準About panel |
| Sidebar履歴・列ソート | 5 | 実装済み | 最近のfolder/file永続履歴、List/Treeにfile論理size・更新日時・iCloud状態を表示、共通sort、タブ単位保存 |
| 外部drag・進捗 | 5 | 実装済み | native file URL provider、link cursor、右上Queue summary |
| 操作履歴・Undo/Redo | 5 | 実装・検証済み | versioned bounded journal、bookmark、fingerprint、実Trash URL、partial outcome、共有Queue、large確認。復元URL欠落stepのみ理由付き非Undo |
| フォルダサイズ | 5 | 実装済み | 明示開始、async progress/cancel、symlink非追跡、partial error、0.5秒UI進捗coalesce、15秒cache、深い子変更からの祖先invalidation |
| リスト／ツリーカラム | 5 | 実装済み | native header/cell同一配置、user resize、min/max clamp、ペイン・表示別幅保存、header sort |
| アプリアイコン | 5 | 実装・検証済み | 独自原画、16〜1024pxの10 PNG、ICNS、配布appのCFBundleIconFile |
| 画像表示モジュール | 6 | 実装・検証済み | ImageIO非同期downsample、zoom、選択追従、外部更新・stale load抑止 |
| Hexビューアー | 6 | 実装・検証済み | bounded paging/LRU、offset/hex/ASCII、go-to、8/16/32 bytes、外部更新 |
| テキストエディタ | 7 | 実装・検証済み | native plain editor、encoding/newline維持、安全保存、外部競合、保存Undo/Redo、Cmd-S/A first responder routing、ペイン全選択、未保存切替・閉鎖guard、再表示時AppKit responder再構成、binary→Hex |
| 大容量テキスト | 7 | 実装・検証済み | 64KiB paging/64MB LRU、2MiB virtual window、offset/line/search/cancel、file-backed Piece Table、stream save、1GB read-only policy |

## 自動テスト範囲

2026-07-13統合検証: `swift build`成功、35スイート・223テスト成功、失敗0件。テキストencoding/newline、安全atomic保存・外部競合、1GB疎ファイルbounded read、Piece Table Undo/Redo/stream、段階行索引・ページ跨ぎ検索、module migration、テキスト保存履歴、Cmd-S/A responder routing、全選択fallback、未保存切替・閉鎖state machine、AppKit editor破棄・再生成後の通常入力／矢印キー回帰、画像・Hex・テキスト共通のサイドモジュール幅ポリシーと旧テキスト幅移行、タブメニューindicator重複防止、ツリー矢印の展開・閉鎖・reload同期、ペイン全域double-click monitorのselection fallback排除とcontent URL限定pointer-open、リスト／カラム／ツリーの名前実描画領域geometry、単一native Favorites tableによる0/1/5/20件の20pt高さ・上端/左端/全幅geometry、16pt icon・文字baseline、light/dark/selected tint・custom color icon、20回高速reorder・永続化・row-on／insertion分離・external folder追加／file拒否、Sidebar row transfer／TrashとFinder modifier/volume matrixを含む。

- Phase 1: 全レイアウト、正規化、ナビゲーション、ペイン操作、D&Dソース判定、永続化、ファイル安全性
- Phase 2: v1→v2移行、タブ独立性と移動・複製、宛先明示とURL固定、キュー順序・キャンセル・失敗継続、ペインセット破損分離、モジュール文脈
- Phase 3: link正規化・伝播・欠落、Pair、全比較分類・checksum・cancel、同期3モード・安全フラグ・stale、Queue同期、cache dedup、v2→v3、単一Window方針
- Phase 4: rename／duplicate／clipboard権限、転送4ポリシー、stale fingerprint、上書き・削除確認、self-copy／descendant拒否、move成功後source削除
- 入力回帰: active pane／text editingに基づくSpace Quick Lookルーティング
- Phase 5: Sidebar幅移行・履歴、List/Tree sort永続化、Queue進行集計、journal境界・破損分離・move undo/redo・large policy、folder size/cancel/symlink
- Finder drag: same/cross-volume×modifier操作マトリクス、native pasteboard、Dock delete mask、衝突時だけplannerへ遷移
- Conflict auto rename: preview、競合race時の次候補、copy/move outcomeとUndo/Redo
- APFS clone: clone高速経路、失敗時streaming fallback、対象外volumeのdeep-copy経路、atomic progress
- Removable eject: ejectable判定、デバイスURL固定、busy状態解除、操作可能な日本語エラー
- Folder size performance: 2,000項目の正確な集計、0.5秒未満の中間通知抑制、開始・最終通知、即時cache再利用、深い子変更による祖先cache無効化、cancel
- Text editor: BOM/日本語encoding・改行round-trip、binary判定、安全save失敗時の原本維持、外部inode/stamp競合、1GB sparse bounded read、LRU、Piece Table編集/Undo/Redo/stream、line/search cancel/stale、workspace migration、保存履歴Undo/Redo、Cmd-S/A native routing、dirty selection/close→save/discard/cancel、save failure restoration、rapid selection/close coalescing、close/recreate後の通常文字入力とarrow movement

実際のpasteboard表現選択、マウス操作、VoiceOver、署名済みSandbox環境の外部ボリューム権限は手動検証対象です。
