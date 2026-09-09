--!strict
-- 共有下書きの併合規則を、保存先ぬきで回す。
--
-- Draft.luau は Roblox の API に触らないので（保存先とのやり取りは App 側）、ここで
-- 「2 人が同じセルを触った」「片方が行を消し、もう片方がそのセルを直した」まで検査できる。
-- 併合が壊れると他人の編集が黙って消えるので、規則はテストで固定しておく。
--
-- 読み込みの仕掛けは session.test.luau と同じ（Lune には script が無いので偽物を差す）。

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

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
local Draft = loadModule("Draft")

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
			rosheet.column("name", "string"),
		},
	}),
	rosheet.sheet("loose", {
		columns = {
			rosheet.column("label", "string"),
		},
	}),
	rosheet.sheet("round", {
		kind = "scalars",
		columns = {
			rosheet.column("SECONDS", "integer", { default = 180 }),
			rosheet.column("MIN_PLAYERS", "integer", { default = 2 }),
		},
	}),
}))

local gunsSheet = schema.sheets[1]
local looseSheet = schema.sheets[2]
local roundSheet = schema.sheets[3]

local base = Rows.normalizeDataset(schema, {
	guns = {
		{ id = "AK47", damage = 30, name = "AK-47" },
		{ id = "M4", damage = 26, name = "M4" },
	},
	loose = { { label = "a" }, { label = "b" } },
	round = { SECONDS = 180, MIN_PLAYERS = 2 },
})

-- ============================================================ 行の見分け方

check("key のある表は key で見分ける", Draft.rowId(gunsSheet, { id = "AK47" }, 1) == "AK47")
check("key の無い表は位置で見分ける", Draft.rowId(looseSheet, { label = "a" }, 2) == "2")
check("scalars は行が 1 つ", Draft.rowId(roundSheet, nil, 1) == Draft.SCALAR_ROW)

check("key のある表は共有してよい", Draft.sharable(gunsSheet))
check("scalars は共有してよい", Draft.sharable(roundSheet))
check("key の無い open な表は共有しない", not Draft.sharable(looseSheet))

-- ============================================================ 差分を載せる

local mine = Draft.empty(5)
Draft.setCell(mine, "guns", "AK47", "damage", 35, "haru", "2026-09-09T01:00:00Z")
Draft.setCell(mine, "round", Draft.SCALAR_ROW, "SECONDS", 240, "haru", "2026-09-09T01:00:01Z")

check("空でなくなる", not Draft.isEmpty(mine))
check("触ったセルを数える", Draft.count(mine) == 2, tostring(Draft.count(mine)))

local applied = Draft.apply(schema, base, mine)
check("表のセルが入れ替わる", (applied.guns :: any)[1].damage == 35)
check("触っていない行はそのまま", (applied.guns :: any)[2].damage == 26)
check("触っていない列はそのまま", (applied.guns :: any)[1].name == "AK-47")
check("scalars も入れ替わる", (applied.round :: any).SECONDS == 240)
check("scalars の他の列はそのまま", (applied.round :: any).MIN_PLAYERS == 2)
check("base は書き換えられていない", (base.guns :: any)[1].damage == 30)

-- ============================================================ 行の増減

local adding = Draft.empty(5)
Draft.addRow(adding, "guns", "new1", { id = "new1", damage = 10, name = "" }, "haru", "2026-09-09T01:00:00Z")
Draft.setCell(adding, "guns", "new1", "damage", 12, "haru", "2026-09-09T01:00:02Z")

