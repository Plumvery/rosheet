--!strict
-- スキーマの正規化が Luau 側（plugin/src/Schema.luau）と JS 側（src/schema.js）で一致するか。
--
-- 2 つ持っているのは、プラグインがスキーマを DataStore へ置く側で CLI が読む側だから。
-- ここがズレると「Studio では通るのに pull で落ちる」スキーマができる。
-- このスクリプトが Luau 側の結果を build/schema.luau.json に書き、
-- test/normalize.test.js が JS 側の結果と突き合わせる。

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local rosheet = require("../runtime/schema")
local Schema = require("../plugin/src/Schema")

local definition = rosheet.defineSchema({
	rosheet.sheet("guns", {
		key = "id",
		description = "銃のパラメータ",
		columns = {
			rosheet.column("id", "string", { readonly = true, description = "コードから引くキー" }),
			rosheet.column("name", "string"),
			rosheet.column("damage", "number", { default = 10, min = 0, description = "1 発のダメージ" }),
			rosheet.column("fireRate", "number", { default = 0.2, min = 0.01, max = 10 }),
			rosheet.column("rarity", "enum", { values = { "Common", "Rare", "Epic", "Legendary" } }),
			rosheet.column("icon", "asset"),
			rosheet.column("enabled", "boolean", { default = true }),
			rosheet.column("note", "text"),
		},
	}),
	rosheet.sheet("rarities", {
		key = "id",
		rows = "fixed",
		columns = {
			rosheet.column("id", "string", { readonly = true }),
			rosheet.column("color", "color", { default = "#FFFFFF" }),
		},
	}),
	rosheet.sheet("round", {
		kind = "scalars",
		description = "ラウンド進行の定数",
		columns = {
			rosheet.column("SECONDS", "integer", { default = 180, min = 30 }),
			rosheet.column("MIN_PLAYERS", "integer", { default = 2, min = 1 }),
			rosheet.column("LABEL", "string", { default = "ラウンド" }),
		},
	}),
})

local normalized = Schema.normalize(definition)

local failures = 0
local function check(name: string, condition: boolean, detail: string?)
	if condition then
		print(`ok    {name}`)
	else
		failures += 1
		print(`FAIL  {name}{if detail ~= nil then ` — {detail}` else ""}`)
	end
end

check("宣言順を保つ", normalized.sheets[1].name == "guns" and normalized.sheets[3].name == "round")
check("既定値の無い string は空文字", normalized.sheets[1].columns[2].default == "")
check("enum の既定値は先頭の候補", normalized.sheets[1].columns[5].default == "Common")
check("boolean の既定値が残る", normalized.sheets[1].columns[7].default == true)
check("readonly が伝わる", normalized.sheets[1].columns[1].readonly == true)
check("readonly の既定は false", normalized.sheets[1].columns[2].readonly == false)
check("rows=fixed が伝わる", normalized.sheets[2].rows == "fixed")
check("scalars は常に fixed", normalized.sheets[3].rows == "fixed" and normalized.sheets[3].kind == "scalars")
check("scalars は key を持たない", normalized.sheets[3].key == nil)

local bad = { { name = "壊れたスキーマは落ちる", run = function()
	Schema.normalize({ sheets = { { name = "a", columns = { { name = "x", type = "nope" } } } } })
end } }
for _, case in bad do
	check(case.name, not pcall(case.run))
end

check("範囲の逆転を弾く", not pcall(function()
	Schema.normalize({
		sheets = { { name = "a", columns = { { name = "x", type = "number", min = 5, max = 1 } } } },
	})
end))
check("default が型に合わないと弾く", not pcall(function()
	Schema.normalize({
		sheets = { { name = "a", columns = { { name = "x", type = "number", default = "no" } } } },
	})
end))
check("key に string 以外は弾く", not pcall(function()
	Schema.normalize({
		sheets = { { name = "a", key = "x", columns = { { name = "x", type = "number" } } } },
	})
end))

if not fs.isDir("build") then
	fs.writeDir("build")
end
fs.writeFile("build/schema.luau.json", serde.encode("json", normalized, true))
print("\nwrote build/schema.luau.json")

if failures > 0 then
	process.exit(1)
end
