--!strict
-- rosheet の入口。スキーマの宣言（schema）とプレイテスト中の値（live）を 1 つにまとめる。
--
--     local rosheet = require(ReplicatedStorage.Packages.rosheet)
--
--     rosheet.defineSchema({ rosheet.sheet("guns", { ... }) })
--     local Guns = rosheet.bind(require(ReplicatedStorage.Config.guns), "guns")
--
-- 片方しか要らないなら子をそのまま require してもよい（`Packages.rosheet.schema` /
-- `Packages.rosheet.live`）。example/ はそちらの形で書いている。
--
-- ここを通すと live.luau も一緒に読み込まれる。live.luau は require の時点では GetService を
-- 呼ぶだけなので、ServerStorage に置いたスキーマモジュールから引いても副作用は無い。

local Live = require(script.live)
local Schema = require(script.schema)

export type ColumnType = Schema.ColumnType
export type ColumnOptions = Schema.ColumnOptions
export type Column = Schema.Column
export type SheetOptions = Schema.SheetOptions
export type Sheet = Schema.Sheet
export type DefinitionOptions = Schema.DefinitionOptions
export type Definition = Schema.Definition

return table.freeze({
	column = Schema.column,
	sheet = Schema.sheet,
	defineSchema = Schema.defineSchema,

	bind = Live.bind,
	onApplied = Live.onApplied,
	FOLDER_NAME = Live.FOLDER_NAME,
})
