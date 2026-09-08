--!strict
-- スキーマの正規化と検証（プラグイン側）。src/schema.js と同じ規則を Luau で実装する。
--
-- 2 つ持つのは、プラグインが place のスキーマモジュールを require して DataStore へ置く側で、
-- CLI は置かれた結果を読む側だから。CLI に Luau の評価器を持たせない代わりに、規則だけを写す。
-- どちらかを変えたら両方変える。

local Schema = {}

export type Column = {
	name: string,
	type: string,
	readonly: boolean,
	description: string,
	default: any,
	values: { string }?,
	min: number?,
	max: number?,
}

export type Sheet = {
	name: string,
	kind: string,
	key: string?,
	rows: string,
	description: string,
	columns: { Column },
}

export type Normalized = { version: number, sheets: { Sheet } }

local COLUMN_TYPES: { [string]: boolean } = {
	string = true,
	text = true,
	number = true,
	integer = true,
	boolean = true,
	enum = true,
	asset = true,
	color = true,
}

local IDENTIFIER = "^[A-Za-z_][A-Za-z0-9_]*$"

local function fail(where: string, message: string): never
	error(`{where}: {message}`, 0)
end

local function implicitDefault(columnType: string, values: { string }?): any
	if columnType == "number" or columnType == "integer" then
		return 0
	elseif columnType == "boolean" then
		return false
	elseif columnType == "enum" then
		return (values :: { string })[1]
	elseif columnType == "color" then
		return "#FFFFFF"
	end
	return ""
end

--[[
	値が列の型に合うなら nil、合わないなら理由を返す。Grid のセル編集もこれで弾く。
]]
function Schema.checkValue(column: Column, value: any): string?
	local columnType = column.type

	if columnType == "string" or columnType == "text" then
		return if type(value) == "string" then nil else "not a string"
	elseif columnType == "number" or columnType == "integer" then
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return "not a finite number"
		end
		if columnType == "integer" and value % 1 ~= 0 then
			return `not an integer: {value}`
		end
		if column.min ~= nil and value < column.min then
			return `below min {column.min}: {value}`
		end
		if column.max ~= nil and value > column.max then
			return `above max {column.max}: {value}`
		end
		return nil
	elseif columnType == "boolean" then
		return if type(value) == "boolean" then nil else "not a boolean"
	elseif columnType == "enum" then
		if type(value) ~= "string" then
			return "not a string"
		end
		for _, candidate in column.values :: { string } do
			if candidate == value then
				return nil
			end
		end
		return `not one of the allowed values: {value}`
	elseif columnType == "asset" then
		if type(value) ~= "string" then
			return "not a string"
		end
		-- 空を許すのは「まだ差し替えていない」を表せないと嘘の ID を入れる羽目になるため。
		-- rocas:// は保存先にこの形のまま置き、生成のときに実 ID へ解決する（src/assets.js）
		if value == "" or string.match(value, "^rbxassetid://%d+$") ~= nil then
			return nil
		end
		if string.match(value, "^rocas://assets/%S+$") ~= nil then
			return nil
		end
		return "not empty, rbxassetid://<number> or rocas://assets/..."
	elseif columnType == "color" then
		if type(value) ~= "string" then
			return "not a string"
		end
		return if string.match(value, "^#%x%x%x%x%x%x$") ~= nil then nil else "not #RRGGBB"
	end

	return `unsupported column type: {columnType}`
end

local function normalizeColumn(raw: any, where: string): Column
	if type(raw) ~= "table" then
		fail(where, "a column must be a table")
	end
	if type(raw.name) ~= "string" or string.match(raw.name, IDENTIFIER) == nil then
		fail(where, `column name is not a usable identifier: {tostring(raw.name)}`)
	end

	local at = `{where}.{raw.name}`
	if not COLUMN_TYPES[raw.type] then
		fail(at, `unsupported column type: {tostring(raw.type)}`)
	end

	local values: { string }? = nil
	if raw.type == "enum" then
		if type(raw.values) ~= "table" or #raw.values == 0 then
			fail(at, "enum needs values")
		end
		values = table.clone(raw.values)
		local seen: { [string]: boolean } = {}
		for _, value in values :: { string } do
			if type(value) ~= "string" then
				fail(at, "enum values must all be strings")
			end
			if seen[value] then
				fail(at, `duplicate enum value: {value}`)
			end
			seen[value] = true
		end
	end

	local column: Column = {
		name = raw.name,
		type = raw.type,
		readonly = raw.readonly == true,
		description = if type(raw.description) == "string" then raw.description else "",
		default = if raw.default == nil then implicitDefault(raw.type, values) else raw.default,
		values = values,
		min = raw.min,
		max = raw.max,
	}

	if column.min ~= nil and column.max ~= nil and column.min > column.max then
		fail(at, `min is greater than max: {column.min} > {column.max}`)
	end

	local problem = Schema.checkValue(column, column.default)
	if problem ~= nil then
		fail(at, `default does not match the column type: {problem}`)
	end

	return column
