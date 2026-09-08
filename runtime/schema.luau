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

export type DefinitionOptions = {
	datastore: string?,
	scope: string?,
	writablePlaces: { number }?,
}

export type Definition = { sheets: { Sheet }, datastore: string?, scope: string?, writablePlaces: { number }? }

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
	assert(type(name) == "string" and name ~= "", "rosheet.column: a column name is required")
	assert(VALID_TYPES[columnType], `rosheet.column({name}): unsupported column type: {tostring(columnType)}`)

	local settings = options or {}
	if columnType == "enum" then
		local values = settings.values
		assert(type(values) == "table" and #values > 0, `rosheet.column({name}): enum needs values`)
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
	assert(type(name) == "string" and name ~= "", "rosheet.sheet: a sheet name is required")
	assert(type(options) == "table" and type(options.columns) == "table", `rosheet.sheet({name}): columns is required`)
	assert(#options.columns > 0, `rosheet.sheet({name}): columns is empty`)

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
	スキーマ全体。この戻り値を返す ModuleScript を、プラグインが ServerStorage /
	ReplicatedStorage から見つけて読む（`RosheetSchema` という名前が確実）。

	保存先も第 2 引数で宣言する。プラグインが要る設定はこれだけで、これも place の中に置く。
	プラグインには何も焼かないので、変えてもプラグインは入れ直さなくてよい。

		rosheet.defineSchema({ ... }, { datastore = "rosheet", scope = "master" })

	CLI は同じ値を rosheet.toml の `project.datastore` / `project.scope` で読む。
	既定から変えるなら両方に書く。

	`writablePlaces` を宣言すると、そこに無い place ではプラグインが読み取り専用になる。

		rosheet.defineSchema({ ... }, { writablePlaces = { 102760853725708 } })

	同じ universe の place は DataStore を共有するので、本番 place を Studio で開くことが
	そのまま master data への書き込み権限になる。宣言は git に載るので、増やすには PR が要る。

	**これは事故を止めるためのもので、権限の境界ではない。** DataStore の書き込み権限は
	universe 単位なので、この宣言を書き換えた place を開けば書ける。
]]
function Schema.defineSchema(sheets: { Sheet }, options: DefinitionOptions?): Definition
	assert(type(sheets) == "table" and #sheets > 0, "rosheet.defineSchema: sheets is empty")

	local settings = options or {}
	assert(
		settings.datastore == nil or (type(settings.datastore) == "string" and settings.datastore ~= ""),
		"rosheet.defineSchema: datastore must be a non-empty string"
	)
	assert(
		settings.scope == nil or (type(settings.scope) == "string" and settings.scope ~= ""),
		"rosheet.defineSchema: scope must be a non-empty string"
	)

	local places = settings.writablePlaces
	if places ~= nil then
		assert(type(places) == "table", "rosheet.defineSchema: writablePlaces must be an array of place ids")
		-- 空の配列は「どの place からも書けない」。書き間違いと区別が付かないので弾く
		assert(#places > 0, "rosheet.defineSchema: writablePlaces is empty (leave it out to allow every place)")
		for _, placeId in places do
			assert(
				type(placeId) == "number" and placeId == math.floor(placeId) and placeId > 0,
				`rosheet.defineSchema: writablePlaces must all be place ids: {tostring(placeId)}`
			)
		end
	end

	local seen: { [string]: boolean } = {}
	for _, sheet in sheets do
		assert(not seen[sheet.name], `rosheet.defineSchema: duplicate sheet name: {sheet.name}`)
		seen[sheet.name] = true
	end

	return table.freeze({
		sheets = sheets,
		datastore = settings.datastore,
		scope = settings.scope,
		writablePlaces = if places == nil then nil else table.freeze(table.clone(places)),
	})
end

return table.freeze(Schema)
