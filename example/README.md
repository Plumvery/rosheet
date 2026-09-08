# example

`RosheetSchema.luau` が rosheet のスキーマの書き方の例。

## 試し方

1. `RosheetSchema.luau` と `runtime/schema.luau` を place へ入れる（Rojo でも、Studio に直接貼っても）
   - `RosheetSchema` は `ServerStorage` の直下、`rosheet` フォルダの中に `schema` として `runtime/schema.luau` を置く
2. place を公開し、File > Experience Settings > Security の "Enable Studio Access to API Services" を入れる
3. `npx rosheet plugin` でプラグインを入れ、Studio を読み込み直す（プラグインを入れるのは一度だけ）
4. ツールバーの rosheet を押す

`rosheet.toml` の `universe` を自分のテストプレイスのものにすると、`npx rosheet pull` で
`example/generated/` に `guns.luau` / `rarities.luau` / `round.luau` が書き出される。
