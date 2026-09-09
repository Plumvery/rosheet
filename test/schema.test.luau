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
local restricted = rosheet.defineSchema(sheets, { writablePlaces = { 1234567890123 } })
print("writablePlaces:", restricted.writablePlaces[1])
print("no writablePlaces:", rosheet.defineSchema(sheets).writablePlaces)
print("empty writablePlaces:", select(2, pcall(rosheet.defineSchema, sheets, { writablePlaces = {} })))
print("bad writablePlaces:", select(2, pcall(rosheet.defineSchema, sheets, { writablePlaces = { "1234567890123" :: any } })))

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

--[[
	ランタイムがスキーマの候補に混ざらないか。

	プラグインは Source に `defineSchema` が含まれるかで place のスキーマを探す。ランタイムは
	それを**定義している**側なので必ず当たる —— `RosheetSchema` があるあいだは名前の一致が先に
	並ぶので表に出ないが、それが place から消えた瞬間に第一候補へ繰り上がり、「この place に
	スキーマが無い」と言うべき場面で、触ってはいけないランタイムの名前が理由として出る。

	外し方は「版の目印を持つモジュールと、それを抱えているモジュール」。目印を持つのは
	schema.luau だけで、入口の init.luau はそれを子に持つので一緒に外れる。**その 2 本以外の
	ランタイムファイルが `defineSchema` を含むと、また候補に戻る**ので、ここで見張る。
]]
local schemaMarker = string.match(fs.readFile("plugin/src/Place.luau"), 'SCHEMA_MARKER%s*=%s*"([^"]+)"')
assert(schemaMarker ~= nil, "plugin/src/Place.luau に SCHEMA_MARKER が無い")

for _, entry in fs.readDir("runtime") do
	if string.match(entry, "%.luau$") == nil then
		continue
	end
	local source = fs.readFile(`runtime/{entry}`)
	if string.find(source, schemaMarker :: string, 1, true) == nil then
		continue
	end

	-- init.luau は目印を持つ schema.luau を子に持つので、抱えている側として外れる
	local excluded = entry == "init.luau" or string.match(source, pluginPattern :: string) ~= nil
	print("runtime candidate:", entry, "excluded:", excluded)
	assert(excluded, `runtime/{entry} は {schemaMarker} を含むのに、プラグインの候補から外れない`)
end
