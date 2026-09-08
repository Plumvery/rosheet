# Changelog

このプロジェクトの主だった変更をここに残す。

書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/)、バージョンは
[Semantic Versioning](https://semver.org/lang/ja/) に従う。1.0 より前は、破壊的変更でマイナーを上げる。

## [Unreleased]

### Added

- スキーマをコードで定義する（Luau / roblox-ts）。列の型・readonly・既定値・enum の候補・数値の範囲を宣言し、Luau 側と JS 側で同じ正規形に落ちることをテストで検査している。
- Studio プラグイン。宣言したシートごとに表ビューを出し、編集できる列だけ編集させ、Apply でプレイテスト中の値を差し替える。設定もスキーマもアセット一覧も焼き込まず、place の中から読む。
- DataStore を編集の正とする履歴。1 回の Apply が 1 つの commit として積まれ、`log` で一覧、`revert` で任意の時点へ戻す commit を積める。
- CLI: `init` / `plugin` / `pull` / `check` / `log` / `revert` / `export` / `import` / `schema`。`check` は生成物が現在値とずれていれば落ちるので、Apply の取り込み忘れを CI で捕まえられる。
- 型付きのコード生成。`*.luau`（`--!strict`）と、roblox-ts 向けの `*.luau` + `*.d.ts`。
- CSV の出入り（`export` / `import`）。スプレッドシートや外部ツールとの退路で、CSV は正ではない。
- ランタイムの `bind`。Apply を反映させたいところだけ live 反映を通し、本番では同梱値をそのまま返す。
- `asset` 列の rocas 連携。`rocas://assets/...` を書くと Studio で補完とサムネイルが出て、`pull` のときに `rbxassetid://` へ解決される。

### Note

- pre-alpha。**Studio の実機での往復（実 DataStore との疎通、Apply からプレイテストへの反映、rocas のアセット読み取り）はまだ確認していない。** 確かめた範囲は [README の進捗](README.md#進捗) を参照。
