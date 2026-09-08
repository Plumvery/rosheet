--!strict
-- 表ビュー。ヘッダ行と行番号の列を固定し、本体だけをスクロールさせる。
--
-- 行は使い回す。行数ぶんの Frame を作ると、数百行のシートを開いた瞬間に Studio が固まる。
-- 見えている数だけ Frame を持ち、スクロールに合わせて中身を差し替える。
--
-- セルの実体は TextBox にする。Studio 上では TextBox が OS のクリップボードをそのまま扱うので、
-- Ctrl+C / Ctrl+V が何もしなくても効く。

local Schema = require(script.Parent.Schema)
local Theme = require(script.Parent.Theme)

local Grid = {}
Grid.__index = Grid

export type Callbacks = {
	onEdit: (rowIndex: number, columnName: string, value: any) -> boolean,
	isDirty: (rowIndex: number, columnName: string) -> boolean,
	onSelectRow: (rowIndex: number?) -> (),
	onError: (message: string) -> (),
}

-- scalars のシートは 1 行 = 1 定数なので、その行がどの列かは束ねるときまで決まらない。
-- `column` を持たないセルは `dynamic` として、行番号から列を引く
type Cell = {
	frame: Frame,
	box: TextBox?,
	button: TextButton?,
	label: TextLabel?,
	column: Schema.Column?,
	dynamic: boolean,
}

type Row = {
	frame: Frame,
	cells: { Cell },
	index: number?,
}

export type Grid = typeof(setmetatable({} :: {
	root: Frame,
	body: ScrollingFrame,
	headerContent: Frame,
	gutterContent: Frame,
	corner: Frame,
	pool: { Row },
	gutterLabels: { TextButton },
	sheet: Schema.Sheet?,
	value: any,
	callbacks: Callbacks?,
	widths: { number },
	offsets: { number },
	totalWidth: number,
	selected: number?,
	connections: { RBXScriptConnection },
}, Grid))

local function palette()
	return Theme.palette()
end

local function stroke(instance: GuiObject, color: Color3)
	local border = Instance.new("UIStroke")
	border.Color = color
	border.Thickness = 1
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = instance
end

local SCALAR_NAME_WIDTH = 220
local SCALAR_VALUE_WIDTH = 260

--[[ 列の幅と、左からの位置をまとめて出す。セルの配置と横スクロールの両方が使う ]]
local function measure(sheet: Schema.Sheet): ({ number }, { number }, number)
	-- scalars は列がいくつあっても「名前 | 値」の 2 列に畳む。定数は縦に並べた方が読める
	if sheet.kind == "scalars" then
		return { SCALAR_NAME_WIDTH, SCALAR_VALUE_WIDTH }, { 0, SCALAR_NAME_WIDTH }, SCALAR_NAME_WIDTH + SCALAR_VALUE_WIDTH
	end

	local widths: { number } = {}
	local offsets: { number } = {}
	local total = 0
	for index, column in sheet.columns do
		widths[index] = Theme.columnWidth(column.type)
		offsets[index] = total
		total += widths[index]
	end
	return widths, offsets, total
end

local function displayText(column: Schema.Column, value: any): string
	if column.type == "boolean" then
		return if value == true then "true" else "false"
	end
	return tostring(value)
end

