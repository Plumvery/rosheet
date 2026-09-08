# Changelog

このプロジェクトの主だった変更をここに残す。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、バージョンは
[Semantic Versioning](https://semver.org/lang/ja/) に従う。1.0 より前は、破壊的変更でマイナーを上げる。

## [0.1.0] - 2026-09-09

### Added

- **ダブルクリックで入るプラグインのインストーラーを、各 Release に添付する。** プラグインを入れるのに Node と npm を入れて `rosheet plugin` を叩く必要があり、値を触るだけの人に求めるには重かった。`scripts/build-installers.js` が `rosheet-plugin-installer-windows.cmd` と `rosheet-plugin-installer-macos.zip` を組み立て、リリースの workflow が添付する。プラグインには何も焼き込まないので、`.rbxmx` を base64 で各インストーラーの中に抱えられる。置き先とファイル名は `rosheet plugin` と同じで、インストール時に通信しない。macOS 版を zip で包むのは、Release のアセットにパーミッションが残らず、実行ビットの落ちた `.command` はダブルクリックできないため。`rosheet.rbxmx` 単体も、手で置きたい人向けに添付する。
- スキーマをコードで定義する（Luau / roblox-ts）。列の型・readonly・既定値・enum の候補・数値の範囲を宣言し、Luau 側と JS 側で同じ正規形に落ちることをテストで検査している。
- Studio プラグイン。宣言したシートごとに表ビューを出し、編集できる列だけ編集させ、Apply でプレイテスト中の値を差し替える。設定もスキーマもアセット一覧も焼き込まず、place の中から読む。
- DataStore を編集の正とする履歴。1 回の Apply が 1 つの commit として積まれ、`log` で一覧、`revert` で任意の時点へ戻す commit を積める。
- CLI: `init` / `plugin` / `runtime` / `pull` / `check` / `log` / `revert` / `export` / `import` / `schema`。`check` は生成物が現在値とずれていれば落ちるので、Apply の取り込み忘れを CI で捕まえられる。
- `rosheet runtime`。`runtime/` を利用側のプロジェクトへ複製する。roblox-ts のプロジェクトからは `node_modules` の中の `.d.ts` へ型として届かない（npm スコープを typeRoots に足すと、`types` を持たないパッケージが暗黙の型ライブラリとして落ちる）ので、rbxtsc と Rojo が元から見ている木の中へ置く。
- 型付きのコード生成。`*.luau`（`--!strict`）と、roblox-ts 向けの `*.luau` + `*.d.ts`。
- CSV の出入り（`export` / `import`）。スプレッドシートや外部ツールとの退路で、CSV は正ではない。
- ランタイムの `bind`。Apply を反映させたいところだけ live 反映を通し、本番では同梱値をそのまま返す。
- `runtime/init.luau`。`schema` と `live` をまとめて返すので、`require(ReplicatedStorage.Packages.rosheet)` 1 本から `defineSchema` も `bind` も取れる（roblox-ts 向けの型は `runtime/index.d.ts`）。
- `asset` 列の rocas 連携。`rocas://assets/...` を書くと Studio で補完とサムネイルが出て、`pull` のときに `rbxassetid://` へ解決される。

### Fixed

- スキーマを直して Rojo が同期しても、プラグインが古いスキーマのままだった。`require` はモジュールの戻り値をインスタンス単位で恒久的にキャッシュし、Rojo は同じインスタンスの Source を書き換えるだけなので、Reload を押しても直らなかった。読むたびに写しを作って require する。
- スキーマが新しくなっても、表のセルが作り直されていなかった。シート名しか見ていなかったので、`readonly` を足しても TextBox のままだった。列の名前・型・readonly・既定値・enum の候補まで含めて見分ける。
- キー列が `readonly` で `rows = "open"` の表で、足した行の key を直せなかった（`new1` のまま確定して消すしかなかった）。まだ Apply していない行に限って、キー列を書き換えられるようにした。空と重複はその場で弾く。

### Note

- pre-alpha。**Studio の実機での往復（実 DataStore との疎通、Apply からプレイテストへの反映、rocas のアセット読み取り）はまだ確認していない。** 確かめた範囲は [README の進捗](README.md#進捗) を参照。
