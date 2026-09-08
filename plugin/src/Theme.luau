--!strict
-- Studio のテーマから色を引く。プラグインの色を自前で決めると、ユーザーがダークテーマに
-- していたときだけ読めなくなる。寸法もここに集める（Grid の仮想スクロールが行の高さに依存する）。

local Theme = {}

Theme.ROW_HEIGHT = 24
Theme.HEADER_HEIGHT = 26
Theme.GUTTER_WIDTH = 44
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
	selected: Color3,
	dirty: Color3,
	accent: Color3,
	danger: Color3,
}

function Theme.palette(): Palette
	return {
		background = color(Enum.StudioStyleGuideColor.MainBackground),
		surface = color(Enum.StudioStyleGuideColor.ViewPortBackground),
		header = color(Enum.StudioStyleGuideColor.TableItem, Enum.StudioStyleGuideModifier.Selected),
		border = color(Enum.StudioStyleGuideColor.Border),
		text = color(Enum.StudioStyleGuideColor.MainText),
		dimText = color(Enum.StudioStyleGuideColor.DimmedText),
		readonlyText = color(Enum.StudioStyleGuideColor.DimmedText),
		readonlyCell = color(Enum.StudioStyleGuideColor.MainBackground, Enum.StudioStyleGuideModifier.Disabled),
		selected = color(Enum.StudioStyleGuideColor.TableItem, Enum.StudioStyleGuideModifier.Hover),
		-- 未 Apply のセルは「まだ届いていない」ことが一目で分かる必要がある。テーマ非依存で目立たせる
		dirty = Color3.fromRGB(226, 168, 42),
		accent = color(Enum.StudioStyleGuideColor.LinkText),
		danger = color(Enum.StudioStyleGuideColor.ErrorText),
	}
end

--[[ テーマが切り替わったら呼び直す。戻り値で購読を切る ]]
function Theme.onChanged(callback: () -> ()): () -> ()
	local connection = studioTheme().Changed:Connect(callback)
	return function()
		connection:Disconnect()
	end
end

--[[ 列の型から既定の幅を決める。数値や真偽値に名前より広い幅を与えても読みやすくならない ]]
function Theme.columnWidth(columnType: string): number
	if columnType == "boolean" then
		return 68
	elseif columnType == "number" or columnType == "integer" then
		return 88
	elseif columnType == "color" then
		return 92
	elseif columnType == "text" or columnType == "asset" then
		return 200
	end
	return Theme.DEFAULT_COLUMN_WIDTH
end

return Theme