function Grid.new(parent: Instance): Grid
	local colors = palette()

	local root = Instance.new("Frame")
	root.Name = "Grid"
	root.BackgroundColor3 = colors.background
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = parent

	local corner = Instance.new("Frame")
	corner.Name = "Corner"
	corner.BackgroundColor3 = colors.header
	corner.BorderSizePixel = 0
	corner.Size = UDim2.fromOffset(Theme.GUTTER_WIDTH, Theme.HEADER_HEIGHT)
	corner.ZIndex = 3
	corner.Parent = root

	local headerClip = Instance.new("Frame")
	headerClip.Name = "Header"
	headerClip.BackgroundColor3 = colors.header
	headerClip.BorderSizePixel = 0
	headerClip.ClipsDescendants = true
	headerClip.Position = UDim2.fromOffset(Theme.GUTTER_WIDTH, 0)
	headerClip.Size = UDim2.new(1, -Theme.GUTTER_WIDTH, 0, Theme.HEADER_HEIGHT)
	headerClip.ZIndex = 2
	headerClip.Parent = root

	local headerContent = Instance.new("Frame")
	headerContent.Name = "Content"
	headerContent.BackgroundTransparency = 1
	headerContent.Size = UDim2.fromScale(1, 1)
	headerContent.Parent = headerClip

	local gutterClip = Instance.new("Frame")
	gutterClip.Name = "Gutter"
	gutterClip.BackgroundColor3 = colors.header
	gutterClip.BorderSizePixel = 0
	gutterClip.ClipsDescendants = true
	gutterClip.Position = UDim2.fromOffset(0, Theme.HEADER_HEIGHT)
	gutterClip.Size = UDim2.new(0, Theme.GUTTER_WIDTH, 1, -Theme.HEADER_HEIGHT)
	gutterClip.ZIndex = 2
	gutterClip.Parent = root

	local gutterContent = Instance.new("Frame")
	gutterContent.Name = "Content"
	gutterContent.BackgroundTransparency = 1
	gutterContent.Size = UDim2.fromScale(1, 1)
	gutterContent.Parent = gutterClip

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundColor3 = colors.background
	body.BorderSizePixel = 0
	body.Position = UDim2.fromOffset(Theme.GUTTER_WIDTH, Theme.HEADER_HEIGHT)
	body.Size = UDim2.new(1, -Theme.GUTTER_WIDTH, 1, -Theme.HEADER_HEIGHT)
	body.CanvasSize = UDim2.new()
	body.ScrollBarThickness = 10
	body.Parent = root

	local self = setmetatable({
		root = root,
		body = body,
		headerContent = headerContent,
		gutterContent = gutterContent,
		corner = corner,
		pool = {},
		gutterLabels = {},
		sheet = nil,
		value = nil,
		callbacks = nil,
		widths = {},
		offsets = {},
		totalWidth = 0,
		selected = nil,
		connections = {},
	}, Grid) :: Grid

	table.insert(
		self.connections,
		body:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:_syncScroll()
		end)
	)
	table.insert(
		self.connections,
		body:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end)
	)

	return self
end

function Grid._syncScroll(self: Grid)
	local position = self.body.CanvasPosition
	self.headerContent.Position = UDim2.fromOffset(-position.X, 0)
	self.gutterContent.Position = UDim2.fromOffset(0, -position.Y)
	self:_bindVisible()
end

--[[ ヘッダの列見出しを作り直す。シートが変わったときだけ ]]
function Grid._buildHeader(self: Grid)
	local colors = palette()
	self.headerContent:ClearAllChildren()

	local sheet = self.sheet
	if sheet == nil then
		return
	end

	local headings: { Schema.Column } = sheet.columns
	if sheet.kind == "scalars" then
		headings = {
			{ name = "key", type = "string", readonly = true, description = "定数の名前", default = "" },
			{ name = "value", type = "string", readonly = false, description = "", default = "" },
		}
	end

	for index, column in headings do
		local cell = Instance.new("TextLabel")
		cell.BackgroundTransparency = 1
		cell.Position = UDim2.fromOffset(self.offsets[index], 0)
		cell.Size = UDim2.fromOffset(self.widths[index], Theme.HEADER_HEIGHT)
		cell.Font = Theme.FONT
		cell.TextSize = Theme.TEXT_SIZE
		cell.TextColor3 = if column.readonly then colors.readonlyText else colors.text
		cell.TextXAlignment = Enum.TextXAlignment.Left
		cell.Text = ` {column.name}`
		-- 列の意味と readonly はここでしか出せない。セルには出す場所が無い
		cell.Name = column.name
		local hint = if column.description ~= "" then column.description else column.type
		cell.Parent = self.headerContent

		local tip = Instance.new("TextLabel")
		tip.BackgroundTransparency = 1
		tip.Size = UDim2.fromScale(1, 1)
		tip.Font = Theme.FONT
		tip.TextSize = Theme.TEXT_SIZE - 3
		tip.TextColor3 = colors.dimText
		tip.TextXAlignment = Enum.TextXAlignment.Right
		tip.Text = if column.readonly then "readonly " else `{hint} `
		tip.TextTruncate = Enum.TextTruncate.AtEnd
		tip.Parent = cell
	end
