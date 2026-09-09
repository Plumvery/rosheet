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
local Place = require(script.Parent.Place)

local Players = game:GetService("Players")
local StudioService = game:GetService("StudioService")

local HISTORY_BUTTON_WIDTH = 72
-- "Restoring..." が入る幅。押している間だけ文言が伸びるので、狭いと切れる
local RESTORE_BUTTON_WIDTH = 88

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

-- スキーマモジュールが宣言していないときの DataStore 名。rosheet.toml の project.datastore の
-- 既定と揃える。ここがズレると、CLI とプラグインが別の DataStore を見て、どちらも「値が無い」
-- としか言えなくなる
local DEFAULT_DATASTORE = "rosheet"

type Loaded = { schema: Schema.Normalized, datastore: string, scope: string?, readOnly: string? }

--[[
	この place から書いてよいか。`writablePlaces` を宣言していないスキーマは今までどおり全許可。

	同じ universe の place は DataStore を共有するので、本番 place を Studio で開くことが
	そのまま master data への書き込み権限になる。これはその事故を止めるためのもので、権限の
	境界ではない（DataStore の権限は universe 単位なので、宣言を書き換えれば書ける）。
]]
local function readOnlyReason(declared: { writablePlaces: any }): string?
	local places = declared.writablePlaces
	if type(places) ~= "table" or #places == 0 then
		return nil
	end

	local placeId = game.PlaceId
	for _, allowed in places do
		if allowed == placeId then
			return nil
		end
	end

	-- 番号だけ出しても照合できないので、宣言されている側も並べる
	local allowed: { string } = {}
	for _, id in places do
		table.insert(allowed, tostring(id))
	end
	return `This place ({placeId}) is not in writablePlaces ({table.concat(allowed, ", ")}), so rosheet is read-only here`
end

--[[
	place の中からスキーマモジュールを見つけて読む。

	候補を確からしい順に試し、最初に正規化まで通ったものを採る。プラグインには何も焼かないので、
	スキーマを置き換えても、Rojo が同期し直せばそのまま拾える。

	DataStore 名と scope もここで読む。プラグインが要る設定はこの 2 つだけで、どちらも
	スキーマモジュールが宣言する。
]]
local function loadSchema(): (Loaded?, string?)
	local candidates = Place.schemaModules()
	if #candidates == 0 then
		-- 最初に必ずここで詰まるので、次に何をすればよいかまで書く
		return nil,
			"No rosheet schema found. Put a ModuleScript named RosheetSchema that returns rosheet.defineSchema(...) into ServerStorage"
	end

	-- ランタイムを上げた直後は、古い defineSchema が評価され続けて宣言が黙って落ちる
	-- （Place.staleRuntime の説明）。落ちる宣言には writablePlaces も含まれる —— 本番 place を
	-- 守るはずの宣言が消えたまま書けてしまうので、ズレている間は読み取り専用にする（Apply も
	-- スキーマの publish も止まる）。読むだけなら害が無いので、表と履歴はそのまま出す
	local stale = Place.staleRuntime()

	local problem: string? = nil
	for _, module in candidates do
		-- そのまま require すると、Rojo が Source を書き換えても古い戻り値が返り続ける
		-- （require はインスタンス単位で恒久的にキャッシュする）。写しを読んで迂回する
		local required, definition = Place.requireFresh(module)
		if not required then
			problem = `{module:GetFullName()}: require failed: {tostring(definition)}`
			continue
		end

		local normalized, schema = pcall(Schema.normalize, definition)
		if not normalized then
			problem = `{module:GetFullName()}: {tostring(schema)}`
			continue
		end

		local named, failure = pcall(Session.checkSheetNames, schema)
		if not named then
			problem = `{module:GetFullName()}: {tostring(failure)}`
			continue
		end

		local declared = definition :: { datastore: any, scope: any, writablePlaces: any }
		local datastore = if type(declared.datastore) == "string" and declared.datastore ~= ""
			then declared.datastore
			else DEFAULT_DATASTORE
		local scope = if type(declared.scope) == "string" and declared.scope ~= "" then declared.scope else nil
		-- ズレの方を先に出す。古い評価結果では writablePlaces 自体が消えているかもしれず、
		-- 「この place は書ける」も当てにならない
		local readOnly = if stale ~= nil then stale else readOnlyReason(declared)
		return { schema = schema, datastore = datastore, scope = scope, readOnly = readOnly }, nil
	end

	-- 候補はあったのに、どれも読めなかった（rosheet の runtime モジュールのように、
	-- defineSchema という語を含むだけのモジュールもここに来る）。最後の理由に一手を添える。
	-- ランタイムがズレているなら、まず疑うのはそちら —— 新しいスキーマを古いランタイムで
	-- 評価すると、宣言が落ちるだけでなく require ごと落ちることがある
	if stale ~= nil then
		return nil, `{tostring(problem)}. {stale :: string}`
	end
	return nil, `{tostring(problem)}. rosheet expects a ModuleScript that returns rosheet.defineSchema(...)`
