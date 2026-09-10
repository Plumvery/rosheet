# rosheet

**Roblox のマスターデータを、コードでスキーマを定義し、Studio の表で編集し、place に焼き込むためのツール。**

スキーマは Luau / roblox-ts で書く。値は Studio のプラグインでスプレッドシートのように編集し、Apply を押すとその場のプレイテストに反映され、同時に履歴として残る。戻りたくなったら Apply 単位で巻き戻せる。確定したら `rosheet pull` で型付きのモジュールを書き出し、git に載せて place に焼く。

> **pre-alpha。** CLI・コード生成・DataStore の履歴・CSV の出入り・Studio プラグインまで実装済み。**ただし Studio の実機での往復はまだ確認していない。**

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

## インストール

npm にはまだ出していない。GitHub から直接入れる（Node 18 以上）:

```bash
npm install --save-dev github:Plumvery/rosheet
```

バージョンを固定するならタグを付ける:

```bash
npm install --save-dev github:Plumvery/rosheet#v0.1.0
```

入ったら `npx rosheet` でコマンドの一覧が出る。値を触るだけの人向けに、npm を通さない[プラグイン単体のインストーラー](#npm-を使わずにプラグインだけ入れる)もある。

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

`rosheet` の実体はパッケージの `runtime/` に入っている。`require` が届く場所へ複製する:

```bash
npx rosheet runtime
```

既定では `output.dir` の隣に `rosheet/` を書く（`--out <dir>` で変えられる）。それを Rojo で place へ配線すれば（上の例では `ReplicatedStorage.Packages.rosheet`）、この 1 本の require から `defineSchema` も `bind` も取れる。片方だけなら `Packages.rosheet.schema` / `Packages.rosheet.live` と分けて require してもよい。

**複製なので、rosheet を上げたら打ち直す。打ち直したら Studio を開き直す。** Studio の `require` は戻り値をインスタンス単位で恒久的にキャッシュするので、Rojo が同期しても古いランタイムが評価され続ける。プラグインはこのズレを見つけると読み取り専用になり、開き直すよう出す。

**roblox-ts の場合。** `output.format = "roblox-ts"` なら `.d.ts` も一緒に置かれるので、`src/` の下へ出せばそのまま import できる:

```ts
import { bind } from "shared/rosheet/live";
import { column, defineSchema, sheet } from "shared/rosheet/schema";
```

`node_modules` の中の `runtime/` を直接 import することはできない（npm スコープを typeRoots に足すと、そのスコープの全パッケージが暗黙の型ライブラリになって落ちる）。複製するのはそのため。

ただし**スキーマの宣言そのものは rootDir の外に置く。** rbxtsc は `src/shared` を ReplicatedStorage へ出すが、そこは本番のクライアントにまで配信される。スキーマの宣言は Luau で `src/` の外に書き、Rojo で ServerStorage へ配線する。

### 2. プラグインを入れる（一度だけ）

```bash
npx rosheet plugin
```

Studio の Plugins フォルダに `rosheet.rbxmx` が置かれる。Studio 側で **File > Experience Settings > Security > Enable Studio Access to API Services** を入れておく。

**プラグインには何も焼き込まない。** スキーマも、保存先の DataStore 名も、rocas のアセット一覧も、プラグインが place の中から読む —— `ServerStorage` と `ReplicatedStorage` を走査して、Rojo が同期したモジュールを見つけ、`DescendantAdded` / Source の変化で追い直す。スキーマを直しても、アセットを足しても、プラグインは入れ直さなくてよい。

#### npm を使わずにプラグインだけ入れる

値を触るだけのプランナーやアーティストに Node と npm を求めるのは重い。[リリース](https://github.com/Plumvery/rosheet/releases/latest)にダブルクリックで入るインストーラーを添付してある:

| ファイル | OS | 開き方 |
|---|---|---|
| `rosheet-plugin-installer-windows.cmd` | Windows | ダブルクリック。発行元を確認できないと出るので **実行** を選ぶ |
| `rosheet-plugin-installer-macos.zip` | macOS | 展開して、中の `.command` を **右クリック → 開く → 開く**。ダブルクリックだけだと拒まれる（署名の無いダウンロード済みスクリプトを macOS が止めるため） |
| `rosheet.rbxmx` | 共通 | プラグイン本体。自分で Plugins フォルダへ置きたいとき用 |

どちらのインストーラーも `.rbxmx` を base64 で中に抱えていて、`rosheet plugin` と同じ場所・同じファイル名で置く（Windows は `%LOCALAPPDATA%\Roblox\Plugins`、macOS は `~/Documents/Roblox/Plugins`）。**インストール時に通信しない**ので、プロキシの向こうでも URL が腐っても動く。置いたら Studio を再起動する。

### 3. CLI を設定する

```bash
npx rosheet init
```

`rosheet.toml` の `project.universe` と `output.dir` を埋める（`pull` / `check` / `log` / `export` / `import` が使う）。DataStore 名と `scope` を既定から変えるなら、スキーマモジュール側にも同じ値を書く —— CLI は `rosheet.toml` を読み、プラグインはスキーマモジュールを読むため:

```lua
return rosheet.defineSchema({ ... }, { datastore = "my-master-data", scope = "master" })
```

**本番の place から書けないようにする。** 同じ universe の place は DataStore を共有するので、本番 place を Studio で開くこと自体が master data への書き込み権限になる。書いてよい place を宣言すると、そこに無い place ではプラグインが読み取り専用になる（表も履歴もチームの下書きも読めるが、セルに書けず、行も足せず、Apply も Discard も押せない）:

```lua
return rosheet.defineSchema({ ... }, {
	-- ここに無い place では読み取り専用
	writablePlaces = { 1234567890123 },
})
```

宣言しなければどの place からでも書ける。**これは事故を止めるためのもので、権限の境界ではない** —— DataStore の書き込み権限は universe 単位なので、この宣言を書き換えた place を開けば書ける。宣言は git に載るので、増やすには PR が要る。

スキーマそのものが読めなくなったとき（モジュールを消した・名前を変えた・Rojo の同期から外れた・`require` が落ちた）も読み取り専用になる。`writablePlaces` を含む宣言が読めていない以上、最後に読めた「この place は書ける」は当てにならないため。

### 4. 編集して Apply

Studio で place を開き、ツールバーの rosheet を押すとウィンドウが出る。

- 下のタブがシート。ヘッダ行と行番号の列は固定で、本体だけがスクロールする
- `readonly` の列はグレーで、編集できない。ただし**足したばかりの行のキー列だけは書き換えられる**（key は空にできないので `new1` のような仮の値が入る。Apply するとグレーに戻る）
- `boolean` と `enum` はクリックで候補が開き、選んだ値が入る。それ以外のセルは TextBox なので、Studio 上では Ctrl+C / Ctrl+V がそのまま効く
- 編集は下書きに溜まり、変えたセルが黄色く残る。**Apply を押すまで保存先に触らない**
- **下書きはチームで 1 つ。** 誰かがセルを直すと数秒で他の人の表にも出る。入力即反映ではない —— 積まれるのは Apply を押したときだけで、そこで 1 つの commit になる。下書きは保存先にも残るので、Studio を閉じても place を開き直しても戻ってくる
- 他の人の未 Apply の編集が乗っているときは、Apply（と Discard）の前に誰が何セル触っているかが出る。編集中もステータス行に `+2 editing` として出る
- **他の人が今どのセルを見ているかが枠と名前で出る。** 色はその人のウィジェットごとに決まるので、見ている側が誰でも同じ人が同じ色になる。Studio を閉じると相手の画面からも消える（閉じ方によっては最大 20 秒残る）
- Apply を押すと 1 つの commit として積まれ、プレイテスト中なら値がその場で入れ替わる
- 「履歴」で過去の Apply が並ぶ。Restore を押すとその時点の値が**下書きに入る**だけで、保存先はまだ触らない。中身を見てから Apply すれば新しい commit として積まれ、Discard すれば戻す前に返る（履歴は書き換えないので、戻したあとにさらに戻れる）
- commit には何を変えたのかが自動で付く（`guns +1 ~2, round ~1` —— `+` が足した行、`-` が消した行、`~` が直したもの）。Restore から Apply したものは `revert of #3` で始まる

place をまだ公開していない、あるいは API Services を入れていない場合は、自動でこのマシンだけのローカル保存に切り替わる（その旨が画面に出る）。チームで共有するには DataStore が要る。

### 5. プレイテスト中の値を使う

ゲーム側が生成物をそのまま読むと、焼かれた値しか見えない。Apply を反映させたいところだけ `bind` を通す:

```lua
local rosheet = require(ReplicatedStorage.Packages.rosheet)
local Guns = rosheet.bind(require(ReplicatedStorage.Config.guns), "guns")

print(Guns.get("AK47").damage)
```

`bind` は本番では同梱値をそのまま返す（`RosheetLive` が存在しないため）。型も同梱値のまま変わらない。

### 6. 生成物を取り込んでコミットする

```bash
npx rosheet pull
```

`output.dir` に `guns.luau` / `round.luau` が書かれる。これを git に載せる。ゲーム側はこう読む:

```lua
local Guns = require(ReplicatedStorage.Config.guns)

print(Guns.get("AK47").damage)
for _, gun in Guns.rows do ... end
```

### 7. 出荷する値を固定する

ここまでの `pull` は **常に head を焼く**。調整が終わったあとに誰かが Studio で Apply すると、次に pull した人がそれごと焼いてしまう。

出口を固定する。調整し終わった commit に名前を付けて、

```bash
npx rosheet tag v0.3.0 --note "0.3.0 のバランス"
npx rosheet update --tag v0.3.0
```

`rosheet.lock.json` がその時点の**スキーマと値ごと**書かれる。以降 `pull` と `check` はこの lock を焼くので、**誰が Apply しても出荷される値は動かない。** 動かすには `rosheet update` を打って lock を差し替える —— それは git の diff になり、PR のレビューに乗る。

```bash
npx rosheet update --tag v0.4.0   # 別の tag へ pin を移す
npx rosheet update                # 今の head に追いつく
npx rosheet status                # head が pin より何 commit 先か
```

**編集を止める必要は無い。** 調整担当は今までどおり Apply できて、それが勝手に出荷されないだけ。プラグインのステータス行には `#45 · 3 ahead of v0.3.0` のように出る。

lock がハッシュではなく値ごと持つのは、rosheet を上げて生成物の書式が変わっても `check` が正しく回るようにするため。副産物として、**lock があるコマンドは Open Cloud のキーが要らなくなる**:

```bash
npx rosheet check              # CI。ネットワークもキーも要らない
npx rosheet export --local     # lock の値を CSV へ
npx rosheet import --local     # CSV を lock へ戻して焼き直す（commit は積まない）
```

DataStore を読むのは `update` / `status` / `log` / `revert` / `import`（`--local` 無し）だけになる。値を 1 個だけ直したい人は `rosheet.lock.json` を直接編集して `rosheet pull` でもよい。

**最初の 1 回だけは Studio の往復が要る。** CLI は Luau を評価しないので、スキーマの出所はプラグインが publish したものになる。`rosheet update` を一度打てば、それ以降はスキーマも lock の中にある。

## コマンド

| コマンド | すること |
|---|---|
| `rosheet init` | `rosheet.toml` を書く |
| `rosheet plugin` | Studio プラグインを Plugins フォルダに置く（一度だけ。何も焼き込まない） |
| `rosheet runtime` | `defineSchema` / `bind` を持つ runtime のモジュールをプロジェクトへ複製する |
| `rosheet update [--tag <name>\|--seq <n>]` | `rosheet.lock.json` の pin を動かして生成物を書く（DataStore を読む唯一の生成経路） |
| `rosheet pull` | pin から生成物を書く（pin が無ければ DataStore の head から） |
| `rosheet check` | 生成物が pin と違えば落ちる（CI 用） |
| `rosheet status` | pin と DataStore の head を突き合わせる |
| `rosheet tag [<name>]` | tag の一覧、または commit に名前を付ける |
| `rosheet log` | Apply の履歴 |
| `rosheet revert <seq>` | その commit の値へ戻す commit を積む |
| `rosheet export --csv <dir>` | 現在値を CSV で書き出す（`--local` なら lock から） |
| `rosheet import --csv <dir>` | CSV を読み込んで Apply する（`--local` なら lock を書き換えるだけ） |
| `rosheet schema --save <file>` | プラグインが公開したスキーマを保存する |

Open Cloud の API キー（`ROSHEET_API_KEY`）が要るのは DataStore を触るときだけ:

- `universe-datastores.objects:read` —— `update` / `status` / `log` / `export` / `schema`、および pin がまだ無いときの `pull` / `check`
- 加えて `:update` —— `import`（`--local` 無し）/ `revert` / `tag`

`.env` に置けば読む。**`rosheet.lock.json` があれば `pull` / `check` / `import --local` / `export --local` はキー無しで回る。**

## DataStore に置く形

| キー | 中身 |
|---|---|
| `schema` | プラグインが place のスキーマモジュールから起こした正規形 |
| `draft` | 共有下書き。`head` からのセル単位の差分と、各セルを誰がいつ触ったか。Apply か Discard で空になる |
| `head` | `{ "seq": <最新の commit 番号> }` |
| `commit.<seq>` | その Apply のメタ情報と、シートごとの blob 番号 |
| `blob.<seq>.<sheet>` | そのシートの値（JSON 文字列） |
| `log` | 履歴の一覧（最新 200 件） |
| `tags` | commit に付けた名前の一覧（最新 200 件）。CLI が書き、プラグインは読むだけ |

設計上の約束は [src/store.js](src/store.js) の冒頭コメントが正。

## 制約

- プラグインが DataStore を読み書きするには、place が universe に紐づいて公開されていて、**Studio Access to API Services** が入っている必要がある。同じ universe の place は DataStore を共有するので、テスト用の place で作業する（`writablePlaces` を宣言すれば、本番 place を開いても読み取り専用になる）
- 1 シートの値は 4MB まで（DataStore のキーあたりの上限）
- 共有下書きの速い経路は MemoryStore で、1 項目 30KB まで。差分 1 セルがおよそ 80 バイトなので数百セルまで。超えると速い経路だけ止まり、DataStore の写し（20 秒ごと）で共有が続く。止まっていることはステータス行に出る
- `key` の無い `rows = "open"` な表は下書きを共有しない。行を位置でしか見分けられず、相手が行を足すと自分の触っていたセルが別の行を指すため。key を宣言すれば共有される
- 古い blob は消えない。`rosheet gc` は未実装
- まだ無いもの: 列幅の変更、並べ替えと絞り込み、複数セルの範囲選択

## 例

[example/](example/) にスキーマの書き方と、それを Studio で開くまでの手順がある。

## 開発

[CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## ライセンス

MIT