end

--[[ セル 1 つ。列の型で見た目と編集の仕方が変わる ]]
function Grid._buildCell(self: Grid, row: Row, index: number, column: Schema.Column): Cell
	local colors = palette()

	local frame = Instance.new("Frame")
	frame.Name = column.name
	frame.BackgroundColor3 = if column.readonly then colors.readonlyCell else colors.background
	frame.BorderSizePixel = 0
	frame.Position = UDim2.fromOffset(self.offsets[index], 0)
	frame.Size = UDim2.fromOffset(self.widths[index] - 1, Theme.ROW_HEIGHT - 1)
	frame.Parent = row.frame

	local cell: Cell = { frame = frame, box = nil, button = nil, label = nil, column = column, dynamic = false }

	if column.readonly then
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Theme.FONT
		label.TextSize = Theme.TEXT_SIZE
		label.TextColor3 = colors.readonlyText
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Text = ""
		label.Parent = frame
		cell.label = label
		return cell
	end

	if column.type == "boolean" or column.type == "enum" then
		local button = Instance.new("TextButton")
		button.BackgroundTransparency = 1
		button.Size = UDim2.fromScale(1, 1)
		button.Font = Theme.FONT
		button.TextSize = Theme.TEXT_SIZE
		button.TextColor3 = colors.text
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Text = ""
		button.AutoButtonColor = false
		button.Parent = frame
		cell.button = button

		button.Activated:Connect(function()
			self:_cycle(row, cell)
		end)
		return cell
	end

	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.fromScale(1, 1)
	box.Font = Theme.FONT
	box.TextSize = Theme.TEXT_SIZE
	box.TextColor3 = colors.text
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Parent = frame
	cell.box = box

	box.Focused:Connect(function()
		self:_select(row.index)
	end)
	box.FocusLost:Connect(function()
		self:_commit(row, cell)
	end)
	return cell
end

--[[ そのセルが今どの列を映しているか。表は固定、scalars は行番号で決まる ]]
function Grid._columnFor(self: Grid, row: Row, cell: Cell): Schema.Column?
	if not cell.dynamic then
		return cell.column
	end
	local sheet = self.sheet
	local index = row.index
	if sheet == nil or index == nil then
		return nil
	end
	return sheet.columns[index]
end

--[[
	scalars の 1 行。「名前 | 値」の 2 セルで、値の列の型は行ごとに変わる。
	値のセルは常に TextBox を持ち、boolean と enum のときだけ右端に切り替えボタンを出す。
]]
function Grid._buildScalarCells(self: Grid, row: Row)
	local colors = palette()

	local nameFrame = Instance.new("Frame")
	nameFrame.BackgroundColor3 = colors.readonlyCell
	nameFrame.BorderSizePixel = 0
	nameFrame.Position = UDim2.fromOffset(self.offsets[1], 0)
	nameFrame.Size = UDim2.fromOffset(self.widths[1] - 1, Theme.ROW_HEIGHT - 1)
	nameFrame.Parent = row.frame

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.Font = Theme.FONT
	nameLabel.TextSize = Theme.TEXT_SIZE
	nameLabel.TextColor3 = colors.text
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = ""
	nameLabel.Parent = nameFrame

	row.cells[1] = { frame = nameFrame, box = nil, button = nil, label = nameLabel, column = nil, dynamic = true }

	local valueFrame = Instance.new("Frame")
	valueFrame.BackgroundColor3 = colors.background
	valueFrame.BorderSizePixel = 0
	valueFrame.Position = UDim2.fromOffset(self.offsets[2], 0)
	valueFrame.Size = UDim2.fromOffset(self.widths[2] - 1, Theme.ROW_HEIGHT - 1)
	valueFrame.Parent = row.frame

	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, -24, 1, 0)
	box.Font = Theme.FONT
	box.TextSize = Theme.TEXT_SIZE
	box.TextColor3 = colors.text
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Parent = valueFrame

	local button = Instance.new("TextButton")
	button.BackgroundTransparency = 1
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.fromScale(1, 0)
	button.Size = UDim2.new(0, 24, 1, 0)
	button.Font = Theme.FONT
	button.TextSize = Theme.TEXT_SIZE
	button.TextColor3 = colors.accent
	button.AutoButtonColor = false
	button.Text = "\u{25BC}"
	button.Visible = false
	button.Parent = valueFrame

	local cell: Cell = { frame = valueFrame, box = box, button = button, label = nil, column = nil, dynamic = true }
	row.cells[2] = cell

	box.Focused:Connect(function()
		self:_select(row.index)
	end)
	box.FocusLost:Connect(function()
		self:_commit(row, cell)
	end)
	button.Activated:Connect(function()
		self:_cycle(row, cell)
	end)