local addedOut = Draft.apply(schema, base, adding)
check("足した行が末尾に付く", #(addedOut.guns :: any) == 3)
check("足した行への編集は行そのものに入る", (addedOut.guns :: any)[3].damage == 12)
check("足した行への編集は cells に積まれない", next((adding.sheets.guns :: any).cells) == nil)

local removing = Draft.empty(5)
Draft.removeRow(removing, "guns", "M4", "haru", "2026-09-09T01:00:00Z")
local removedOut = Draft.apply(schema, base, removing)
check("消した行が消える", #(removedOut.guns :: any) == 1)
check("残る行は正しい方", (removedOut.guns :: any)[1].id == "AK47")

local addThenRemove = Draft.empty(5)
Draft.addRow(addThenRemove, "guns", "new1", { id = "new1", damage = 10, name = "" }, "haru", "2026-09-09T01:00:00Z")
Draft.removeRow(addThenRemove, "guns", "new1", "haru", "2026-09-09T01:00:01Z")
check("足してすぐ消した行は記録ごと消える", Draft.isEmpty(addThenRemove))

-- ============================================================ 併合

local a = Draft.empty(5)
Draft.setCell(a, "guns", "AK47", "damage", 35, "haru", "2026-09-09T01:00:00Z")

local b = Draft.empty(5)
Draft.setCell(b, "guns", "M4", "damage", 28, "kae", "2026-09-09T01:00:01Z")

local merged = Draft.merge(a, b)
local mergedOut = Draft.apply(schema, base, merged)
check("違うセルは両方残る", (mergedOut.guns :: any)[1].damage == 35 and (mergedOut.guns :: any)[2].damage == 28)

local older = Draft.empty(5)
Draft.setCell(older, "guns", "AK47", "damage", 35, "haru", "2026-09-09T01:00:00Z")
local newer = Draft.empty(5)
Draft.setCell(newer, "guns", "AK47", "damage", 40, "kae", "2026-09-09T01:00:05Z")

check("同じセルは at の新しい方が勝つ", (Draft.apply(schema, base, Draft.merge(older, newer)).guns :: any)[1].damage == 40)
check("併合の順を入れ替えても同じ", (Draft.apply(schema, base, Draft.merge(newer, older)).guns :: any)[1].damage == 40)

local removeSide = Draft.empty(5)
Draft.removeRow(removeSide, "guns", "M4", "kae", "2026-09-09T01:00:00Z")
local editSide = Draft.empty(5)
Draft.setCell(editSide, "guns", "M4", "damage", 99, "haru", "2026-09-09T01:00:01Z")
local conflict = Draft.apply(schema, base, Draft.merge(removeSide, editSide))
check("消した行への編集は行ごと消える", #(conflict.guns :: any) == 1)

local reAdd = Draft.empty(5)
Draft.removeRow(reAdd, "guns", "M4", "kae", "2026-09-09T01:00:00Z")
local reAddLater = Draft.empty(5)
Draft.addRow(reAddLater, "guns", "M4", { id = "M4", damage = 26, name = "M4" }, "haru", "2026-09-09T01:00:09Z")
local reAdded = Draft.merge(reAdd, reAddLater)
check("消したあとに足し直したら足った方を採る", (reAdded.sheets.guns :: any).removed.M4 == nil)

local other = Draft.empty(9)
Draft.setCell(other, "guns", "AK47", "damage", 1, "kae", "2026-09-09T01:00:00Z")
check("base が違えば新しい方を採る", Draft.merge(mine, other).base == 9)
check("base が違えば古い方は採らない", Draft.merge(other, mine).base == 9)

-- ============================================================ 確認ダイアログの中身

local team = Draft.empty(5)
Draft.setCell(team, "guns", "AK47", "damage", 35, "haru", "2026-09-09T01:00:00Z")
Draft.setCell(team, "guns", "M4", "damage", 28, "kae", "2026-09-09T01:00:01Z")
Draft.setCell(team, "guns", "M4", "name", "M4A1", "kae", "2026-09-09T01:00:02Z")
Draft.addRow(team, "guns", "new1", { id = "new1", damage = 10, name = "" }, "sora", "2026-09-09T01:00:03Z")

local authors = Draft.otherAuthors(team, "haru")
check("自分は出てこない", #authors == 2, tostring(#authors))
check("触った数の多い順", authors[1].by == "kae" and authors[1].cells == 2)
check("行を足した人も出る", authors[2].by == "sora" and authors[2].cells == 1)
check("誰も居なければ空", #Draft.otherAuthors(mine, "haru") == 0)

-- ============================================================ 足した行のキーを直す

local rekey = Draft.empty(5)
Draft.addRow(rekey, "guns", "new1", { id = "new1", damage = 10, name = "" }, "haru", "2026-09-09T01:00:00Z")
Draft.setCell(rekey, "guns", "new1", "damage", 44, "haru", "2026-09-09T01:00:01Z")
check("足した行だと分かる", Draft.isAdded(rekey, "guns", "new1"))
check("足していない行は false", not Draft.isAdded(rekey, "guns", "AK47"))

Draft.rekeyAdded(rekey, "guns", "new1", "AK74")
check("識別子が付け替わる", Draft.isAdded(rekey, "guns", "AK74"))
check("古い識別子は残らない", not Draft.isAdded(rekey, "guns", "new1"))

local rekeyed = Draft.apply(schema, base, rekey)
check("付け替えても行は 1 つ", #(rekeyed.guns :: any) == 3)
check("付け替えても値は残る", (rekeyed.guns :: any)[3].damage == 44)

-- ============================================================ 共有しないシートを外す

local mixed = Draft.empty(5)
Draft.setCell(mixed, "guns", "AK47", "damage", 35, "haru", "2026-09-09T01:00:00Z")
Draft.setCell(mixed, "loose", "1", "label", "z", "haru", "2026-09-09T01:00:01Z")
Draft.setCell(mixed, "round", Draft.SCALAR_ROW, "SECONDS", 240, "haru", "2026-09-09T01:00:02Z")

local outgoing = Draft.sharableOnly(schema, mixed)
check("key のある表は出す", outgoing.sheets.guns ~= nil)
check("scalars は出す", outgoing.sheets.round ~= nil)
check("key の無い open な表は出さない", outgoing.sheets.loose == nil)
check("元の下書きからは外れない", mixed.sheets.loose ~= nil)
check("出す方も base と rev を持つ", outgoing.base == 5 and outgoing.rev == mixed.rev)

-- 共有しないシートの下書きが、押し込みの往復で消えないこと（App._pushShared の戻し方）
local returned = Draft.sharableOnly(schema, mixed)
returned.rev += 1
local afterPush = Draft.merge(mixed, returned)
check("往復しても共有しないシートは残る", afterPush.sheets.loose ~= nil)
check("往復で rev が上がる", afterPush.rev == mixed.rev + 1)

-- ============================================================ MemoryStore の上限

check("30KB は載る", Draft.fitsInMemoryStore(30 * 1024))
check("32KB は載らない", not Draft.fitsInMemoryStore(32 * 1024))

print(`\n{if failures == 0 then "all ok" else `{failures} failed`}`)
if failures > 0 then
	process.exit(1)
end
