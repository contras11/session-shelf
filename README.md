# Session Shelf

Session Shelfは、AI開発ツールがローカルに保存した過去セッションを、人間が読みやすい形で確認するためのmacOSネイティブアプリです。SwiftUIで実装しています。

## 主な機能

- Codex、Claude Code、Cursor Desktop、Cursor CLI、Grok Build CLIを最上位で分けて表示
- セッション一覧にタイトル、更新日時、容量、関連プロジェクト、短い概要を表示
- 詳細画面を「会話」「操作履歴」「変更したファイル」「生ログ」に分けて表示
- CursorのプランMarkdownを閲覧
- CursorとGrokのプランを、概要・タスク・Markdown本文に分けた専用画面で表示
- システム指示や実行環境は通常会話から分離し、必要なときだけ展開
- タイトル・概要・プロジェクト名によるローカル検索
- 対応する保存場所がない場合は「未検出」、場所はあるが読めない場合は「未対応の保存形式」と想定パス候補を表示
- 対応済みの非アクティブなセッションをmacOSのゴミ箱へ移動

## ローカル性と安全性

- ログの読み取り、検索、概要生成はすべてMac内で完結します。
- 外部通信、クラウド要約、解析APIへの送信は行いません。
- 元ログをこのプロジェクトへコピーしません。画面表示時に保存元を読み取り専用で開きます。
- 削除操作は完全削除ではなく、macOSのゴミ箱への移動だけです。
- 移動前に確認を表示し、保存場所の外にあるファイルは拒否します。

## 検出対象

| ツール | 対応する主な保存形式・場所 |
|---|---|
| Codex | `~/.codex/sessions`、`~/.codex/archived_sessions`のJSONL |
| Claude Code | `~/.claude/projects`、`~/.claude/sessions`のJSONL |
| Cursor Desktop | `~/.cursor/plans`のプランMarkdown。Desktop内部SQLiteは検出のみ |
| Cursor CLI | `~/.cursor/projects/*/agent-transcripts`のJSONL。`~/.cursor/chats`の内部SQLiteは検出のみ |
| Grok Build CLI | `~/.grok/sessions`のセッションディレクトリ、要約、会話JSONL、プランMarkdown |

保存形式は各ツールの公開契約ではないため、形式が変わったログは安全側に倒して「未対応の保存形式」と表示します。

## 保護対象

次の項目はゴミ箱へ移す対象にしません。

- 更新から30分以内で、作業中の可能性があるセッション
- Cursorの内部SQLiteなど、設定・認証・状態データを含む可能性がある保存物
- プラグイン、キャッシュ、認証情報、ツール設定
- サブエージェントだけの補助ログ
- 対応保存場所の外にあるファイル

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