end

--[[ boolean は反転、enum は次の候補へ。ドロップダウンを出さずに済むぶん速い ]]
function Grid._cycle(self: Grid, row: Row, cell: Cell)
	local index = row.index
	local callbacks = self.callbacks
	local column = self:_columnFor(row, cell)
	if index == nil or callbacks == nil or column == nil then
		return
	end

	local current = self:_cellValue(index, column.name)
	local next: any
	if column.type == "boolean" then
		next = not current
	elseif column.type == "enum" then
		local values = column.values :: { string }
		local at = table.find(values, current)
		next = values[if at == nil or at == #values then 1 else at + 1]
	else
		return
	end

	self:_select(index)
	if callbacks.onEdit(index, column.name, next) then
		self:_bindVisible()
	end
end

function Grid._commit(self: Grid, row: Row, cell: Cell)
	local index = row.index
	local callbacks = self.callbacks
	local box = cell.box
	local column = self:_columnFor(row, cell)
	if index == nil or callbacks == nil or box == nil or column == nil then
		return
	end

	local value = Schema.coerce(column, box.Text)
	local problem = Schema.checkValue(column, value)
	if problem ~= nil then
		callbacks.onError(`{column.name}: {problem}`)
		box.Text = displayText(column, self:_cellValue(index, column.name))
		return
	end

	callbacks.onEdit(index, column.name, value)
	self:_bindVisible()
end

function Grid._cellValue(self: Grid, rowIndex: number, columnName: string): any
	local sheet = self.sheet
	if sheet == nil then
		return nil
	end
	if sheet.kind == "scalars" then
		return (self.value :: { [string]: any })[columnName]
	end
	local row = (self.value :: { { [string]: any } })[rowIndex]
	return if row == nil then nil else row[columnName]
end

function Grid._rowCount(self: Grid): number
	local sheet = self.sheet
	if sheet == nil or self.value == nil then
		return 0
	end
	-- scalars は 1 列 = 1 定数なので、行として縦に並べる（Google スプレッドシートの key/value と同じ形）
	return if sheet.kind == "scalars" then #sheet.columns else #(self.value :: { any })
end

function Grid._select(self: Grid, index: number?)
	if self.selected == index then
		return
	end
	self.selected = index
	local callbacks = self.callbacks
	if callbacks ~= nil then
		callbacks.onSelectRow(index)
	end
	self:_bindVisible()
end

function Grid.selectedRow(self: Grid): number?
	return self.selected
end

--[[ 見えている数だけ行の Frame を用意する。シートの列が変わったら作り直す ]]
function Grid._ensurePool(self: Grid)
	local sheet = self.sheet
	if sheet == nil then
		return
	end

	local needed = math.max(1, math.ceil(self.body.AbsoluteSize.Y / Theme.ROW_HEIGHT) + 2)
	while #self.pool > needed do
		local row = table.remove(self.pool) :: Row
		row.frame:Destroy()
	end

	while #self.pool < needed do
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromOffset(self.totalWidth, Theme.ROW_HEIGHT)
		frame.Visible = false
		frame.Parent = self.body

		local row: Row = { frame = frame, cells = {}, index = nil }
		if sheet.kind == "scalars" then
			self:_buildScalarCells(row)
		else
			for index, column in sheet.columns do
				row.cells[index] = self:_buildCell(row, index, column)
			end
		end
		table.insert(self.pool, row)
	end

	local gutterNeeded = needed
	while #self.gutterLabels > gutterNeeded do
		(table.remove(self.gutterLabels) :: TextButton):Destroy()
	end
	while #self.gutterLabels < gutterNeeded do
		local label = Instance.new("TextButton")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromOffset(Theme.GUTTER_WIDTH, Theme.ROW_HEIGHT - 1)
		label.Font = Theme.FONT
		label.TextSize = Theme.TEXT_SIZE - 1
		label.TextColor3 = palette().dimText
		label.AutoButtonColor = false
		label.Text = ""
		label.Visible = false
		label.Parent = self.gutterContent
		table.insert(self.gutterLabels, label)
	end
end

function Grid._bindVisible(self: Grid)
	local sheet = self.sheet
	if sheet == nil then
		return
	end

	local colors = palette()
	local callbacks = self.callbacks
	local count = self:_rowCount()
	local first = math.floor(self.body.CanvasPosition.Y / Theme.ROW_HEIGHT) + 1

	for slot, row in self.pool do
		local index = first + slot - 1
		if index > count then
			row.frame.Visible = false
			row.index = nil
		else
			row.index = index
			row.frame.Visible = true
			row.frame.Position = UDim2.fromOffset(0, (index - 1) * Theme.ROW_HEIGHT)

			for _, cell in row.cells do
				local column = self:_columnFor(row, cell)
				if column == nil then
					continue
				end

				-- scalars の名前セルは値ではなく列の名前を映す。値のセルだけが編集の対象
				local isNameCell = cell.dynamic and cell.label ~= nil
				local dirty = not isNameCell and callbacks ~= nil and callbacks.isDirty(index, column.name)
				local text = if isNameCell then column.name else displayText(column, self:_cellValue(index, column.name))

				if cell.label ~= nil then
					(cell.label :: TextLabel).Text = ` {text}`
				end
				if cell.box ~= nil then
					local box = cell.box :: TextBox
					-- 編集中のセルは触らない。入力中に書き戻すとカーソルごと消える
					if not box:IsFocused() then
						box.Text = text
					end
					box.TextEditable = not column.readonly
				end
				if cell.button ~= nil then
					local button = cell.button :: TextButton
					local pickable = column.type == "boolean" or column.type == "enum"
					if cell.dynamic then
						button.Visible = pickable and not column.readonly
					else
						button.Text = ` {text}`
					end
				end

				cell.frame.BackgroundColor3 = if dirty
					then colors.dirty
					elseif column.readonly or isNameCell then colors.readonlyCell
					elseif self.selected == index then colors.selected
					else colors.background
				cell.frame.BackgroundTransparency = if dirty then 0.55 else 0
			end
		end

		local gutter = self.gutterLabels[slot]
		if gutter ~= nil then
			gutter.Visible = row.frame.Visible
			gutter.Position = UDim2.fromOffset(0, (index - 1) * Theme.ROW_HEIGHT)
			gutter.Text = if sheet.kind == "scalars" then "" else tostring(index)
			gutter.TextColor3 = if self.selected == index then colors.text else colors.dimText
		end
	end
end

function Grid._layout(self: Grid)
	local sheet = self.sheet
	if sheet == nil then
		return
	end

	self:_ensurePool()
	self.body.CanvasSize = UDim2.fromOffset(self.totalWidth, self:_rowCount() * Theme.ROW_HEIGHT)
	self:_bindVisible()
end

function Grid.setSheet(self: Grid, sheet: Schema.Sheet, value: any, callbacks: Callbacks)
	local changedShape = self.sheet == nil or (self.sheet :: Schema.Sheet).name ~= sheet.name

	self.sheet = sheet
	self.value = value
	self.callbacks = callbacks

	if changedShape then
		for _, row in self.pool do
			row.frame:Destroy()
		end
		table.clear(self.pool)
		self.selected = nil
		self.widths, self.offsets, self.totalWidth = measure(sheet)
		self:_buildHeader()
		self.body.CanvasPosition = Vector2.zero
	end

	self:_layout()
end

function Grid.setValue(self: Grid, value: any)
	self.value = value
	self:_layout()
end

function Grid.destroy(self: Grid)
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	self.root:Destroy()
end

return Grid
