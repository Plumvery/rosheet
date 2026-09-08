--!strict
-- ウィンドウの中身。スキーマの読み込み、下書きの保持、Apply、履歴。
--
-- 編集は下書きに溜め、Apply を押すまで保存先に触らない。押していない編集が黄色で残るので、
-- 「何を試そうとしていたか」が画面から消えない。

local Schema = require(script.Parent.Schema)
local Rows = require(script.Parent.Rows)
local Store = require(script.Parent.Store)
local Session = require(script.Parent.Session)
local Grid = require(script.Parent.Grid)
local Live = require(script.Parent.Live)
local Theme = require(script.Parent.Theme)
local Config = require(script.Parent.Config)
local Assets = require(script.Parent.Assets)

local Players = game:GetService("Players")
local StudioService = game:GetService("StudioService")

local HISTORY_BUTTON_WIDTH = 72

local App = {}
App.__index = App

export type App = typeof(setmetatable({} :: any, App))

--[[
	履歴に残す「誰が」。Studio のログインユーザー名を引き、引けなければ UserId を残す。
	GetNameFromUserIdAsync は待つので、開いたときに一度だけ引いて覚えておく。
]]
local author = "studio"

local function resolveAuthor()
	local gotId, userId = pcall(function()
		return StudioService:GetUserId()
	end)
	if not gotId or type(userId) ~= "number" or userId <= 0 then
		return
	end

	author = `userid:{userId}`
	local gotName, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if gotName and type(name) == "string" and name ~= "" then
		author = name
	end
end

--[[ "ServerStorage.RosheetSchema" のような文字列を実体まで辿る ]]
local function resolvePath(path: string): (Instance?, string?)
	local current: Instance = game
	for segment in string.gmatch(path, "[^%.]+") do
		local child = current:FindFirstChild(segment)
		if child == nil then
			return nil, `{path}: {current:GetFullName()} has no {segment}`
		end
		current = child
	end
	return current, nil
end

local function loadSchema(): (Schema.Normalized?, string?)
	local instance, problem = resolvePath(Config.schemaPath)
	if instance == nil then
		-- 最初に必ずここで詰まるので、次に何をすればよいかまで書く
		return nil, `{problem}. Put the schema ModuleScript in the place, or fix schema.path in rosheet.toml`
	end
	if not instance:IsA("ModuleScript") then
		return nil, `{Config.schemaPath} is not a ModuleScript`
	end

	local required, definition = pcall(require, instance)
	if not required then
		return nil, `require of the schema failed: {tostring(definition)}`
	end

	local normalized, schema = pcall(Schema.normalize, definition)
	if not normalized then
		return nil, tostring(schema)
	end

	local named, failure = pcall(Session.checkSheetNames, schema)
	if not named then
		return nil, tostring(failure)
	end
	return schema, nil
end

-- ============================================================ UI の部品

local function button(parent: Instance, text: string, width: number): TextButton
	local colors = Theme.palette()
	local instance = Instance.new("TextButton")
	instance.BackgroundColor3 = colors.surface
	instance.BorderSizePixel = 0
	instance.Size = UDim2.fromOffset(width, Theme.TOOLBAR_HEIGHT - 8)
	instance.Font = Theme.FONT
	instance.TextSize = Theme.TEXT_SIZE
	instance.TextColor3 = colors.text
	instance.Text = text
	instance.AutoButtonColor = true
	instance.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = instance
	return instance
end

--[[ 押せないボタンは見た目でも押せないと分かる必要がある ]]
local function setEnabled(instance: TextButton, enabled: boolean)
	local colors = Theme.palette()
	instance.Active = enabled
	instance.AutoButtonColor = enabled
	instance.TextColor3 = if enabled then colors.text else colors.dimText
	instance.BackgroundTransparency = if enabled then 0 else 0.55
end

-- ============================================================

