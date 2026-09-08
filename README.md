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

`rosheet` の実体は npm パッケージの `runtime/` に入っている。`require` が届く場所へ複製する:

```bash
npx rosheet runtime
```

既定では `output.dir` の隣に `rosheet/` を書く（`--out <dir>` で変えられる）。それを Rojo で place へ配線すれば（上の例では `ReplicatedStorage.Packages.rosheet`）、この 1 本の require から `defineSchema` も `bind` も取れる。片方だけなら `Packages.rosheet.schema` / `Packages.rosheet.live` と分けて require してもよい。**複製なので、rosheet を上げたら打ち直す。**

**roblox-ts の場合。** `output.format = "roblox-ts"` なら `.d.ts` も一緒に置かれるので、`src/` の下へ出せばそのまま import できる:

```ts
import { bind } from "shared/rosheet/live";
import { column, defineSchema, sheet } from "shared/rosheet/schema";
```

`node_modules/@plumvery/rosheet/runtime` を直接 import することはできない。npm スコープが typeRoots に無いと言われ、言われたとおり typeRoots に足すと、そのスコープの全パッケージが暗黙の型ライブラリになって `types` を持たないパッケージで落ちる。複製するのはそのため。

ただし**スキーマの宣言そのものは rootDir の外に置く。** rbxtsc は `src/server` を ServerScriptService、`src/shared` を ReplicatedStorage へ出すが、プラグインが走査するのは ServerStorage と ReplicatedStorage で、ReplicatedStorage は本番のクライアントにまで配信される。スキーマの宣言は Luau で `src/` の外に書き、Rojo で ServerStorage へ配線する。

### 2. プラグインを入れる（一度だけ）

```bash
npx rosheet plugin
```

Studio の Plugins フォルダに `rosheet.rbxmx` が置かれる。Studio 側で **File > Experience Settings > Security > Enable Studio Access to API Services** を入れておく。

**プラグインには何も焼き込まない。** スキーマも、保存先の DataStore 名も、rocas のアセット一覧も、プラグインが place の中から読む —— `ServerStorage` と `ReplicatedStorage` を走査して、Rojo が同期したモジュールを見つけ、`DescendantAdded` / Source の変化で追い直す。スキーマを直しても、アセットを足しても、プラグインは入れ直さなくてよい。

#### npm を使わずに入れる

