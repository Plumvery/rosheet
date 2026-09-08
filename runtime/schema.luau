--!strict
-- rosheet のスキーマ定義。ゲーム側のプロジェクトがこれを require してシートと列を宣言する。
--
-- 列もシートも配列で受ける。Luau のテーブルは文字列キーの順序を保たないので、辞書で受けると
-- プラグインの列やタブの並びが起動のたびに変わる。

local Schema = {}

export type ColumnType = "string" | "text" | "number" | "integer" | "boolean" | "enum" | "asset" | "color"

export type ColumnOptions = {
	readonly: boolean?,
	default: any?,
	description: string?,
	values: { string }?,
	min: number?,
	max: number?,
}

export type Column = {
	name: string,
	type: ColumnType,
	readonly: boolean?,
	default: any?,
	description: string?,
	values: { string }?,
	min: number?,
	max: number?,
}

export type SheetOptions = {
	kind: ("table" | "scalars")?,
	key: string?,
	rows: ("open" | "fixed")?,
	description: string?,
	columns: { Column },
}

export type Sheet = {
	name: string,
	kind: string?,
	key: string?,
	rows: string?,
	description: string?,
	columns: { Column },
}

export type Definition = { sheets: { Sheet } }

local VALID_TYPES: { [string]: boolean } = {
	string = true,
	text = true,
	number = true,
	integer = true,
	boolean = true,
	enum = true,
	asset = true,
	color = true,
}

--[[
	1 列を宣言する。

		rosheet.column("damage", "number", { default = 10, min = 0 })
		rosheet.column("rarity", "enum", { values = { "Common", "Rare" } })
]]
function Schema.column(name: string, columnType: ColumnType, options: ColumnOptions?): Column
	assert(type(name) == "string" and name ~= "", "rosheet.column: 列名が要る")
	assert(VALID_TYPES[columnType], `rosheet.column({name}): 未対応の列の型: {tostring(columnType)}`)

	local settings = options or {}
	if columnType == "enum" then
		local values = settings.values
		assert(type(values) == "table" and #values > 0, `rosheet.column({name}): enum には values が要る`)
	end

	return {
		name = name,
		type = columnType,
		readonly = settings.readonly,
		default = settings.default,
		description = settings.description,
		values = settings.values,
		min = settings.min,
		max = settings.max,
	}
end

--[[
	1 シートを宣言する。既定は表（`kind = "scalars"` にすると key/value の定数集合）。

		rosheet.sheet("guns", {
			key = "id",
			columns = { rosheet.column("id", "string", { readonly = true }) },
		})
]]
function Schema.sheet(name: string, options: SheetOptions): Sheet
	assert(type(name) == "string" and name ~= "", "rosheet.sheet: シート名が要る")
	assert(type(options) == "table" and type(options.columns) == "table", `rosheet.sheet({name}): columns が要る`)
	assert(#options.columns > 0, `rosheet.sheet({name}): columns が空`)

	return {
		name = name,
		kind = options.kind,
		key = options.key,
		rows = options.rows,
		description = options.description,
		columns = options.columns,
	}
end

--[[
	スキーマ全体。この戻り値を返す ModuleScript を rosheet.toml の `schema.path` が指す。
]]
function Schema.defineSchema(sheets: { Sheet }): Definition
	assert(type(sheets) == "table" and #sheets > 0, "rosheet.defineSchema: シートが空")

	local seen: { [string]: boolean } = {}
	for _, sheet in sheets do
		assert(not seen[sheet.name], `rosheet.defineSchema: シート名が重複している: {sheet.name}`)
		seen[sheet.name] = true
	end

	return table.freeze({ sheets = sheets })
end

return table.freeze(Schema)