end

--[[ 読み直した宣言が前と同じか。同じなら表もツールバーも触らない ]]
local function sameLoaded(next: Loaded, previous: Loaded?): boolean
	if previous == nil then
		return false
	end
	local before = previous :: Loaded
	return next.datastore == before.datastore
		and next.scope == before.scope
		and next.readOnly == before.readOnly
		and Schema.equal(next.schema, before.schema)
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
		backendKey = nil :: string?,
		schema = nil :: Schema.Normalized?,
		state = nil :: Session.State?,
		draft = nil :: { [string]: any }?,
		-- まだ Apply していない、足したばかりの行（シート名 → 行テーブルの集合）。行の位置では
		-- なく実体で覚える。途中の行を消すと位置はずれるが、行そのものは同じ
		newRows = {} :: { [string]: { [any]: boolean } },
		-- 履歴から下書きへ読み込んだ commit。Apply したときに「何へ戻したのか」を残すため
		restored = nil :: { seq: number, dataset: { [string]: any } }?,
		-- この place から書けないときの理由（スキーマの writablePlaces）。編集も履歴も読めるが
		-- Apply だけ押せなくなる
		readOnly = nil :: string?,
		-- スキーマが今は読めない理由（消された、名前が変わった、Rojo の同期から外れた、
		-- require が落ちる）。読めているあいだは nil
		schemaProblem = nil :: string?,
		-- banner に今出している表示の通し番号。8 秒後の自動消灯が、そのあいだに差し替わった
		-- 表示を消さないようにするため
		bannerSeq = 0,
		-- 最後に読み切れた宣言。place が変わったとき「中身も変わったのか」を見るのに使う
		loaded = nil :: Loaded?,
		-- 保存先へ実際に置けたスキーマ。同じものを毎回書き直さないため
		publishedSchema = nil :: Schema.Normalized?,
		-- head が pin より何 commit 先か。出荷値は tag から焼くので、Apply しても出荷は動かない
		tags = { entries = {} },
		activeSheet = 1,
		showHistory = false,
		log = { entries = {} },
		grid = nil :: any,
		buttons = {} :: { TextButton },
		restoreButtons = {} :: { TextButton },
		watcher = nil :: Place.Watcher?,
		busy = false,
		busyLabel = nil :: string?,
	}, App)

	self:_buildChrome()
	-- Rojo が同期し直したら、スキーマと rocas の一覧を追い直す。プラグインを入れ直さないための経路
	self.watcher = Place.watch(function(reasons: Place.Changes)
		self:_placeChanged(reasons)
	end)
	self:_refreshPlace()
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

	-- シートのタブは一番下。スプレッドシートと同じ位置に置く
	local tabs = Instance.new("ScrollingFrame")
	tabs.Name = "Tabs"
	tabs.BackgroundColor3 = colors.surface
	tabs.BorderSizePixel = 0
	tabs.AnchorPoint = Vector2.new(0, 1)
	tabs.Position = UDim2.fromScale(0, 1)
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
	content.Position = UDim2.fromOffset(0, Theme.TOOLBAR_HEIGHT)
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
	-- タブの上に出す。タブを覆うとシートを切り替えられなくなる
	self.banner.Position = UDim2.new(0, 0, 1, -Theme.TAB_HEIGHT)
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

