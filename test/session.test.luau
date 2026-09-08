--!strict
-- 履歴の読み書きを、偽の保存先で丸ごと回す。
--
-- Session.luau は Roblox の API に触らないので（符号化は Store.luau の中）、ここで実際に
-- Apply・巻き戻し・競合まで検査できる。偽の保存先は値を JSON へ通してから返すので、
-- JSON を往復できない値が混じっていればここで落ちる。
--
-- plugin/src/*.luau は `require(script.Parent.X)` で兄弟を引く。Lune には script が無いので、
-- 環境に偽の script と require を差してから読み込む。

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local rosheet = require("../runtime/schema")

-- ============================================================ プラグインのモジュールを読む

local loaded: { [string]: any } = {}
local siblings = {}

local function loadModule(name: string): any
	if loaded[name] ~= nil then
		return loaded[name]
	end
	local chunk = luau.load(fs.readFile(`plugin/src/{name}.luau`), {
		debugName = name,
		environment = {
			script = { Parent = siblings },
			-- script.Parent.X が既にモジュールを返すので、require は素通しでよい
			require = function(module: any): any
				return module
			end,
		},
	})
	loaded[name] = chunk()
	return loaded[name]
end

setmetatable(siblings, {
	__index = function(_, key: string): any
		return loadModule(key)
	end,
})

local Schema = loadModule("Schema")
local Rows = loadModule("Rows")
local Session = loadModule("Session")

-- ============================================================ 偽の保存先

type Fake = { backend: any, data: { [string]: string }, writes: number }

local function fakeBackend(): Fake
	local data: { [string]: string } = {}
	local self: Fake = { backend = nil, data = data, writes = 0 }

	self.backend = {
		kind = "fake",
		label = "fake",
		get = function(key: string): any
			if data[key] == nil then
				return { ok = true, value = nil }
			end
			return { ok = true, value = serde.decode("json", data[key]) }
		end,
		set = function(key: string, value: any): any
			data[key] = serde.encode("json", value)
			self.writes += 1
			return { ok = true, value = value }
		end,
		update = function(key: string, transform: (any) -> any): any
			local current = if data[key] == nil then nil else serde.decode("json", data[key])
			local next = transform(current)
			if next == nil then
				return { ok = false, error = "競合: 他の誰かが先に書き込んだ" }
			end
			data[key] = serde.encode("json", next)
			self.writes += 1
			return { ok = true, value = next }
		end,
	}
	return self
end

-- ============================================================ 検査の道具

local failures = 0
local function check(name: string, condition: boolean, detail: string?)
	if condition then
		print(`ok    {name}`)
	else
		failures += 1
		print(`FAIL  {name}{if detail ~= nil then ` — {detail}` else ""}`)
	end
end

local schema = Schema.normalize(rosheet.defineSchema({
	rosheet.sheet("guns", {
		key = "id",
		columns = {
			rosheet.column("id", "string", { readonly = true }),
			rosheet.column("damage", "number", { default = 10, min = 0 }),
			rosheet.column("rarity", "enum", { values = { "Common", "Rare" } }),
		},
	}),
	rosheet.sheet("round", {
		kind = "scalars",
		columns = { rosheet.column("SECONDS", "integer", { default = 180 }) },
	}),
}))

-- ============================================================ 空の状態

local fake = fakeBackend()
local backend = fake.backend

check("キーは 50 文字に収まる", pcall(Session.checkSheetNames, schema))

local ok, state = Session.readCurrent(backend, schema)
check("何も無いところから読める", ok and state.head == 0, if ok then nil else tostring(state))
check("空の状態は空のデータセット", ok and #state.dataset.guns == 0 and state.dataset.round.SECONDS == 180)

check("スキーマを置いて読み戻せる", (function()
	local published = Session.publishSchema(backend, schema)
	local read, stored = Session.readSchema(backend)
	return published and read and stored.sheets[1].name == "guns" and #stored.sheets == 2
end)())

-- ============================================================ 1 回目の Apply

local draft = Rows.cloneDataset(schema, state.dataset)
table.insert(draft.guns, { id = "AK", damage = 34, rarity = "Rare" })
table.insert(draft.guns, { id = "SMG", damage = 12, rarity = "Common" })
draft.round.SECONDS = 240

local applied, commit1 = Session.apply(backend, schema, state, draft, { at = "2026-09-08T00:00:00Z", by = "tester" })
check("1 回目の Apply が通る", applied and commit1 ~= nil and commit1.seq == 1, tostring(commit1))
check("両方のシートが blob を持つ", applied and commit1.sheets.guns == 1 and commit1.sheets.round == 1)

local read1, state1 = Session.readCurrent(backend, schema)
check("Apply した値が読み戻せる", read1 and #state1.dataset.guns == 2 and state1.dataset.guns[1].id == "AK")
check("scalars も読み戻せる", read1 and state1.dataset.round.SECONDS == 240)
check("既定値が埋まっている", read1 and state1.dataset.guns[2].rarity == "Common")

-- ============================================================ 変わったシートだけ blob を作る

local draft2 = Rows.cloneDataset(schema, state1.dataset)
draft2.guns[1].damage = 40

local applied2, commit2 = Session.apply(backend, schema, state1, draft2, { at = "2026-09-08T00:00:00Z", by = "tester" })
check("2 回目の Apply が通る", applied2 and commit2.seq == 2)
check("変わった guns だけ新しい blob", applied2 and commit2.sheets.guns == 2)
check("変わらない round は前の blob を指す", applied2 and commit2.sheets.round == 1)
check("round の blob は作り直されていない", fake.data["blob.000002.round"] == nil)
check("parent が繋がっている", applied2 and commit2.parent == 1)

-- ============================================================ 変化が無ければ commit を積まない

local read2, state2 = Session.readCurrent(backend, schema)
local before = fake.writes
local applied3, commit3 = Session.apply(backend, schema, state2, Rows.cloneDataset(schema, state2.dataset), { at = "2026-09-08T00:00:00Z", by = "tester" })
check("変化が無ければ commit を積まない", applied3 and commit3 == nil)
check("そのとき書き込みも起きない", fake.writes == before)

-- ============================================================ 巻き戻し
--
-- 昔の commit を読んで下書きに入れ、それを Apply し直す。プラグインの Restore と同じ手順。

local found, target = Session.readCommit(backend, 1)
check("過去の commit を読める", found and target.seq == 1)

local restored, restoredDataset = Session.readDataset(backend, schema, target)
check("過去の commit の値を読める", restored and restoredDataset.guns[1].damage == 34)

local reverted, commit4 = Session.apply(
	backend,
	schema,
	state2,
	restoredDataset,
	{ at = "2026-09-08T00:00:00Z", by = "tester", note = "revert of #1", revertOf = 1 }
)
check("巻き戻しが新しい commit として積まれる", reverted and commit4.seq == 3 and commit4.revertOf == 1)
check("戻した値を持つシートだけ blob を作る", reverted and commit4.sheets.guns == 3 and commit4.sheets.round == 1)

local read3, state3 = Session.readCurrent(backend, schema)
check("巻き戻した値が戻っている", read3 and state3.dataset.guns[1].damage == 34, if read3 then tostring(state3.dataset.guns[1].damage) else nil)
check("巻き戻した後もさらに進める", (function()
	local draft4 = Rows.cloneDataset(schema, state3.dataset)
	draft4.guns[1].damage = 99
	local okApply, commit5 = Session.apply(backend, schema, state3, draft4, { at = "2026-09-08T00:00:00Z", by = "tester" })
	return okApply and commit5.seq == 4 and commit5.parent == 3
end)())

-- ============================================================ 競合

local stale = { head = 1, commit = target, dataset = state3.dataset }
local staleDraft = Rows.cloneDataset(schema, state3.dataset)
staleDraft.guns[1].damage = 1
local conflicted, why = Session.apply(backend, schema, stale, staleDraft, { at = "2026-09-08T00:00:00Z", by = "other" })
check("古い head からの Apply は弾かれる", not conflicted and string.find(tostring(why), "競合") ~= nil, tostring(why))

-- ============================================================ head が指す commit が無いとき

local broken = fakeBackend()
Session.publishSchema(broken.backend, schema)
local s0 = select(2, Session.readCurrent(broken.backend, schema))
Session.apply(broken.backend, schema, s0, draft, { at = "2026-09-08T00:00:00Z", by = "tester" })
-- 番号を取った直後に落ちた状況を作る
broken.backend.update("head", function()
	return { seq = 2 }
end)
local recovered, recoveredState = Session.readCurrent(broken.backend, schema)
check("commit が無ければ 1 つ前まで遡って読む", recovered and recoveredState.head == 2 and recoveredState.commit.seq == 1)

-- ============================================================ 履歴

local logged, log = Session.readLog(backend)
check("履歴が新しい順に並ぶ", logged and log.entries[1].seq == 4 and log.entries[#log.entries].seq == 1)
check("履歴に変えたシートが残る", logged and table.concat(log.entries[3].changed, ",") == "guns")
check("巻き戻しは履歴に revertOf を残す", logged and log.entries[2].revertOf == 1)

-- ============================================================ 何を変えたのかの要約

local read4, state4 = Session.readCurrent(backend, schema)
local draft5 = Rows.cloneDataset(schema, state4.dataset)
draft5.guns[1].damage = 7
local added = Rows.blankRow(schema.sheets[1])
added.id = "NEW"
table.insert(draft5.guns, added)
draft5.round.SECONDS = 90

local summary = Rows.summarize(schema, state4.dataset, draft5)
check("足した行と直した行を分けて数える", read4 and summary == "guns +1 ~1, round ~1", summary)
check("消した行は -", (function()
	local shorter = Rows.cloneDataset(schema, state4.dataset)
	table.remove(shorter.guns, 1)
	return Rows.summarize(schema, state4.dataset, shorter) == "guns -1"
end)())
check("変化が無ければ空", Rows.summarize(schema, state4.dataset, Rows.cloneDataset(schema, state4.dataset)) == "")

local applied6, commit6 = Session.apply(
	backend,
	schema,
	state4,
	draft5,
	{ at = "2026-09-08T00:00:00Z", by = "tester", note = "revert of #1 · guns +1 ~1", revertOf = 1 }
)
check("Apply が revertOf と note を残す", applied6 and commit6.revertOf == 1 and commit6.note == "revert of #1 · guns +1 ~1")

local logged3, log3 = Session.readLog(backend)
check("履歴にも note が残る", logged3 and log3.entries[1].note == "revert of #1 · guns +1 ~1")

print(`\n{if failures == 0 then "all ok" else `{failures} failed`}`)
if failures > 0 then
	process.exit(1)
end
