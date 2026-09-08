local fs = require("@lune/fs")

local rosheet = require("../runtime/schema")

local definition = rosheet.defineSchema({
	rosheet.sheet("guns", {
		key = "id",
		description = "銃の表",
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
})

print("sheets:", #definition.sheets)
print("first:", definition.sheets[1].name, definition.sheets[1].key, #definition.sheets[1].columns)
print("second:", definition.sheets[2].name, definition.sheets[2].kind)

print("bad type:", select(2, pcall(rosheet.column, "x", "nope" :: any)))
print("enum without values:", select(2, pcall(rosheet.column, "x", "enum")))
print("duplicate sheet:", select(2, pcall(rosheet.defineSchema, {
	rosheet.sheet("a", { columns = { rosheet.column("c", "string") } }),
	rosheet.sheet("a", { columns = { rosheet.column("c", "string") } }),
})))

-- 書ける place の宣言。プラグインはこれに無い place で読み取り専用になる
local sheets = { rosheet.sheet("a", { columns = { rosheet.column("c", "string") } }) }
local restricted = rosheet.defineSchema(sheets, { writablePlaces = { 102760853725708 } })
print("writablePlaces:", restricted.writablePlaces[1])
print("no writablePlaces:", rosheet.defineSchema(sheets).writablePlaces)
print("empty writablePlaces:", select(2, pcall(rosheet.defineSchema, sheets, { writablePlaces = {} })))
print("bad writablePlaces:", select(2, pcall(rosheet.defineSchema, sheets, { writablePlaces = { "102760853725708" :: any } })))

-- 知らない鍵は捨てずに落とす。捨てると「宣言したのに効かない」が黙って通る
print("unknown option:", select(2, pcall(rosheet.defineSchema, sheets, { writeablePlaces = { 1 } } :: any)))

--[[
	ランタイムの版が Source からも読めるか。

	プラグインは place に置かれた runtime/schema.luau の**テキスト**からこの版を読み、require が
	返す版（＝ Studio の恒久キャッシュに載っている古い方）と突き合わせて「Studio を開き直せ」を
	出す。定数の名前か書式を変えると、プラグインは黙って何も言わなくなる —— 落ちないぶん、
	気づけない壊れ方なのでここで見張る。
]]
-- プラグインが実際に使う pattern をそのまま取り出して当てる。書き写すと、片方だけ直したときに
-- ここが通ってしまう
local pluginPattern = string.match(fs.readFile("plugin/src/Place.luau"), 'RUNTIME_VERSION_PATTERN%s*=%s*"([^"]+)"')
assert(pluginPattern ~= nil, "plugin/src/Place.luau に RUNTIME_VERSION_PATTERN が無い")

local declaredVersion = tonumber(string.match(fs.readFile("runtime/schema.luau"), pluginPattern :: string))
print("runtime version:", rosheet.VERSION, "read by the plugin's pattern:", declaredVersion)
assert(
	declaredVersion == rosheet.VERSION,
	`プラグインの pattern（{pluginPattern}）で runtime/schema.luau から版が読めない`
)
