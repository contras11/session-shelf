# Session Shelf

Session Shelfは、AI開発ツールがローカルに保存した過去セッションを、人間が読みやすい形で確認するためのmacOSネイティブアプリです。SwiftUIで実装しています。

## 主な機能

- Codex、Claude Code、Cursor Desktop、Cursor CLI、Grok Build CLI、OpenCodeを最上位で分けて表示
- セッション一覧にタイトル、更新日時、容量、関連プロジェクト、短い概要を表示
- CodexとOpenCodeのサブエージェントを親セッションの下へ折りたたみ表示
- 詳細画面を「会話」「操作履歴」「変更したファイル」「生ログ」に分けて表示
- CursorのプランMarkdownを閲覧
- CursorとGrokのプランを、概要・タスク・Markdown本文に分けた専用画面で表示
- システム指示や実行環境は通常会話から分離し、必要なときだけ展開
- タイトル・概要・プロジェクト名によるローカル検索
- 対応する保存場所がない場合は「未検出」、場所はあるが読めない場合は「未対応の保存形式」と想定パス候補を表示
- 対応済みの非アクティブなセッションをmacOSのゴミ箱へ移動（OpenCodeは公式CLIによる不可逆削除）
- Claude Code・Cursor CLI・Codexでは、会話ログと同じセッションの関連ファイルも一緒にゴミ箱へ移動
- 親セッションの削除時は、配下のサブエージェントを子から親の順にまとめて削除
- 6ツールのキャッシュ、一時ファイル、生成物、診断記録を用途と安全度ごとに可視化
- サイドバーのストレージ配下から、各ツールの容量と整理候補へ切り替え
- 各サービスの公式アイコンを表示し、「設定…」から表示・非表示と並び順を変更
- 「再生成可能」「要確認」「保護」の3段階で影響を説明し、確認後に安全な項目をゴミ箱へ移動

## ローカル性と安全性

- ログの読み取り、検索、概要生成はすべてMac内で完結します。
- 外部通信、クラウド要約、解析APIへの送信は行いません。
- 元ログをこのプロジェクトへコピーしません。画面表示時に保存元を読み取り専用で開きます。
- 通常5ツールの削除はmacOSのゴミ箱へ移動します。OpenCodeだけは専用警告後、公式CLIでゴミ箱を経由せず完全削除します。
- Claude Codeは会話JSONLに加え、同じIDの作業ディレクトリ、`file-history`、`session-env`、`tasks`を一緒に移します。Cursor CLIは会話ディレクトリごと移します。Codexは一致する`shell_snapshots`も移します。Codexの`session_index.jsonl`と内部SQLiteは共有索引のため書き換えません。
- Codexの`parent_thread_id`とOpenCodeの`parent_id`を使って親子関係を表示します。親が見つからないサブエージェントは「親なし」と表示します。
- 親セッションをゴミ箱へ移すときは、配下のサブエージェントも削除候補へ含めます。保護中または未対応の子がある場合は、親だけを削除して孤立させないよう操作を拒否します。
- 移動前に確認を表示し、保存場所の外にあるファイルは拒否します。
- 削除直前に更新時刻とシンボリックリンクを再確認します。確認後に内容が変わった項目は移動しません。
- ストレージ整理は既知の保存場所だけを対象にし、削除直前に容量・更新日時・安全判定を再確認します。
- シンボリックリンク、更新から30分以内の項目、用途を確認できない項目は保護します。

## 検出対象

| ツール | 対応する主な保存形式・場所 |
|---|---|
| Codex | `~/.codex/sessions`、`~/.codex/archived_sessions`のJSONL |
| Claude Code | `~/.claude/projects`、`~/.claude/sessions`のJSONL |
| Cursor Desktop | `~/.cursor/plans`のプランMarkdown。Desktop内部SQLiteは検出のみ |
| Cursor CLI | `~/.cursor/projects/*/agent-transcripts`のJSONL。`~/.cursor/chats`の内部SQLiteは検出のみ |
| Grok Build CLI | `~/.grok/sessions`のセッションディレクトリ、要約、会話JSONL、プランMarkdown |
| OpenCode | `~/.local/share/opencode/opencode.db`（session/message/partのみ読み取り） |

保存形式は各ツールの公開契約ではないため、形式が変わったログは安全側に倒して「未対応の保存形式」と表示します。

## 保護対象

次の項目はゴミ箱へ移す対象にしません。

OpenCodeの「完全に削除」はゴミ箱を経由せず、公式CLI `opencode session delete <ID>` を実行します。CLIは`PATH`を優先し、HomebrewとMacPortsの標準パスも確認します。空または相対的な`PATH`要素は使用しません。削除直前に存在・更新時刻・圧縮状態を再確認し、CLIがない場合や状態が変わった場合は実行しません。

OpenCodeのストレージは`~/.local/share/opencode`、`~/.local/state/opencode`、`~/.cache/opencode`、`~/.config/opencode`を対象に可視化します。cacheの既知項目は再生成可能、shareのlog・tool-outputとstateのprompt-historyは要確認、DB・auth・config・未知形式は保護対象です。

- 更新から30分以内で、作業中の可能性があるセッション
- Cursorの内部SQLiteなど、設定・認証・状態データを含む可能性がある保存物
- インストール済みプラグイン、認証情報、ツール設定
- 認証・設定・状態SQLite、メモリ、ユーザースキル、ユーザープラグイン、拡張機能、worktree
- サブエージェントだけの補助ログ（親セッションをゴミ箱へ移すときは、同じディレクトリ内なら一緒に移します）
- 対応保存場所の外にあるファイル

キャッシュや古い一時バックアップは「再生成可能」として表示します。生成画像や診断ログなど、削除後に戻せない可能性があるデータは「要確認」とし、通常より強い確認を表示します。いずれも自動削除は行いません。

## 実行方法

必要環境はmacOS 14以降とSwift 6です。

```sh
git clone https://github.com/contras11/session-shelf.git
cd session-shelf
swift run SessionShelf
```

Xcodeでは`Package.swift`を開き、`SessionShelf`スキームを実行してください。Swift Package Managerが`Sources`配下の新規Swiftファイルをターゲットへ自動追加します。

通常のmacOSアプリバンドルは次のコマンドで作成できます。

```sh
./scripts/build_app.sh
```

生成物は`dist/Session Shelf.app`です。Info.plist、複数解像度のアプリアイコン、実行権限、ローカル実行用のad-hoc署名を含みます。
サービスアイコンとサイドバー設定もbundleへ含まれ、表示順と表示状態はmacOSのユーザー設定へ保存されます。

この環境では、SwiftPMだけで実行できる自己完結型の検証ランナーを用意しています。

```sh
swift run SessionShelfChecks
```

## 既知の制限

- Cursor Desktopの会話SQLiteと、新しいCursor CLIの`store.db`は内部形式のため、初回版では本文を解析しません。保存先は検出し、「未対応の保存形式」として保護します。
- 操作の成否を元ログで明示できない場合は「結果不明」と表示します。
- 「変更したファイル」は編集系ツール呼び出しにファイルパスが含まれる場合だけ抽出できます。
- 巨大ログはメモリ消費を抑えるため、一覧解析、詳細表示、生ログ表示を上限付きで読み込み、省略を画面に表示します。
- 各ツールの保存形式変更後は、パーサーの更新が必要になる場合があります。