--[[
	書き込みを止めている理由。止まっているあいだは続く状態なので、banner にも出したままにする。

	スキーマが読めないほうを先に出す。読めないあいだは `writablePlaces` を含む宣言そのものが
	読めていないので、最後に読めた「この place は書ける／書けない」は、今もそうだとは言えない。
	今いちばん当てになるのは「スキーマが読めない」のほう。
]]
function App._blocked(self: App): string?
	if self.schemaProblem ~= nil then
		return self.schemaProblem
	end
	return self.readOnly
end

--[[
	一時的なエラー（Apply に失敗した、など）は banner に出して 8 秒で消す。一度きりの出来事
	なので、出したままにすると表を覆い続ける。

	書き込みを止めている理由（`_blocked`）だけは消さない。状態のほうは続くので、説明だけ先に
	消えると、あとから見た人にはステータス行の `· read-only` しか残らない —— なぜ書けないのか、
	何をすれば直るのか（版ズレなら「Studio を再起動しろ」）が画面から消える。
]]
function App._say(self: App, message: string, isError: boolean)
	if not isError then
		self.status.Text = message
		return
	end

	self.banner.Text = ` {message}`
	self.banner.Visible = true

	-- 予約済みの自動消灯を無効にする。無効にしないと、前のエラーの残り時間でこの表示が消える
	self.bannerSeq += 1

	local blocked = self:_blocked()
	if blocked ~= nil and message == blocked then
		return
	end

	local seq = self.bannerSeq
	task.delay(8, function()
		-- そのあいだに別の表示へ差し替わっていたら、この予約はもう自分のものではない
		if self.bannerSeq ~= seq then
			return
		end
		self:_refreshBanner()
	end)
end

--[[
	banner を今の状態に合わせる。書き込みが止まっているなら理由を出したままにし、そうで
	なければ閉じる。一時的なエラーがその上に重なったときも、消えたあとここへ戻る。
]]
function App._refreshBanner(self: App)
	if self.banner == nil then
		return
	end
	-- 予約済みの自動消灯を無効にする。理由へ戻した表示を、あとから消されないように
	self.bannerSeq += 1
	local blocked = self:_blocked()
	if blocked ~= nil then
		self.banner.Text = ` {blocked :: string}`
		self.banner.Visible = true
	else
		self.banner.Visible = false
	end
end

-- ============================================================ 読み込み

--[[
	rocas の一覧を place から取り直し、次に見張るモジュールを差し替える。

	一覧はプラグインに焼かない。rocas の manifest（`rocas manifest` が書き、Rojo が同期する
	もの）をそのまま読むので、アセットを足してもプラグインは入れ直さなくてよい。
]]
function App._refreshPlace(self: App)
	local assets, manifest = Place.assets()
	self.grid:setAssets(assets)

	-- スキーマとアセットを分けて渡す。混ぜると、rocas の manifest が変わっただけで
	-- 「スキーマが変わった」になり、表を作り直してスクロール位置と選択行が飛ぶ
	local watched: Place.Watched = { schema = {}, assets = {} }
	if manifest ~= nil then
		table.insert(watched.assets, manifest :: ModuleScript)
	end
	for _, module in Place.schemaModules() do
		table.insert(watched.schema, module)
	end

	local watcher = self.watcher
	if watcher ~= nil then
		(watcher :: Place.Watcher):track(watched)
	end
end