function App.new(widget: DockWidgetPluginGui, plugin: Plugin): App
	local colors = Theme.palette()

	local root = Instance.new("Frame")
	root.BackgroundColor3 = colors.background
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = widget

	local self = setmetatable({
		plugin = plugin,
		widget = widget,
		root = root,
		backend = nil :: Store.Backend?,
		schema = nil :: Schema.Normalized?,
		state = nil :: Session.State?,
		draft = nil :: { [string]: any }?,
		activeSheet = 1,
		showHistory = false,
		log = { entries = {} },
		grid = nil :: any,
		buttons = {} :: { TextButton },
		busy = false,
	}, App)

	self:_buildChrome()
	self.grid:setAssets(Assets)
	-- 名前を引くのは待つので、画面を出してから別スレッドで
	task.spawn(resolveAuthor)
	self:reload()
	return self
end

function App._buildChrome(self: App)
	local colors = Theme.palette()

	local toolbar = Instance.new("Frame")
	toolbar.Name = "Toolbar"
	toolbar.BackgroundColor3 = colors.surface
	toolbar.BorderSizePixel = 0
	toolbar.Size = UDim2.new(1, 0, 0, Theme.TOOLBAR_HEIGHT)
	toolbar.Parent = self.root

	-- 左の並びだけを UIListLayout に入れる。History は右端に置きたいので、レイアウトの外に出す
	local left = Instance.new("Frame")
	left.Name = "Left"
	left.BackgroundTransparency = 1
	left.Size = UDim2.new(1, -HISTORY_BUTTON_WIDTH - Theme.PADDING * 2, 1, 0)
	left.Parent = toolbar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = left

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Theme.PADDING)
	padding.Parent = left

	self.applyButton = button(left, "Apply", 92)
	self.applyButton.LayoutOrder = 1
	self.applyButton.Activated:Connect(function()
		self:apply()
	end)

	self.discardButton = button(left, "Discard", 80)
	self.discardButton.LayoutOrder = 2
	self.discardButton.Activated:Connect(function()
		self:discard()
	end)

	self.addButton = button(left, "Add row", 76)
	self.addButton.LayoutOrder = 3
	self.addButton.Activated:Connect(function()
		self:addRow()
	end)

	self.deleteButton = button(left, "Delete row", 88)
	self.deleteButton.LayoutOrder = 4
	self.deleteButton.Activated:Connect(function()
		self:deleteRow()
	end)

	self.reloadButton = button(left, "Reload", 72)
	self.reloadButton.LayoutOrder = 5
	self.reloadButton.Activated:Connect(function()
		self:reload()
	end)

	self.status = Instance.new("TextLabel")
	self.status.BackgroundTransparency = 1
	self.status.Font = Theme.FONT
	self.status.TextSize = Theme.TEXT_SIZE
	self.status.TextColor3 = colors.dimText
	self.status.TextXAlignment = Enum.TextXAlignment.Left
	self.status.Size = UDim2.fromOffset(420, Theme.TOOLBAR_HEIGHT)
	self.status.LayoutOrder = 6
	self.status.Text = ""
	self.status.Parent = left

	-- 履歴は右から開くので、開閉も右端に置く
	self.historyButton = button(toolbar, "History", HISTORY_BUTTON_WIDTH)
	self.historyButton.AnchorPoint = Vector2.new(1, 0.5)
	self.historyButton.Position = UDim2.new(1, -Theme.PADDING, 0.5, 0)
	self.historyButton.Activated:Connect(function()
		self:toggleHistory()
	end)

	self.buttons = {
		self.applyButton,
		self.discardButton,
		self.addButton,
		self.deleteButton,
		self.reloadButton,
		self.historyButton,
	}

	local tabs = Instance.new("ScrollingFrame")
	tabs.Name = "Tabs"
	tabs.BackgroundColor3 = colors.surface
	tabs.BorderSizePixel = 0
	tabs.Position = UDim2.fromOffset(0, Theme.TOOLBAR_HEIGHT)
	tabs.Size = UDim2.new(1, 0, 0, Theme.TAB_HEIGHT)
	tabs.CanvasSize = UDim2.new()
	tabs.ScrollBarThickness = 4
	tabs.ScrollingDirection = Enum.ScrollingDirection.X
	tabs.Parent = self.root
	self.tabs = tabs

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 2)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabs

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, Theme.TOOLBAR_HEIGHT + Theme.TAB_HEIGHT)
	content.Size = UDim2.new(1, 0, 1, -(Theme.TOOLBAR_HEIGHT + Theme.TAB_HEIGHT))
	content.Parent = self.root
	self.content = content

	self.grid = Grid.new(content)

	local history = Instance.new("ScrollingFrame")
	history.Name = "History"
	history.BackgroundColor3 = colors.surface
	history.BorderSizePixel = 0
	history.AnchorPoint = Vector2.new(1, 0)
	history.Position = UDim2.fromScale(1, 0)
	history.Size = UDim2.new(0, 300, 1, 0)
	history.CanvasSize = UDim2.new()
	history.ScrollBarThickness = 8
	history.Visible = false
	history.ZIndex = 5
	history.Parent = content
	self.history = history

	local historyLayout = Instance.new("UIListLayout")
	historyLayout.Padding = UDim.new(0, 2)
	historyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	historyLayout.Parent = history

	-- 下に出す。上に出すとツールバーのボタンを覆ってしまい、エラーが出た瞬間に何も押せなくなる
	self.banner = Instance.new("TextLabel")
	self.banner.BackgroundColor3 = colors.danger
	self.banner.BorderSizePixel = 0
	self.banner.Font = Theme.FONT
	self.banner.TextSize = Theme.TEXT_SIZE
	self.banner.TextColor3 = Color3.new(1, 1, 1)
	self.banner.TextWrapped = true
	self.banner.TextXAlignment = Enum.TextXAlignment.Left
	self.banner.AnchorPoint = Vector2.new(0, 1)
	self.banner.Position = UDim2.fromScale(0, 1)
	self.banner.Size = UDim2.new(1, 0, 0, 36)
	self.banner.Visible = false
	self.banner.ZIndex = 10
	self.banner.Text = ""
	self.banner.Parent = self.root

	local bannerPadding = Instance.new("UIPadding")
	bannerPadding.PaddingLeft = UDim.new(0, Theme.PADDING)
	bannerPadding.PaddingRight = UDim.new(0, Theme.PADDING)
	bannerPadding.Parent = self.banner