値を触るだけのプランナーやアーティストに Node と npm を求めるのは重い。[リリース](https://github.com/Plumvery/rosheet/releases/latest)にダブルクリックで入るインストーラーを添付してある:

| ファイル | OS | 開き方 |
|---|---|---|
| `rosheet-plugin-installer-windows.cmd` | Windows | ダブルクリック。発行元を確認できないと出るので **実行** を選ぶ |
| `rosheet-plugin-installer-macos.zip` | macOS | 展開して、中の `.command` を **右クリック → 開く → 開く**。ダブルクリックだけだと拒まれる（署名の無いダウンロード済みスクリプトを macOS が止めるため） |
| `rosheet.rbxmx` | 共通 | プラグイン本体。自分で Plugins フォルダへ置きたいとき用 |

どちらのインストーラーも `.rbxmx` を base64 で中に抱えていて、`rosheet plugin` と同じ場所・同じファイル名で置く（Windows は `%LOCALAPPDATA%\Roblox\Plugins`、macOS は `~/Documents/Roblox/Plugins`）。**インストール時に通信しない**ので、プロキシの向こうでも URL が腐っても動く。置いたら Studio を再起動する。

プラグインには何も焼き込んでいないので、リリースから取った 1 本はプラグイン自体が変わるまで正しいままになる。

CLI 側の設定はこれとは別に要る:

```bash
npx rosheet init
```

`rosheet.toml` の `project.universe` と `output.dir` を埋める（`pull` / `check` / `log` / `export` / `import` が使う）。DataStore 名と `scope` を既定から変えるなら、スキーマモジュール側にも同じ値を書く —— CLI は `rosheet.toml` を読み、プラグインはスキーマモジュールを読むため:

```lua
return rosheet.defineSchema({ ... }, { datastore = "my-master-data", scope = "master" })
```

**本番の place から書けないようにする。** 同じ universe の place は DataStore を共有するので、本番 place を Studio で開くこと自体が master data への書き込み権限になる。書いてよい place を宣言すると、そこに無い place ではプラグインが読み取り専用になる（表も履歴も読めるが、Apply が押せない。スキーマの publish もしない）:

```lua
return rosheet.defineSchema({ ... }, {
	-- ここに無い place では読み取り専用
	writablePlaces = { 102760853725708 },
})
```

宣言しなければ今までどおりどの place からでも書ける。**これは事故を止めるためのもので、権限の境界ではない** —— DataStore の書き込み権限は universe 単位なので、この宣言を書き換えた place を開けば書ける。宣言は git に載るので、増やすには PR が要る。

### 3. 編集して Apply

Studio で place を開き、ツールバーの rosheet を押すとウィンドウが出る。

- 下のタブがシート。ヘッダ行と行番号の列は固定で、本体だけがスクロールする
- `readonly` の列はグレーで、編集できない。ただし**足したばかりの行のキー列だけは書き換えられる**（key は空にできないので `new1` のような仮の値が入る。Apply するとグレーに戻る）
- `boolean` と `enum` はクリックで候補が開き、選んだ値が入る。それ以外のセルは TextBox なので、Studio 上では Ctrl+C / Ctrl+V がそのまま効く
- 編集は下書きに溜まり、変えたセルが黄色く残る。**Apply を押すまで保存先に触らない**
- Apply を押すと 1 つの commit として積まれ、プレイテスト中なら値がその場で入れ替わる
- 「履歴」で過去の Apply が並ぶ。Restore を押すとその時点の値が**下書きに入る**だけで、保存先はまだ触らない。中身を見てから Apply すれば新しい commit として積まれ、Discard すれば戻す前に返る（履歴は書き換えないので、戻したあとにさらに戻れる）
- commit には何を変えたのかが自動で付く（`guns +1 ~2, round ~1` —— `+` が足した行、`-` が消した行、`~` が直したもの）。Restore から Apply したものは `revert of #3` で始まる

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

### 6. 出荷する値を固定する

ここまでの `pull` は **常に head を焼く**。調整が終わったあとに誰かが Studio で Apply すると、次に pull した人がそれごと焼いてしまう。気づく手段は `rosheet log` を見に行くことだけになる。

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

**編集を止める必要は無い。** 調整担当は今までどおり Apply できて、それが勝手に出荷されないだけ。プラグインのステータス行には `#45 · 3 ahead of v0.3.0` のように出るので、編集する側も「自分の変更はまだ出荷されていない」と分かる。

lock がハッシュではなく値ごと持つのは、rosheet を上げて生成物の書式が変わっても `check` が正しく回るようにするため。副産物として、**lock があるコマンドは Open Cloud のキーが要らなくなる**:

```bash
npx rosheet check              # CI。ネットワークもキーも要らない
npx rosheet export --local     # lock の値を CSV へ
npx rosheet import --local     # CSV を lock へ戻して焼き直す（commit は積まない）
```

DataStore を読むのは `update` / `status` / `log` / `revert` / `import`（`--local` 無し）だけになる。値を 1 個だけ直したい人は `rosheet.lock.json` を直接編集して `rosheet pull` でもよい —— キーを持たない貢献者も、CI も、ブランチ限定の値も、これで閉じる。ブランチごとに違う値を試したければ、そのブランチの lock を差し替えるだけで、本番相当のデータには触らない。

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
| `head` | `{ "seq": <最新の commit 番号> }` |
| `commit.<seq>` | その Apply のメタ情報と、シートごとの blob 番号 |
| `blob.<seq>.<sheet>` | そのシートの値（JSON 文字列） |
| `log` | 履歴の一覧（最新 200 件） |
| `tags` | commit に付けた名前の一覧（最新 200 件）。CLI が書き、プラグインは読むだけ |

設計上の約束は [src/store.js](src/store.js) の冒頭コメントが正。要点は 3 つ:

- **キーに `/` を入れない。** Open Cloud v2 はキーを URL のパスに埋める
- **値は必ず JSON 文字列で置く。** Luau のテーブルをそのまま置くと、Open Cloud がそれをどんな JSON に落とすかに全部が乗る（空のテーブルが配列と辞書のどちらになるか、が典型）。文字列にしておけば、符号化するのは常に `HttpService:JSONEncode` の側だけになる
- **DataStore 組み込みの versioning は使わない。** あれはキーごとに UTC 1 時間で 1 版しか作らず、同じ時間内の後続の書き込みは前を恒久的に上書きするので、Apply の履歴には使えない

## 制約

- プラグインが DataStore を読み書きするには、place が universe に紐づいて公開されていて、**Studio Access to API Services** が入っている必要がある。同じ universe の place は DataStore を共有するので、テスト用の place で作業する（`writablePlaces` を宣言すれば、本番 place を開いても読み取り専用になる）
- 1 シートの値は 4MB まで（DataStore のキーあたりの上限）。`rosheet.lock.json` は同じ値を持つので、自然に同じ範囲に収まる
- 古い blob は消えない。`rosheet gc` は未実装。入れるときは **tag と `rosheet.lock.json` が参照する blob を回収してはいけない**

## 進捗

| | 状態 | 確かめた範囲 |
|---|---|---|
| スキーマの定義（Luau / roblox-ts） | 動く | Lune で実行して検証 |
| コード生成（`*.luau` / `*.luau` + `*.d.ts`） | 動く | 生成物を Lune で実行して検証 |
| 履歴の計画（commit / revert / log） | 動く | 単体テスト |
| CSV の出入り | 動く | 往復の単体テスト |
| pin（`rosheet.lock.json`）とオフライン生成 | 動く | 単体テストと、一時プロジェクトでの `pull` / `check` / `import --local` / `export --local`（キー無し） |
| CLI | 実装済み | **実 DataStore との疎通は未確認**（`update` / `status` / `tag` / `log` / `revert` / `import`） |
| Studio プラグイン | 実装済み | コンパイルと `.rbxmx` の組み立てまで。**Studio 実機は未確認** |
| ランタイムの live 反映（`bind`） | 実装済み | コンパイルのみ。**Studio 実機は未確認** |

まだ無いもの: 列幅の変更、並べ替えと絞り込み、複数セルの範囲選択、古い blob の掃除（`rosheet gc`）。

## 次にやること

**Studio の実機で往復を確かめる。** CLI もプラグインもコードとしては通っているが、実 DataStore との疎通、Apply からプレイテストへの反映、rocas の manifest の読み取りは、まだ Studio で確認していない。

## リリース

バージョンは GitHub のリリースタグで管理する。npm へはまだ出していない。

1. [CHANGELOG.md](CHANGELOG.md) の `[Unreleased]` の見出しを、新しいバージョンと日付に書き換える
2. `package.json` の `version` を上げる（1.0 より前は、破壊的変更でマイナーを上げる）
3. `main` へマージしてから、その commit にタグを打って push する

```bash
git tag v0.2.0
git push origin v0.2.0
```

[`release.yml`](.github/workflows/release.yml) がこれを拾い、[`ci.yml`](.github/workflows/ci.yml) のテスト（node と Luau）を通してから GitHub Release を作る。本文は CHANGELOG のそのバージョンの節がそのまま入る。

タグと `package.json` がずれていたり、CHANGELOG にその節が無かったりすると、Release は作られずに落ちる。直したら、タグを打ち直す:

```bash
git tag -d v0.2.0 && git push origin :v0.2.0
```

GitHub の UI から Release を publish しても（タグはそこで作られる）同じ検査は走る。その場合、Release は既にあるので本文は触らない。

## ライセンス

MIT
