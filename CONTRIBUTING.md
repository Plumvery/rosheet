# 開発

## テスト

JS 側:

```bash
npm test
```

Luau 側は [rokit](https://github.com/rojo-rbx/rokit) で lune を入れてから:

```bash
rokit install
lune run test/schema.test.luau
lune run test/normalize.test.luau
lune run test/session.test.luau
node test/cross-check.js
lune run test/plugin-syntax.test.luau
```

`test/cross-check.js` は `normalize.test.luau` が書いた `build/schema.luau.json` を読むので、その後に走らせる。Luau 側と JS 側でスキーマの正規化がずれていないかを見ている。

[`ci.yml`](.github/workflows/ci.yml) が push と PR で同じものを回す。

## リリース

バージョンは GitHub のリリースタグで管理する。npm へはまだ出していない。

1. [CHANGELOG.md](CHANGELOG.md) の `[Unreleased]` の見出しを、新しいバージョンと日付に書き換える
2. `package.json` の `version` を上げる（1.0 より前は、破壊的変更でマイナーを上げる）
3. `main` へマージしてから、その commit にタグを打って push する

```bash
git tag v0.2.0
git push origin v0.2.0
```

[`release.yml`](.github/workflows/release.yml) がこれを拾い、[`ci.yml`](.github/workflows/ci.yml) のテスト（node と Luau）を通してから GitHub Release を作る。本文は CHANGELOG のそのバージョンの節がそのまま入る。Studio プラグインのインストーラーもそこへ添付される。

タグと `package.json` がずれていたり、CHANGELOG にその節が無かったりすると、Release は作られずに落ちる。直したら、タグを打ち直す:

```bash
git tag -d v0.2.0 && git push origin :v0.2.0
```

GitHub の UI から Release を publish しても（タグはそこで作られる）同じ検査は走る。その場合、Release は既にあるので本文は触らない。