--[[
	Rojo が同期し直した。

	Rojo は同期し直すとき、インスタンスを作り直さずに Source だけ書き換える。Watcher はそれを
	拾えているので、あとはここで「スキーマが変わったのか」を判断して読み直す。

	読み直すのはスキーマが変わったときだけ。`rbxtsc` のビルド 1 回で `out/` の木ごと入れ替わる
	プロジェクトがあるので、木の増減で読み直すと、スキーマが 1 文字も変わっていないのに
	ビルドのたびに DataStore へ書くことになる（Place.Changes で理由を分けているのはそのため）。

	さらに、読み直しても中身が同じなら何もしない。作り直すと表のスクロール位置と選択行が飛ぶ。

	**下書きがあるときは黙って読み直さない。** Apply していない編集は履歴にも無いので戻せない。
	変わったことだけ出して、捨てるか残すかは編集している側に決めさせる。
]]
function App._placeChanged(self: App, reasons: Place.Changes)
	if self.root.Parent == nil then
		return
	end
	-- 見張り対象と rocas の一覧はどの変化でも張り直す。飛ばすと次の変化を拾えなくなる
	self:_refreshPlace()

	if self.schema == nil then
		-- まだ読めていない。スキーマが後から同期されてくる経路なので、どの変化でも試す
		self:reload()
		return
	end
	-- 読めなくなったあとは、どの変化でも試す。名前を変えて置き直されると変化の理由は
	-- "schema" にならないので、理由では絞れない
	if self.schemaProblem == nil and not reasons.schema then
		return
	end
	-- Apply / Restore の最中は触らない。終わったところで reload が走る
	if self.busy or self.state == nil then
		return
	end

	local loaded = loadSchema()
	if loaded == nil then
		-- スキーマが place から消えた（消した、名前を変えた、Rojo の同期から外れた）。黙って
		-- 前の宣言のまま編集させ続けると、Apply で何に書くつもりだったのかが分からなくなる。
		-- 下書きは捨てない —— reload の読めなかった側は下書きにも表にも触らない
		self:reload()
		return
	end

	if sameLoaded(loaded :: Loaded, self.loaded) then
		if self.schemaProblem == nil then
			return
		end
		-- 読めなくなる前と同じ宣言が戻ってきた（消して undo した、Rojo が置き直した）。
		-- 下書きも表もそのまま使えるので、止めていた書き込みだけ戻す。ここで読み直すと、
		-- 消えているあいだ残していた下書きを、戻ってきた拍子に捨てることになる
		self.schemaProblem = nil
		self:_refreshGrid()
		self:_refreshToolbar()
		self:_refreshBanner()
		return
	end

	if #self:_changedSheets() > 0 then
		self:_say("The schema changed. Apply or Discard, then press Reload", true)
		return
	end
	self:reload()
end