end

local function normalizeSheet(raw: any, where: string): Sheet
	if type(raw) ~= "table" then
		fail(where, "a sheet must be a table")
	end
	if type(raw.name) ~= "string" or string.match(raw.name, IDENTIFIER) == nil then
		fail(where, `sheet name is not a usable identifier: {tostring(raw.name)}`)
	end

	local at = `sheet {raw.name}`
	local kind = if raw.kind == nil then "table" else raw.kind
	if kind ~= "table" and kind ~= "scalars" then
		fail(at, `unsupported sheet kind: {tostring(kind)}`)
	end
	if type(raw.columns) ~= "table" or #raw.columns == 0 then
		fail(at, "columns is empty")
	end

	local columns: { Column } = {}
	local seen: { [string]: boolean } = {}
	for index, rawColumn in raw.columns do
		local column = normalizeColumn(rawColumn, at)
		if seen[column.name] then
			fail(at, `duplicate column name: {column.name}`)
		end
		seen[column.name] = true
		columns[index] = column
	end

	local key: string? = nil
	if kind == "table" and raw.key ~= nil then
		key = raw.key
		local found: Column? = nil
		for _, column in columns do
			if column.name == key then
				found = column
			end
		end
		if found == nil then
			fail(at, `no such column for key: {key}`)
		end
		if (found :: Column).type ~= "string" then
			fail(at, `the key column must be a string: {key} is {(found :: Column).type}`)
		end
	end

	return {
		name = raw.name,
		kind = kind,
		key = key,
		-- scalars は 1 列 = 1 定数で、行の増減という概念が無い
		rows = if kind == "scalars" or raw.rows == "fixed" then "fixed" else "open",
		description = if type(raw.description) == "string" then raw.description else "",
		columns = columns,
	}
end

--[[
	`defineSchema` の戻り値を、DataStore へ置く正規形に落とす。宣言順は保つ。
]]
function Schema.normalize(definition: any): Normalized
	if type(definition) ~= "table" or type(definition.sheets) ~= "table" then
		fail("schema", "not the return value of defineSchema")
	end
	if #definition.sheets == 0 then
		fail("schema", "sheets is empty")
	end

	local sheets: { Sheet } = {}
	local seen: { [string]: boolean } = {}
	for index, rawSheet in definition.sheets do
		local sheet = normalizeSheet(rawSheet, `sheets[{index}]`)
		if seen[sheet.name] then
			fail("schema", `duplicate sheet name: {sheet.name}`)
		end
		seen[sheet.name] = true
		sheets[index] = sheet
	end

	return { version = 1, sheets = sheets }
end

function Schema.findColumn(sheet: Sheet, name: string): Column?
	for _, column in sheet.columns do
		if column.name == name then
			return column
		end
	end
	return nil
end

--[[
	テキスト入力を列の型へ寄せる。Grid のセル編集と、貼り付けたテキストの取り込みが使う。
]]
function Schema.coerce(column: Column, text: string): any
	local columnType = column.type

	if columnType == "number" or columnType == "integer" then
		local trimmed = string.match(text, "^%s*(.-)%s*$") :: string
		if trimmed == "" then
			return column.default
		end
		local value = tonumber(trimmed)
		-- 数値として読めないときは元のテキストを返す。checkValue が理由付きで弾く
		return if value == nil then text else value
	elseif columnType == "boolean" then
		local lowered = string.lower(string.match(text, "^%s*(.-)%s*$") :: string)
		if lowered == "true" or lowered == "1" or lowered == "yes" then
			return true
		elseif lowered == "false" or lowered == "0" or lowered == "no" or lowered == "" then
			return false
		end
		return text
	elseif columnType == "color" then
		return string.upper(string.match(text, "^%s*(.-)%s*$") :: string)
	end

	return text
end

return Schema
