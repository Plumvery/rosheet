--!strict
-- Studio のテーマから色を引く。プラグインの色を自前で決めると、ユーザーがダークテーマに
-- していたときだけ読めなくなる。寸法もここに集める（Grid の仮想スクロールが行の高さに依存する）。

local Theme = {}

Theme.ROW_HEIGHT = 24
Theme.HEADER_HEIGHT = 26
Theme.GUTTER_WIDTH = 30
Theme.DEFAULT_COLUMN_WIDTH = 132
Theme.MIN_COLUMN_WIDTH = 48
Theme.TOOLBAR_HEIGHT = 32
Theme.TAB_HEIGHT = 26
Theme.PADDING = 6
Theme.FONT = Enum.Font.SourceSans
Theme.TEXT_SIZE = 14

local function studioTheme(): StudioTheme
	return settings().Studio.Theme :: StudioTheme
end

local function color(item: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return studioTheme():GetColor(item, modifier)
end

export type Palette = {
	background: Color3,
	surface: Color3,
	header: Color3,
	border: Color3,
	text: Color3,
	dimText: Color3,
	readonlyText: Color3,
	readonlyCell: Color3,
	stripe: Color3,
	selected: Color3,
	dirty: Color3,
	accent: Color3,
	danger: Color3,
}

--[[
	色は役割で選ぶ。Dark テーマでの実測値を括弧に書いておく（Light でも役割は同じ）。

	`TableItem` の Selected（Dark で #13235D の濃い青）はヘッダに使わない。あれは「選択中の行」の
	色で、ヘッダに敷くと表全体が選択されているように見える。ヘッダは `Light`、選択は `Item` の
	Selected に回す。readonly のセルは `TableItem` の Disabled にする —— MainBackground の
	Disabled は背景と同じ値なので、グレーアウトが見えない。
]]
function Theme.palette(): Palette
	local background = color(Enum.StudioStyleGuideColor.MainBackground) -- #191A1F
	local header = color(Enum.StudioStyleGuideColor.Light) -- #353741

	return {
		background = background,
		surface = color(Enum.StudioStyleGuideColor.Titlebar), -- #202227
		header = header,
		border = color(Enum.StudioStyleGuideColor.Border), -- #202227
		text = color(Enum.StudioStyleGuideColor.MainText), -- #BCBEC8
		dimText = color(Enum.StudioStyleGuideColor.DimmedText), -- #6A6F81
		readonlyText = color(Enum.StudioStyleGuideColor.DimmedText),
		readonlyCell = color(Enum.StudioStyleGuideColor.TableItem, Enum.StudioStyleGuideModifier.Disabled), -- #272930
		-- 1 行おきの薄い縞。テーマの色から作る（固定値だと Light テーマで背景より暗くなる）
		stripe = background:Lerp(header, 0.22),
		selected = color(Enum.StudioStyleGuideColor.Item, Enum.StudioStyleGuideModifier.Selected), -- #13235D
		-- 未 Apply のセルは「まだ届いていない」ことが一目で分かる必要がある。テーマ非依存で目立たせる
		dirty = Color3.fromRGB(226, 168, 42),
		accent = color(Enum.StudioStyleGuideColor.LinkText), -- #528BFF
		danger = color(Enum.StudioStyleGuideColor.ErrorText), -- #E75750
	}
end

--[[ テーマが切り替わったら呼び直す。戻り値で購読を切る ]]
function Theme.onChanged(callback: () -> ()): () -> ()
	local connection = studioTheme().Changed:Connect(callback)
	return function()
		connection:Disconnect()
	end
end

--[[
	列の幅。狭いほど一度に見える列が増えるので、型から決まる最小幅と、列名が切れない幅の
	大きい方を採る。説明はホバーで出すので、幅に織り込まない。
]]
function Theme.columnWidth(column: { name: string, type: string }): number
	local byType = if column.type == "boolean"
		then 58
		elseif column.type == "number" or column.type == "integer" then 72
		elseif column.type == "color" then 80
		elseif column.type == "enum" then 96
		elseif column.type == "asset" then 132
		elseif column.type == "text" then 160
		else 96

	-- 列名は識別子（ASCII）なので、1 文字 7px で足りる。enum と boolean は右端の印のぶんを足す
	local affordance = if column.type == "enum" or column.type == "boolean" then 18 else 0
	local byName = #column.name * 7 + 16 + affordance
	return math.max(Theme.MIN_COLUMN_WIDTH, byType, byName)
end

return Theme