function App.reload(self: App)
	local loaded, problem = loadSchema()
	if loaded == nil then
		-- 読めないあいだは書かせない。`writablePlaces` を含む宣言そのものが読めていないので、
		-- 最後に読めた「この place は書ける」は、今もそうだとは言えない。次に Rojo が同期
		-- したら _placeChanged がもう一度試す
		self.schemaProblem = problem
		-- 一度読めているなら、表と履歴はそのまま出しておく（読むだけなら害が無い）。
		-- 読み取り専用へ落ちたことを、表とツールバーにも通す
		if self.schema ~= nil and self.state ~= nil then
			self:_refreshGrid()
			self:_refreshToolbar()
		end
		self:_refreshBanner()
		return
	end

	local schema = loaded.schema
	self.schema = schema
	self.schemaProblem = nil
	self.readOnly = loaded.readOnly
	-- 理由はここで出す。この先の途中で失敗しても（publish できない、読めない）、その一時的な
	-- エラーが消えたあとに理由へ戻る。書けるようになったなら、ここで閉じる
	self:_refreshBanner()
	self:_refreshPlace()

	-- スキーマが宣言する DataStore が変わったら、それまでの backend は捨てる
	local key = `{loaded.datastore}/{loaded.scope}`
	if self.backend == nil or self.backendKey ~= key then
		local dataStore = Store.dataStore(loaded.datastore, loaded.scope)
		local usable, why = Store.probe(dataStore)
		if usable then
			self.backend = dataStore
		else
			-- 公開していない place や API を入れていない環境でも触れるようにしておく。
			-- ここで諦めると「何も出ないプラグイン」になり、原因も分からない
			self.backend = Store.pluginSettings(self.plugin, loaded.datastore)
			self:_say(`Falling back to local storage: {why}`, true)
		end
		self.backendKey = key
	end
	local backend = self.backend :: Store.Backend

	-- publish は書き込みなので、必要なときだけにする:
	--
	-- - 読み取り専用の place ではしない。本番 place を開いただけでチームのスキーマが
	--   置き換わるのを避ける
	-- - 既に置いたものと同じ正規形ならしない。読み直しは place が変わるたびに走るので、
	--   ここを無条件にすると Rojo の同期 1 回ごとに DataStore へ 1 write する
	--
	-- 「置いた」で覚えるのが要点。読んだ内容で覚えると、publish が失敗した回のスキーマを
	-- 置いたことにしてしまい、次からは同じだからと書き直さなくなる
	if self:_blocked() == nil and not Schema.equal(self.publishedSchema, schema) then
		local published, failure = Session.publishSchema(backend, schema)
		if not published then
			self:_say(`Could not publish the schema: {tostring(failure)}`, true)
			return
		end
		self.publishedSchema = schema
	end

	local ok, state = Session.readCurrent(backend, schema)
	if not ok then
		self:_say(tostring(state), true)
		return
	end

	self.state = state
	self.draft = Rows.cloneDataset(schema, (state :: Session.State).dataset)
	self.newRows = {}
	self.restored = nil
	self.activeSheet = math.min(self.activeSheet, #schema.sheets)

	local logged, log = Session.readLog(backend)
	self.log = if logged then log else { entries = {} }

	local tagged, tags = Session.readTags(backend)
	self.tags = if tagged then tags else { entries = {} }

	-- 最後まで通ったときだけ控える。途中で落ちた回を「読めた」にすると、次に place が
	-- 変わっても「同じだから何もしない」になり、直すまで追いつけなくなる
	self.loaded = loaded

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

	-- 読み取り専用の place では表からも編集させない。Apply だけ止めても、保存できない下書きを
	-- いくらでも作れてしまい、気づくのは Apply に手を伸ばしたとき
	self.grid:setReadOnly(self:_blocked() ~= nil)

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

		-- キー列が readonly でも、この行の key だけは Grid に書かせる。addRow が入れる
		-- `new1` のような仮の値は、ここが false を返すと二度と直せない
		isNewRow = function(rowIndex: number): boolean
			if sheet.kind ~= "table" then
				return false
			end
			local added = self.newRows[sheet.name]
			if added == nil then
				return false
			end
			local row = (draft[sheet.name] :: { any })[rowIndex]
			return row ~= nil and added[row] == true
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

	local writable = self:_blocked() == nil
	self.applyButton.Text = if self.busy
		then "Applying..."
		elseif not writable then "Read-only"
		elseif dirty then `Apply ({#changed})`
		else "Apply"
	setEnabled(self.applyButton, idle and dirty and writable)
	-- Discard は常に出す。変更があるときだけ現れると、押せる場所が動いて狙いにくい
	setEnabled(self.discardButton, idle and dirty)

	-- 行の増減も書き込み。読み取り専用の place では入口ごと閉じる
	local canAddRows = sheet.kind == "table" and sheet.rows == "open" and writable
	setEnabled(self.addButton, idle and canAddRows)
	setEnabled(self.deleteButton, idle and canAddRows and self.grid:selectedRow() ~= nil)
	setEnabled(self.historyButton, idle)
	setEnabled(self.reloadButton, idle)
	self.historyButton.Text = if self.showHistory then "History \u{25B8}" else "History"

	-- 履歴の Restore も同じ。Apply / Restore の最中にもう 1 つ押せると、どちらの結果を
	-- 見ているのか分からなくなる
	for _, restore in self.restoreButtons do
		setEnabled(restore, idle)
	end

	local backend = self.backend :: Store.Backend
	local where = if Live.isPlaying() then " \u{00B7} playing" else ""
	local locked = if writable then "" else " \u{00B7} read-only"
	self.status.Text = if self.busyLabel ~= nil
		then self.busyLabel :: string
		else `#{state.head} \u{00B7} {backend.label}{self:_pinDistance()}{locked}{where}`
end

--[[
	出荷値は tag から焼くので、Apply しただけでは出荷は動かない。編集する側が「自分の変更は
	まだ出荷されていない」と分かるように、head が一番新しい tag より何 commit 先かを出す。

	止めるためのものではない。tag が無ければ何も出さない。
]]
function App._pinDistance(self: App): string
	local latest: { name: string, seq: number }? = nil
	for _, entry in (self.tags :: any).entries do
		if type(entry) == "table" and type(entry.seq) == "number" and (latest == nil or entry.seq > (latest :: any).seq) then
			latest = entry
		end
	end
	if latest == nil then
		return ""
	end

	local ahead = (self.state :: Session.State).head - (latest :: any).seq
	if ahead <= 0 then
		return ` \u{00B7} {(latest :: any).name}`
	end
	return ` \u{00B7} {ahead} ahead of {(latest :: any).name}`
end

--[[
	Apply / Restore の最中は表もツールバーも触らせない。触れると送っている内容と画面が食い違う。

	`label` を渡すと、終わるまでステータス行に出したままにする。DataStore の読み書きは数秒
	かかることがあり、何も出ないと「もう終わったのか、まだなのか」が分からない。
]]
function App._setBusy(self: App, busy: boolean, label: string?)
	self.busy = busy
	self.busyLabel = if busy then label else nil
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
		self.newRows = {}
		self.restored = nil
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
	-- ボタンは落としてあるが、ここでも見る。読み取り専用は「押せない」ではなく「しない」
	if self.busy or self:_blocked() ~= nil or sheet.kind ~= "table" or sheet.rows ~= "open" then
		return
	end

	local rows = (self.draft :: { [string]: any })[sheet.name] :: { any }
	local row = Rows.blankRow(sheet)
	if sheet.key ~= nil then
		-- key は空を許さないので、重複しない仮の値を入れる。キー列が readonly でも、この行に
		-- 限っては表から書き換えられる（Grid の isNewRow）
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

	local added = self.newRows[sheet.name]
	if added == nil then
		added = {}
		self.newRows[sheet.name] = added
	end
	added[row] = true

	self.grid:setValue(rows)
	self:_refreshToolbar()
end

function App.deleteRow(self: App)
	local sheet = self:_sheet()
	local index = self.grid:selectedRow()
	if self.busy or self:_blocked() ~= nil or sheet.kind ~= "table" or sheet.rows ~= "open" or index == nil then
		return
	end

	local rows = (self.draft :: { [string]: any })[sheet.name] :: { any }
	if rows[index] == nil then
		return
	end
	local removed = table.remove(rows, index)

	local added = self.newRows[sheet.name]
	if added ~= nil and removed ~= nil then
		added[removed] = nil
	end

	self.grid:setValue(rows)
	self:_refreshToolbar()
end

-- ============================================================ Apply と履歴

function App.apply(self: App)
	if self.busy then
		return
	end
	-- ボタンは無効にしてあるが、書き込みを止めるのはここ 1 箇所にしておく
	local blocked = self:_blocked()
	if blocked ~= nil then
		self:_say(blocked :: string, true)
		return
	end
	local changed = self:_changedSheets()
	if #changed == 0 then
		return
	end

	self:_setBusy(true, "Applying...")

	task.spawn(function()
		local backend = self.backend :: Store.Backend
		local schema = self.schema :: Schema.Normalized

		-- 何を変えたのかを commit に残す。Restore から来た下書きは、戻した時点との差を書く
		-- （head との差にすると巻き戻しそのものが変更として並び、戻したあとに何を足したのかが読めない）
		local restored = self.restored
		local baseline = if restored == nil
			then (self.state :: Session.State).dataset
			else (restored :: any).dataset
		local summary = Rows.summarize(schema, baseline, self.draft :: any)

		local note = summary
		local revertOf: number? = nil
		if restored ~= nil then
			revertOf = (restored :: any).seq
			note = if summary == "" then `revert of #{revertOf}` else `revert of #{revertOf} · {summary}`
		end

		local ok, result = Session.apply(
			backend,
			schema,
			self.state :: Session.State,
			self.draft :: any,
			{ at = DateTime.now():ToIsoDate(), by = author, note = note, revertOf = revertOf }
		)

		if not ok then
			self:_setBusy(false)
			self:_say(`Apply failed: {tostring(result)}`, true)
			return
		end

		local commit = result :: Session.Commit
		Live.publish(schema, self.draft :: any, commit.seq)
		-- 読み直しまで busy のまま。ここで先に解除すると、画面がまだ古いうちに押せてしまい、
		-- 直後に表が入れ替わる
		self:reload()
		self:_setBusy(false)
		self:_say(`Applied #{commit.seq}: {table.concat(changed, ", ")}`, false)
	end)
end

function App._refreshHistory(self: App)
	self.history.Visible = self.showHistory
	-- 作り直すので前のボタンは忘れる。消したボタンをグレーアウトしに行かないように
	self.restoreButtons = {}
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
		card.Size = UDim2.new(1, -8, 0, 64)
		card.LayoutOrder = order
		card.Parent = self.history

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(6, 2)
		title.Size = UDim2.new(1, -(RESTORE_BUTTON_WIDTH + 18), 0, 18)
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
		detail.Size = UDim2.new(1, -(RESTORE_BUTTON_WIDTH + 18), 0, 42)
		detail.Font = Theme.FONT
		detail.TextSize = Theme.TEXT_SIZE - 2
		detail.TextColor3 = colors.dimText
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.TextYAlignment = Enum.TextYAlignment.Top
		detail.TextWrapped = true
		local who = if entry.by ~= nil and entry.by ~= "" then entry.by else "?"
		-- note に何を変えたのかが入る。note を書いていなかった頃の履歴はシート名だけ出す
		local what = if entry.note ~= nil and entry.note ~= "" then entry.note else table.concat(entry.changed, ", ")
		detail.Text = `{entry.at or "?"}  ·  {who}\n{what}`
		detail.Parent = card

		local restore = button(card, "Restore", RESTORE_BUTTON_WIDTH)
		restore.AnchorPoint = Vector2.new(1, 0.5)
		restore.Position = UDim2.new(1, -6, 0.5, 0)
		restore.Activated:Connect(function()
			self:restore(entry.seq, restore)
		end)
		table.insert(self.restoreButtons, restore)

		height += 66
	end

	self.history.CanvasSize = UDim2.fromOffset(0, height)
end

--[[
	履歴の Restore。保存先には触らず、その commit の値を下書きへ読み込むだけ。

	読み込んだ値は他の編集と同じ黄色い下書きとして出るので、Apply を押せば新しい commit として
	積まれ、Discard を押せば戻す前の状態に返る。押した瞬間に書かないぶん、戻した中身を見てから
	決められる。
]]
function App.restore(self: App, seq: number, pressed: TextButton?)
	if self.busy then
		return
	end

	local changed = self:_changedSheets()
	if #changed == 0 then
		self:_readInto(seq, pressed)
		return
	end

	-- 下書きを丸ごと置き換えるので、Apply していない編集は消える。Discard と同じ確認を挟む
	self:_confirm(
		`Replace unapplied edits in {table.concat(changed, ", ")} with the values of #{seq}?`,
		"Restore",
		function()
			self:_readInto(seq, pressed)
		end
	)
end

function App._readInto(self: App, seq: number, pressed: TextButton?)
	self:_setBusy(true, `Restoring #{seq}...`)
	if pressed ~= nil then
		(pressed :: TextButton).Text = "Restoring..."
	end

	-- 読んだあとに履歴を作り直さないので、押したボタンの文言は自分で戻す
	local function done()
		if pressed ~= nil then
			(pressed :: TextButton).Text = "Restore"
		end
		self:_setBusy(false)
	end

	task.spawn(function()
		local backend = self.backend :: Store.Backend
		local schema = self.schema :: Schema.Normalized

		local found, target = Session.readCommit(backend, seq)
		if not found or target == nil then
			done()
			self:_say(`Could not read commit #{seq}`, true)
			return
		end

		local read, dataset = Session.readDataset(backend, schema, target)
		if not read then
			done()
			self:_say(`Could not read the values of #{seq}: {tostring(dataset)}`, true)
			return
		end

		self.draft = dataset
		-- 読み込んだ行はどれも過去の commit に載っていた行なので、新規行は 1 つも無い
		self.newRows = {}
		self:_refreshGrid()

		-- 今の値と同じなら戻すものが無い。控えを持つと、このあとの編集まで「#N への巻き戻し」に
		-- されてしまう
		local changed = self:_changedSheets()
		if #changed > 0 then
			-- Apply のときに「戻した時点から何を足したのか」を出すので、読み込んだ値も控えておく
			self.restored = { seq = seq, dataset = Rows.cloneDataset(schema, dataset) }
		end

		done()
		self:_say(
			if #changed == 0
				then `#{seq} is the same as the current values. Nothing to restore`
				else `Restored #{seq} into the draft. Apply to save it, Discard to drop it`,
			false
		)
	end)
end

function App.destroy(self: App)
	local watcher = self.watcher
	if watcher ~= nil then
		(watcher :: Place.Watcher):destroy()
		self.watcher = nil
	end
	if self.grid ~= nil then
		self.grid:destroy()
	end
	self.root:Destroy()
end

return App
