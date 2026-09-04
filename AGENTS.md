# Session Shelf リポジトリ運用規約

この文書は、このリポジトリ内の作業に対してグローバル規約へ追加して適用する。

## 正本と構成

- 機能・安全性・対応保存形式の正本は `README.md` とする。
- SwiftPMターゲットと依存関係の正本は `Package.swift` とする。
- セッション解析と削除境界は `Sources/SessionShelfCore`、UI状態と表示は `Sources/SessionShelf` に分ける。
- OpenCodeのSQLiteは読み取り専用で開き、削除は公式CLIだけに委譲する。生ログや認証情報をテストfixture、文書、出力へ複製しない。

## 安全性の不変条件

- セッションとストレージの削除前に、許可ルート、保護状態、更新時刻、シンボリックリンク、現在の分類を再確認する。
- OpenCodeセッションはゴミ箱へ移さず、30分保護・圧縮中保護・更新時刻一致を確認してから `opencode session delete <ID>` を直接実行する。
- `PATH`から実行ファイルを探索するときは空要素と相対パスを拒否し、シェルを介さない。
- 非同期処理の結果はMainActorへ戻してからUI状態へ反映し、二重実行と古い結果の反映を防ぐ。

## 検証と配布

- 通常変更では `swift test`、`swift run SessionShelfChecks`、`swift build`、`git diff --check` を実行する。
- 配布変更では `./scripts/build_app.sh` に加え、生成bundleのplistとcodesignを検証する。
- 正式なローカル配置先は `/Users/contras11/Applications/Session Shelf.app` とし、`/Applications`へ新しいbundleを配置しない。同じbundle IDを持つ旧版が別の場所に残っている場合は、パス、更新時刻、binary hashを照合して旧版と確定してからゴミ箱へ移す。
- 正式アプリの更新時は、生成bundleを一時領域へstageしてplist、codesign、binary hashを検証し、起動中の旧版を終了してから正式配置先を置換する。旧bundleは上書きや完全削除をせず、識別できる名前でゴミ箱へ退避する。
- 置換後は旧版と開発用artifactをLaunch Servicesの起動候補から外し、正式配置先の最新版だけを再登録する。通常の `open -a "Session Shelf"` で起動し、実行中processの絶対パスとインストール済みbinaryのhashが最新版に一致することを確認する。
- ゴミ箱へ退避した旧アプリを完全削除したり、他の項目を含むゴミ箱全体を空にしたりする操作は、別の明示依頼がある場合だけ行う。
- ローカルテスト、artifact、インストール済みアプリ、commit、remote同期、GitHub Actionsを別々の状態として確認・報告する。
- commit、push、GitHub Actionsや配布先への書き込みはユーザーの明示依頼がある場合だけ実行する。
