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