end

function App._say(self: App, message: string, isError: boolean)
	if isError then
		self.banner.Text = ` {message}`
		self.banner.Visible = true
		task.delay(8, function()
			if self.banner ~= nil then
				self.banner.Visible = false
			end
		end)
	else
		self.status.Text = message
	end
end

-- ============================================================ 読み込み

function App.reload(self: App)
	local schema, problem = loadSchema()
	if schema == nil then
		self:_say(problem :: string, true)
		return
	end
	self.schema = schema

	if self.backend == nil then
		local dataStore = Store.dataStore(Config.datastore, Config.scope)
		local usable, why = Store.probe(dataStore)
		if usable then
			self.backend = dataStore
		else
			-- 公開していない place や API を入れていない環境でも触れるようにしておく。
			-- ここで諦めると「何も出ないプラグイン」になり、原因も分からない
			self.backend = Store.pluginSettings(self.plugin, Config.datastore)
			self:_say(`Falling back to local storage: {why}`, true)
		end
	end
	local backend = self.backend :: Store.Backend

	local published, failure = Session.publishSchema(backend, schema)
	if not published then
		self:_say(`Could not publish the schema: {tostring(failure)}`, true)
		return
	end

	local ok, state = Session.readCurrent(backend, schema)
	if not ok then
		self:_say(tostring(state), true)
		return
	end

	self.state = state
	self.draft = Rows.cloneDataset(schema, (state :: Session.State).dataset)
	self.activeSheet = math.min(self.activeSheet, #schema.sheets)

	local logged, log = Session.readLog(backend)
	self.log = if logged then log else { entries = {} }

	self:_buildTabs()
	self:_refreshGrid()
	self:_refreshHistory()
	self:_refreshToolbar()
end

function App._buildTabs(self: App)
	local colors = Theme.palette()
	for _, child in self.tabs:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local schema = self.schema :: Schema.Normalized
	local offset = 0
	for index, sheet in schema.sheets do
		local width = 24 + #sheet.name * 8
		local tab = Instance.new("TextButton")
		tab.BackgroundColor3 = if index == self.activeSheet then colors.background else colors.surface
		tab.BorderSizePixel = 0
		tab.Size = UDim2.fromOffset(width, Theme.TAB_HEIGHT)
		tab.Font = Theme.FONT
		tab.TextSize = Theme.TEXT_SIZE
		tab.TextColor3 = if index == self.activeSheet then colors.text else colors.dimText
		tab.Text = sheet.name
		tab.LayoutOrder = index
		tab.AutoButtonColor = false
		tab.Parent = self.tabs

		tab.Activated:Connect(function()
			self.activeSheet = index
			self:_buildTabs()
			self:_refreshGrid()
			self:_refreshToolbar()
		end)
		offset += width + 2
	end
	self.tabs.CanvasSize = UDim2.fromOffset(offset, 0)
end

function App._sheet(self: App): Schema.Sheet
	return (self.schema :: Schema.Normalized).sheets[self.activeSheet]
end

function App._refreshGrid(self: App)
	local sheet = self:_sheet()
	local draft = self.draft :: { [string]: any }
	local saved = (self.state :: Session.State).dataset

	self.grid:setSheet(sheet, draft[sheet.name], {
		onEdit = function(rowIndex: number, columnName: string, value: any): boolean
			if sheet.kind == "scalars" then
				(draft[sheet.name] :: { [string]: any })[columnName] = value
			else
				local row = (draft[sheet.name] :: { any })[rowIndex]
				if row == nil then
					return false
				end
				row[columnName] = value
			end
			self:_refreshToolbar()
			return true
		end,

		isDirty = function(rowIndex: number, columnName: string): boolean
			if sheet.kind == "scalars" then
				return (draft[sheet.name] :: any)[columnName] ~= (saved[sheet.name] :: any)[columnName]
			end
			local before = (saved[sheet.name] :: { any })[rowIndex]
			local after = (draft[sheet.name] :: { any })[rowIndex]
			if before == nil or after == nil then
				return true
			end
			return before[columnName] ~= after[columnName]
		end,

		onSelectRow = function()
			self:_refreshToolbar()
		end,

		onError = function(message: string)
			self:_say(message, true)
		end,
	})
end

-- ============================================================ 下書き

function App._changedSheets(self: App): { string }
	local schema = self.schema :: Schema.Normalized
	local saved = (self.state :: Session.State).dataset
	local draft = self.draft :: { [string]: any }

	local changed: { string } = {}
	for _, sheet in schema.sheets do
		if not Rows.equal(sheet, saved[sheet.name], draft[sheet.name]) then
			table.insert(changed, sheet.name)
		end
	end
	return changed
end

function App._refreshToolbar(self: App)
	if self.schema == nil or self.state == nil then
		return
	end

	local changed = self:_changedSheets()
	local sheet = self:_sheet()
	local state = self.state :: Session.State

	local idle = not self.busy
	local dirty = #changed > 0

	self.applyButton.Text = if self.busy then "Applying..." elseif dirty then `Apply ({#changed})` else "Apply"
	setEnabled(self.applyButton, idle and dirty)
	-- Discard は常に出す。変更があるときだけ現れると、押せる場所が動いて狙いにくい
	setEnabled(self.discardButton, idle and dirty)

	local canAddRows = sheet.kind == "table" and sheet.rows == "open"
	setEnabled(self.addButton, idle and canAddRows)
	setEnabled(self.deleteButton, idle and canAddRows and self.grid:selectedRow() ~= nil)
	setEnabled(self.historyButton, idle)
	setEnabled(self.reloadButton, idle)
	self.historyButton.Text = if self.showHistory then "History \u{25B8}" else "History"

	local backend = self.backend :: Store.Backend
	local where = if Live.isPlaying() then " \u{00B7} playing" else ""
	self.status.Text = `#{state.head} \u{00B7} {backend.label}{where}`
end

--[[ Apply の最中は表もツールバーも触らせない。触れると送っている内容と画面が食い違う ]]
function App._setBusy(self: App, busy: boolean)
	self.busy = busy
	self.grid:setLocked(busy)
	self:_refreshToolbar()
end

--[[
	取り消せない操作の前に挟む。背後を覆うので、開いている間は表もツールバーも触れない。
]]
function App._confirm(self: App, message: string, confirmLabel: string, onConfirm: () -> ())
	local colors = Theme.palette()

	local overlay = Instance.new("TextButton")
	overlay.BackgroundColor3 = colors.background
	overlay.BackgroundTransparency = 0.4
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.ZIndex = 40
	overlay.Parent = self.root

	local box = Instance.new("Frame")
	box.BackgroundColor3 = colors.surface
	box.BorderSizePixel = 0
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromOffset(380, 116)
	box.ZIndex = 41
	box.Parent = overlay

	local outline = Instance.new("UIStroke")
	outline.Color = colors.header
	outline.Thickness = 1
	outline.Parent = box

	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Position = UDim2.fromOffset(16, 16)
	text.Size = UDim2.new(1, -32, 0, 56)
	text.Font = Theme.FONT
	text.TextSize = Theme.TEXT_SIZE
	text.TextColor3 = colors.text
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.TextWrapped = true
	text.Text = message
	text.ZIndex = 42
	text.Parent = box

	local function close()
		overlay:Destroy()
	end

	local cancel = button(box, "Cancel", 88)
	cancel.AnchorPoint = Vector2.new(1, 1)
	cancel.Position = UDim2.new(1, -104, 1, -14)
	cancel.ZIndex = 42
	cancel.Activated:Connect(close)

	local confirm = button(box, confirmLabel, 88)
	confirm.AnchorPoint = Vector2.new(1, 1)
	confirm.Position = UDim2.new(1, -12, 1, -14)
	confirm.BackgroundColor3 = colors.danger
	confirm.TextColor3 = Color3.new(1, 1, 1)
	confirm.ZIndex = 42
	confirm.Activated:Connect(function()
		close()
		onConfirm()
	end)

	-- 覆いを押したら取り消し。閉じ方が分からなくなるのを避ける
	overlay.Activated:Connect(close)
end

function App.discard(self: App)
	if self.busy then
		return
	end
	local changed = self:_changedSheets()
	if #changed == 0 then
		return
	end

	-- 捨てた編集は戻せない（Apply していないので履歴にも無い）。確認を挟む
	self:_confirm(`Discard unapplied edits in {table.concat(changed, ", ")}?`, "Discard", function()
		local schema = self.schema :: Schema.Normalized
		self.draft = Rows.cloneDataset(schema, (self.state :: Session.State).dataset)
		self:_refreshGrid()
		self:_refreshToolbar()
	end)
end

function App.toggleHistory(self: App)
	if self.busy then
		return
	end
	self.showHistory = not self.showHistory
	self:_refreshHistory()
	self:_refreshToolbar()
end

function App.addRow(self: App)
	local sheet = self:_sheet()
	if self.busy or sheet.kind ~= "table" or sheet.rows ~= "open" then
		return
	end

	local rows = (self.draft :: { [string]: any })[sheet.name] :: { any }
	local row = Rows.blankRow(sheet)
	if sheet.key ~= nil then
		-- key は空を許さないので、重複しない仮の値を入れる。すぐ書き換えられる
		local candidate = `new{#rows + 1}`
		local taken = true
		local attempt = #rows + 1
		while taken do
			taken = false
			for _, existing in rows do
				if existing[sheet.key] == candidate then
					taken = true
					attempt += 1
					candidate = `new{attempt}`
					break
				end
			end
		end
		row[sheet.key] = candidate
	end

	table.insert(rows, row)
	self.grid:setValue(rows)
	self:_refreshToolbar()
end

function App.deleteRow(self: App)
	local sheet = self:_sheet()
	local index = self.grid:selectedRow()
	if self.busy or sheet.kind ~= "table" or sheet.rows ~= "open" or index == nil then
		return
	end

	local rows = (self.draft :: { [string]: any })[sheet.name] :: { any }
	if rows[index] == nil then
		return
	end
	table.remove(rows, index)
	self.grid:setValue(rows)
	self:_refreshToolbar()
end

-- ============================================================ Apply と履歴

function App.apply(self: App)
	if self.busy then
		return
	end
	local changed = self:_changedSheets()
	if #changed == 0 then
		return
	end

	self:_setBusy(true)

	task.spawn(function()
		local backend = self.backend :: Store.Backend
		local schema = self.schema :: Schema.Normalized
		local ok, result =
			Session.apply(backend, schema, self.state :: Session.State, self.draft :: any, { at = DateTime.now():ToIsoDate(), by = author, note = "" })

		self:_setBusy(false)
		if not ok then
			self:_say(`Apply failed: {tostring(result)}`, true)
			return
		end

		local commit = result :: Session.Commit
		Live.publish(schema, self.draft :: any, commit.seq)
		self:reload()
		self:_say(`Applied #{commit.seq}: {table.concat(changed, ", ")}`, false)
	end)
end

function App._refreshHistory(self: App)
	self.history.Visible = self.showHistory
	if not self.showHistory then
		return
	end

	local colors = Theme.palette()
	for _, child in self.history:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local height = 0
	for order, entry in self.log.entries do
		local card = Instance.new("Frame")
		card.BackgroundColor3 = colors.background
		card.BorderSizePixel = 0
		card.Size = UDim2.new(1, -8, 0, 52)
		card.LayoutOrder = order
		card.Parent = self.history

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(6, 2)
		title.Size = UDim2.new(1, -70, 0, 18)
		title.Font = Theme.FONT
		title.TextSize = Theme.TEXT_SIZE
		title.TextColor3 = colors.text
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		local reverted = if entry.revertOf ~= nil then ` (revert of #{entry.revertOf})` else ""
		title.Text = `#{entry.seq}{reverted}`
		title.Parent = card

		local detail = Instance.new("TextLabel")
		detail.BackgroundTransparency = 1
		detail.Position = UDim2.fromOffset(6, 20)
		detail.Size = UDim2.new(1, -70, 0, 30)
		detail.Font = Theme.FONT
		detail.TextSize = Theme.TEXT_SIZE - 2
		detail.TextColor3 = colors.dimText
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.TextYAlignment = Enum.TextYAlignment.Top
		detail.TextWrapped = true
		local who = if entry.by ~= nil and entry.by ~= "" then entry.by else "?"
		detail.Text = `{entry.at or "?"}  ·  {who}\n{table.concat(entry.changed, ", ")}`
		detail.Parent = card

		local restore = button(card, "Restore", 52)
		restore.AnchorPoint = Vector2.new(1, 0.5)
		restore.Position = UDim2.new(1, -6, 0.5, 0)
		restore.Activated:Connect(function()
			self:revertTo(entry.seq)
		end)

		height += 54
	end

	self.history.CanvasSize = UDim2.fromOffset(0, height)
end

function App.revertTo(self: App, seq: number)
	if self.busy then
		return
	end
	if #self:_changedSheets() > 0 then
		self:_say("There are unapplied edits. Apply or discard them first.", true)
		return
	end

	self.busy = true
	task.spawn(function()
		local backend = self.backend :: Store.Backend
		local found, target = Session.readCommit(backend, seq)
		if not found or target == nil then
			self.busy = false
			self:_say(`Could not read commit #{seq}`, true)
			return
		end

		local ok, result = Session.revert(backend, self.state :: Session.State, target, { at = DateTime.now():ToIsoDate(), by = author, note = nil })
		self.busy = false
		if not ok then
			self:_say(`Restore failed: {tostring(result)}`, true)
			return
		end

		self:_say(`Restored the values of #{seq} as #{(result :: Session.Commit).seq}`, false)
		self:reload()

		local schema = self.schema :: Schema.Normalized
		Live.publish(schema, (self.state :: Session.State).dataset, (result :: Session.Commit).seq)
	end)
end

function App.destroy(self: App)
	if self.grid ~= nil then
		self.grid:destroy()
	end
	self.root:Destroy()
end

return App
