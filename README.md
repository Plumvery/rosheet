# rosheet

**Roblox のマスターデータを、コードでスキーマを定義し、Studio の表で編集し、place に焼き込むためのツール。**

スキーマは Luau / roblox-ts で書く。値は Studio のプラグインでスプレッドシートのように編集し、Apply を押すとその場のプレイテストに反映され、同時に履歴として残る。戻りたくなったら Apply 単位で巻き戻せる。確定したら `rosheet pull` で型付きのモジュールを書き出し、git に載せて place に焼く。

> **pre-alpha。** CLI・コード生成・DataStore の履歴・CSV の出入り・Studio プラグインまで実装済み。**ただし Studio の実機での往復はまだ確認していない**（[進捗](#進捗)）。

## なぜ

Roblox のバランス調整は「値を変える → Studio に反映する → テストプレイする」の往復が長い。スプレッドシートや CSV を挟むと、編集した値が実際に動くまでにビルドと同期が挟まる。rosheet はこの往復を Studio の中で閉じる。

一方で、**本番の place が DataStore を読みに行く設計にはしない。** 起動のたびに DataStore の障害とレート制限に晒され、Studio での誤操作が本番へ直撃し、値の変更が git に残らなくなるため。編集の正は DataStore、出荷の正は git に載る生成物、と分ける。

```
Studio プラグイン ──▶ DataStore（編集の正・Apply ごとの履歴・巻き戻し）
                          │
                          │ rosheet pull
                          ▼
                  生成コード *.luau / *.ts（git 管理・place に焼かれる）
```

## 何ができるか

- **スキーマをコードで定義**。列の型・readonly・既定値・enum の候補・数値の範囲を Luau / roblox-ts で宣言する
- **Studio で表として編集**。宣言したシートごとに表ビューが出て、編集できる列だけ編集できる
- **Apply で即時反映**。押した瞬間にプレイテスト中の値が入れ替わる
- **Apply ごとの履歴**。1 回の Apply が 1 つの commit として DataStore に積まれる。一個前へ戻る、任意の時点をもう一度試す、ができる
- **型付きのコード生成**。`*.luau`（`--!strict`）と、roblox-ts 向けの `*.luau` + `*.d.ts`
- **CSV の出入り**。スプレッドシートや外部ツールと往復する退路。CSV は経路の外にあり、正ではない
- **rocas のアセットを引ける**。`asset` 列に `rocas://assets/...` を書くと、Studio では rocas の manifest から補完とサムネイルが出て、`pull` のときに `rbxassetid://` へ解決される
- **プラグインは入れ直さない**。設定もスキーマもアセット一覧も焼き込まず、place の中から読む

## 使い方

### 1. スキーマを宣言する

```lua
-- ServerStorage/RosheetSchema.luau
local rosheet = require(ReplicatedStorage.Packages.rosheet)

return rosheet.defineSchema({
	rosheet.sheet("guns", {
		key = "id",
		description = "銃のパラメータ",
		columns = {
			rosheet.column("id", "string", { readonly = true }),
			rosheet.column("name", "string"),
			rosheet.column("damage", "number", { default = 10, min = 0 }),
			rosheet.column("rarity", "enum", { values = { "Common", "Rare", "Epic" } }),
			rosheet.column("icon", "asset"),
		},
	}),
	rosheet.sheet("round", {
		kind = "scalars",
		columns = {
			rosheet.column("SECONDS", "integer", { default = 180 }),
			rosheet.column("MIN_PLAYERS", "integer", { default = 2 }),
		},
	}),
})
```

roblox-ts なら同じものを TypeScript で書く（`runtime/schema.d.ts` が型を持つ）。

### 2. プラグインを入れる（一度だけ）

```bash
npx rosheet plugin
```

Studio の Plugins フォルダに `rosheet.rbxmx` が置かれる。Studio 側で **File > Experience Settings > Security > Enable Studio Access to API Services** を入れておく。

**プラグインには何も焼き込まない。** スキーマも、保存先の DataStore 名も、rocas のアセット一覧も、プラグインが place の中から読む —— `ServerStorage` と `ReplicatedStorage` を走査して、Rojo が同期したモジュールを見つけ、`DescendantAdded` / Source の変化で追い直す。スキーマを直しても、アセットを足しても、プラグインは入れ直さなくてよい。

CLI 側の設定はこれとは別に要る:

```bash
npx rosheet init
```

`rosheet.toml` の `project.universe` と `output.dir` を埋める（`pull` / `check` / `log` / `export` / `import` が使う）。DataStore 名を既定の `rosheet` から変えるなら、スキーマモジュール側にも同じ値を書く —— CLI は `rosheet.toml` を読み、プラグインはスキーマモジュールを読むため:

```lua
return rosheet.defineSchema({ ... }, { datastore = "my-master-data", scope = "master" })
```

### 3. 編集して Apply

Studio で place を開き、ツールバーの rosheet を押すとウィンドウが出る。

- 下のタブがシート。ヘッダ行と行番号の列は固定で、本体だけがスクロールする
- `readonly` の列はグレーで、編集できない
- `boolean` と `enum` はクリックで候補が開き、選んだ値が入る。それ以外のセルは TextBox なので、Studio 上では Ctrl+C / Ctrl+V がそのまま効く
- 編集は下書きに溜まり、変えたセルが黄色く残る。**Apply を押すまで保存先に触らない**
- Apply を押すと 1 つの commit として積まれ、プレイテスト中なら値がその場で入れ替わる
- 「履歴」で過去の Apply が並ぶ。「戻す」でその時点の値に戻る（履歴は書き換えず、戻した結果を新しい commit として積むので、戻したあとにさらに戻れる）

place をまだ公開していない、あるいは API Services を入れていない場合は、自動でこのマシンだけのローカル保存に切り替わる（その旨が画面に出る）。チームで共有するには DataStore が要る。

### 4. プレイテスト中の値を使う

ゲーム側が生成物をそのまま読むと、焼かれた値しか見えない。Apply を反映させたいところだけ `bind` を通す:

```lua
local rosheet = require(ReplicatedStorage.Packages.rosheet)
local Guns = rosheet.bind(require(ReplicatedStorage.Config.guns), "guns")

print(Guns.get("AK47").damage)
```

`bind` は本番では同梱値をそのまま返す（`RosheetLive` が存在しないため）。型も同梱値のまま変わらない。

### 5. 生成物を取り込んでコミットする

```bash
npx rosheet pull
```

`output.dir` に `guns.luau` / `round.luau` が書かれる。これを git に載せる。ゲーム側はこう読む:

```lua
local Guns = require(ReplicatedStorage.Config.guns)

print(Guns.get("AK47").damage)
for _, gun in Guns.rows do ... end
```

## コマンド

| コマンド | すること |
|---|---|
| `rosheet init` | `rosheet.toml` を書く |
| `rosheet plugin` | Studio プラグインを Plugins フォルダに置く（一度だけ。何も焼き込まない） |
| `rosheet pull` | DataStore の現在値を読んで生成物を書く |
| `rosheet check` | 生成物が現在値と違えば落ちる（CI 用。誰かの Apply の取り込み忘れを捕まえる） |
| `rosheet log` | Apply の履歴 |
| `rosheet revert <seq>` | その commit の値へ戻す commit を積む |
| `rosheet export --csv <dir>` | 現在値を CSV で書き出す |
| `rosheet import --csv <dir>` | CSV を読み込んで Apply する |
| `rosheet schema --save <file>` | プラグインが公開したスキーマを保存する |

`pull` / `check` / `log` / `export` は Open Cloud の API キー（`ROSHEET_API_KEY`）に `universe-datastores.objects:read` が要る。`import` / `revert` はさらに `:update` が要る。`.env` に置けば読む。

## DataStore に置く形

| キー | 中身 |
|---|---|
| `schema` | プラグインが place のスキーマモジュールから起こした正規形 |
| `head` | `{ "seq": <最新の commit 番号> }` |
| `commit.<seq>` | その Apply のメタ情報と、シートごとの blob 番号 |
| `blob.<seq>.<sheet>` | そのシートの値（JSON 文字列） |
| `log` | 履歴の一覧（最新 200 件） |

設計上の約束は [src/store.js](src/store.js) の冒頭コメントが正。要点は 3 つ:

- **キーに `/` を入れない。** Open Cloud v2 はキーを URL のパスに埋める
- **値は必ず JSON 文字列で置く。** Luau のテーブルをそのまま置くと、Open Cloud がそれをどんな JSON に落とすかに全部が乗る（空のテーブルが配列と辞書のどちらになるか、が典型）。文字列にしておけば、符号化するのは常に `HttpService:JSONEncode` の側だけになる
- **DataStore 組み込みの versioning は使わない。** あれはキーごとに UTC 1 時間で 1 版しか作らず、同じ時間内の後続の書き込みは前を恒久的に上書きするので、Apply の履歴には使えない

## 制約

- プラグインが DataStore を読み書きするには、place が universe に紐づいて公開されていて、**Studio Access to API Services** が入っている必要がある。Studio は本番と同じ DataStore を見るので、テスト用の place で作業する
- 1 シートの値は 4MB まで（DataStore のキーあたりの上限）
- 古い blob は消えない。`rosheet gc` は未実装

## 進捗

| | 状態 | 確かめた範囲 |
|---|---|---|
| スキーマの定義（Luau / roblox-ts） | 動く | Lune で実行して検証 |
| コード生成（`*.luau` / `*.luau` + `*.d.ts`） | 動く | 生成物を Lune で実行して検証 |
| 履歴の計画（commit / revert / log） | 動く | 単体テスト |
| CSV の出入り | 動く | 往復の単体テスト |
| CLI | 実装済み | **実 DataStore との疎通は未確認** |
| Studio プラグイン | 実装済み | コンパイルと `.rbxmx` の組み立てまで。**Studio 実機は未確認** |
| ランタイムの live 反映（`bind`） | 実装済み | コンパイルのみ。**Studio 実機は未確認** |

まだ無いもの: 列幅の変更、並べ替えと絞り込み、複数セルの範囲選択、古い blob の掃除（`rosheet gc`）。

## 次にやること

**Studio の実機で往復を確かめる。** CLI もプラグインもコードとしては通っているが、実 DataStore との疎通、Apply からプレイテストへの反映、rocas の manifest の読み取りは、まだ Studio で確認していない。

## ライセンス

MIT
