--!strict
-- 行データの正規化と比較。src/rows.js と同じ規則。
--
-- 差分の判定は JSON 文字列の一致ではなく構造の比較で行う。Luau のテーブルは文字列キーの順序を
-- 保たないので、JSONEncode の結果は同じ中身でも揺れうる。揺れを差分と読むと、何も変えていない
-- のに Apply が commit を積んでしまう。

local Schema = require(script.Parent.Schema)

local Rows = {}

export type SheetValue = { [string]: any } | { { [string]: any } }

local function fail(where: string, message: string): never
	error(`{where}: {message}`, 0)
end

local function normalizeRow(sheet: Schema.Sheet, raw: any, where: string): { [string]: any }
	if type(raw) ~= "table" then
		fail(where, "行はテーブルでなければならない")
	end

	local row: { [string]: any } = {}
	for _, column in sheet.columns do
		local value = if raw[column.name] == nil then column.default else raw[column.name]
		local problem = Schema.checkValue(column, value)
		if problem ~= nil then
			fail(`{where}.{column.name}`, problem)
		end
		row[column.name] = value
	end
	return row
end

function Rows.normalizeSheet(sheet: Schema.Sheet, raw: any): SheetValue
	if sheet.kind == "scalars" then
		return normalizeRow(sheet, if raw == nil then {} else raw, `sheet {sheet.name}`)
	end

	local list = if raw == nil then {} else raw
	if type(list) ~= "table" then
		fail(`sheet {sheet.name}`, "表の値は配列でなければならない")
	end

	local rows: { { [string]: any } } = {}
	local seen: { [string]: boolean } = {}
	for index, rawRow in list do
		local row = normalizeRow(sheet, rawRow, `sheet {sheet.name}[{index}]`)
		if sheet.key ~= nil then
			local key = row[sheet.key :: string]
			if key == "" then
				fail(`sheet {sheet.name}[{index}]`, `{sheet.key} が空`)
			end
			if seen[key] then
				fail(`sheet {sheet.name}[{index}]`, `{sheet.key} が重複している: {key}`)
			end
			seen[key] = true
		end
		rows[index] = row
	end
	return rows
end

function Rows.normalizeDataset(schema: Schema.Normalized, data: { [string]: any }?): { [string]: SheetValue }
	local source = if data == nil then {} else data
	local dataset: { [string]: SheetValue } = {}
	for _, sheet in schema.sheets do
		dataset[sheet.name] = Rows.normalizeSheet(sheet, source[sheet.name])
	end
	return dataset
end

function Rows.emptySheet(sheet: Schema.Sheet): SheetValue
	return if sheet.kind == "scalars" then normalizeRow(sheet, {}, sheet.name) else {}
end

--[[
	新しい行。key 列は呼び手が空でない値に差し替える。
]]
function Rows.blankRow(sheet: Schema.Sheet): { [string]: any }
	local row: { [string]: any } = {}
	for _, column in sheet.columns do
		row[column.name] = column.default
	end
	return row
end

local function rowsEqual(sheet: Schema.Sheet, a: { [string]: any }, b: { [string]: any }): boolean
	for _, column in sheet.columns do
		if a[column.name] ~= b[column.name] then
			return false
		end
	end
	return true
end

function Rows.equal(sheet: Schema.Sheet, a: SheetValue, b: SheetValue): boolean
	if sheet.kind == "scalars" then
		return rowsEqual(sheet, a :: { [string]: any }, b :: { [string]: any })
	end

	local left = a :: { { [string]: any } }
	local right = b :: { { [string]: any } }
	if #left ~= #right then
		return false
	end
	for index, row in left do
		if not rowsEqual(sheet, row, right[index]) then
			return false
		end
	end
	return true
end

function Rows.cloneSheet(sheet: Schema.Sheet, value: SheetValue): SheetValue
	if sheet.kind == "scalars" then
		return table.clone(value :: { [string]: any })
	end

	local copy: { { [string]: any } } = {}
	for index, row in value :: { { [string]: any } } do
		copy[index] = table.clone(row)
	end
	return copy
end

function Rows.cloneDataset(schema: Schema.Normalized, dataset: { [string]: SheetValue }): { [string]: SheetValue }
	local copy: { [string]: SheetValue } = {}
	for _, sheet in schema.sheets do
		copy[sheet.name] = Rows.cloneSheet(sheet, dataset[sheet.name])
	end
	return copy
end

return Rows
