--!strict
-- place の中から、rosheet が要るものを見つける。プラグインには何も焼かない。
--
-- 焼くと「アセットを足した」「スキーマの置き場を変えた」のたびにプラグインを入れ直すことに
-- なる。Rojo が同期したモジュールを読み、木の変化を追えば、入れ直しは要らない。rocas の
-- プラグインも同じ形（あちらも ReplicatedStorage の manifest を読み、DescendantAdded で
-- 追い直している）。
--
-- 走査するのは ServerStorage と ReplicatedStorage だけ。Workspace まで見に行くと、大きい
-- place では毎回数万インスタンスを舐めることになる。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")

local Place = {}

export type Asset = { path: string, assetId: string, kind: string }

-- スキーマは require しないと形が分からない（defineSchema を評価するのはモジュール自身）。
-- 名前かソースで絞ってから require する。place の ModuleScript を手当たり次第に require
-- すると、rosheet と関係ないモジュールの副作用まで走らせてしまう
local SCHEMA_NAME = "RosheetSchema"
local SCHEMA_MARKER = "defineSchema"

-- rocas の manifest は「JSON をマーカーで挟んだ長い文字列」として書かれている。require せず
-- に Source から取り出す。rocas 側もプラグインでこの形で読んでいる
local ROCAS_MARKER = "ROCAS_MANIFEST_JSON_BEGIN"
local ROCAS_SCHEME = "rocas://"
local IMAGE_EXTENSIONS: { [string]: boolean } = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }

-- require のキャッシュを避けるために作る一時的な写しの目印（Place.requireFresh）。写しは木に
-- 足すので、走査からも見張りからも外す。外さないと、写しを足したこと自体が「place が変わった」
-- になり、読み直しへ戻ってぐるぐる回る
local CLONE_MARK = "__rosheetReloadCopy"

-- Rojo の 1 回の同期は数百のイベントとして届く。まとめて 1 回に潰す
local DEBOUNCE = 0.25

local function roots(): { Instance }
	return { ServerStorage, ReplicatedStorage }
end

local function isReloadCopy(instance: Instance): boolean
	return string.find(instance.Name, CLONE_MARK, 1, true) ~= nil
end

--[[ Source はプラグインからしか読めない。読めない場面もあるので、落ちないようにしておく ]]
local function readSource(instance: Instance): string?
	local ok, source = pcall(function()
		return (instance :: any).Source
	end)
	return if ok and type(source) == "string" then source else nil
end

local function moduleScripts(): { ModuleScript }
	local found: { ModuleScript } = {}
	for _, root in roots() do
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("ModuleScript") and not isReloadCopy(descendant) then
				table.insert(found, descendant)
			end
		end
	end
	return found
end

--[[
	モジュールを、require のキャッシュを避けて読む。

	Roblox の require は戻り値をインスタンス単位で恒久的にキャッシュする。Rojo は同期のたびに
	同じインスタンスの Source を書き換えるので、そのまま require するとスキーマを直しても古い
	戻り値が返り続け、Studio を開き直すまで直らない（Reload を押しても同じ require を通る）。
	読むたびに写しを作れば、キャッシュに当たらない。

	写しは元と同じ親に置く。スキーマモジュールは `require(script.Parent.rosheet.schema)` の
	ように相対で書けるので、親が違うと解決できない。
]]
function Place.requireFresh(module: ModuleScript): (boolean, any)
	local copy = module:Clone()
	copy.Name = `{module.Name}{CLONE_MARK}`
	copy.Parent = module.Parent

	local ok, result = pcall(require, copy)
	copy:Destroy()
	return ok, result
end

--[[
	スキーマになりうる ModuleScript を、確からしい順に返す。

	名前が一致するものが先。Rojo が同期する木では `RosheetSchema.luau` がそのまま名前になる。
	roblox-ts でコンパイルした場合も、呼び出しの `defineSchema` は出力に残る。
]]
function Place.schemaModules(): { ModuleScript }
	local named: { ModuleScript } = {}
	local guessed: { ModuleScript } = {}

	for _, module in moduleScripts() do
		if module.Name == SCHEMA_NAME then
			table.insert(named, module)
		else
			local source = readSource(module)
			if source ~= nil and string.find(source, SCHEMA_MARKER, 1, true) ~= nil then
				table.insert(guessed, module)
			end
		end
	end

	for _, module in guessed do
		table.insert(named, module)
	end
	return named
end

-- 長い文字列リテラルの中身を取り出す（開き括弧のイコールの数に合わせて閉じを探す）
local function longString(source: string, from: number): string?
	local openStart, openEnd = string.find(source, "%[=*%[", from)
	if openStart == nil or openEnd == nil then
		return nil
	end

	local equals = string.match(string.sub(source, openStart, openEnd), "^%[(=*)%[$") or ""
	local closeAt = string.find(source, `]{equals}]`, openEnd + 1, true)
	if closeAt == nil then
		return nil
	end
	return string.sub(source, openEnd + 1, closeAt - 1)
end

local function manifestFrom(module: ModuleScript): { assets: { any } }?
	local source = readSource(module)
	if source == nil then
		return nil
	end

	local markerAt = string.find(source, ROCAS_MARKER, 1, true)
	if markerAt == nil then
		return nil
	end

	local json = longString(source, markerAt)
	if json == nil then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(json :: string)
	end)
	if not ok or type(decoded) ~= "table" or decoded.generatedBy ~= "rocas" or type(decoded.assets) ~= "table" then
		return nil
	end
	return decoded
end

local function kindOf(path: string): string
	local extension = string.lower(string.match(path, "%.([%w]+)$") or "")
	return if IMAGE_EXTENSIONS[extension] then "image" else "other"
end

--[[
	rocas の manifest から `rocas://` の一覧を作る。rocas を使っていない place では空。

	manifest の `sourcePath` は cwd 相対のパス（`assets/images/maps/SciFi.png`）で、rosheet の
	`rocas://` が指すパスとそのまま一致する。group とディレクトリの対応を別に持たなくてよい。

	返り値の 2 つ目は読んだモジュール。Source を見張るのに使う（Rojo は同期し直すとき、
	インスタンスを作り直さずに Source だけ書き換えることがある）。
]]
function Place.assets(): ({ Asset }, ModuleScript?)
	for _, module in moduleScripts() do
		local manifest = manifestFrom(module)
		if manifest == nil then
			continue
		end

		local entries: { Asset } = {}
		for _, asset in manifest.assets do
			local sourcePath = if type(asset) == "table" then asset.sourcePath else nil
			local assetId = if type(asset) == "table" then asset.assetId else nil
			-- `rocas manifest --local` の manifest には assetId が無い。出しても Studio では
			-- 引けないので落とす
			if type(sourcePath) == "string" and type(assetId) == "string" and assetId ~= "" then
				table.insert(entries, { path = ROCAS_SCHEME .. sourcePath, assetId = assetId, kind = kindOf(sourcePath) })
			end
		end

		table.sort(entries, function(a: Asset, b: Asset): boolean
			return a.path < b.path
		end)
		return entries, module
	end

	return {}, nil
end

-- ============================================================ 変化を追う

local Watcher = {}
Watcher.__index = Watcher

--[[
	何が変わったのか。引き金を 1 本にすると区別が付かず、呼び手は「毎回全部やり直す」しか
	選べない。roblox-ts のプロジェクトでは `rbxtsc` のビルド 1 回で `out/` の木ごと入れ替わり、
	数百の ModuleScript が足される —— それを「スキーマが変わった」と同じ扱いにすると、
	ビルドのたびにスキーマを DataStore へ書き直すことになる。

	- `schema` — スキーマの宣言が変わったかもしれない（読み直す価値がある）
	- `place` — それ以外の木の変化（rocas の一覧と見張り対象を張り直すだけでよい）
]]
export type Changes = { schema: boolean, place: boolean }

--[[ 見張るモジュール。理由を分けるので、スキーマとアセットも分けて渡す ]]
export type Watched = { schema: { Instance }, assets: { Instance } }

export type Watcher = typeof(setmetatable(
	{} :: {
		connections: { RBXScriptConnection },
		sources: { RBXScriptConnection },
		onChanged: (Changes) -> (),
		scheduled: boolean,
		pending: Changes,
		alive: boolean,
	},
	Watcher
))

--[[ debounce の窓の中に来た理由は足し合わせる。潰すのはイベントの数だけで、理由は落とさない ]]
function Watcher._schedule(self: Watcher, reason: string)
	if not self.alive then
		return
	end
	if reason == "schema" then
		self.pending.schema = true
	else
		self.pending.place = true
	end

	if self.scheduled then
		return
	end
	self.scheduled = true
	task.delay(DEBOUNCE, function()
		self.scheduled = false
		if not self.alive then
			return
		end
		local reasons = self.pending
		self.pending = { schema = false, place = false }
		self.onChanged(reasons)
	end)
end

--[[
	読んだモジュールの Source を見張り直す。読み直すたびに呼ぶ。

	木の増減だけでは足りない。Rojo は既にある ModuleScript の Source を書き換えることがあり、
	スキーマの更新も rocas の manifest の更新も、まさにその形で届く。
]]
function Watcher.track(self: Watcher, watched: Watched)
	for _, connection in self.sources do
		connection:Disconnect()
	end
	self.sources = {}
	if not self.alive then
		return
	end

	local function listen(instance: Instance, reason: string)
		table.insert(
			self.sources,
			instance:GetPropertyChangedSignal("Source"):Connect(function()
				self:_schedule(reason)
			end)
		)
	end

	for _, instance in watched.schema do
		listen(instance, "schema")
	end
	for _, instance in watched.assets do
		listen(instance, "place")
	end
end

function Watcher.destroy(self: Watcher)
	self.alive = false
	for _, connection in self.connections do
		connection:Disconnect()
	end
	for _, connection in self.sources do
		connection:Disconnect()
	end
	self.connections = {}
	self.sources = {}
end

--[[ place の木が変わったら呼び返す。返り値の :track() に、見張りたいモジュールを渡す ]]
function Place.watch(onChanged: (Changes) -> ()): Watcher
	local self: Watcher = setmetatable({
		connections = {},
		sources = {},
		onChanged = onChanged,
		scheduled = false,
		pending = { schema = false, place = false },
		alive = true,
	}, Watcher) :: any

	-- Rojo が Source を書き換えるのではなく、インスタンスごと差し替える経路がある。そこだけは
	-- 木の増減からスキーマの変化を拾う。判定は名前だけで、Source は読まない ——
	-- rbxtsc のビルド 1 回で数百の ModuleScript が足されるので、そこで Source を舐めると重い
	local function reasonFor(descendant: Instance): string
		return if descendant.Name == SCHEMA_NAME then "schema" else "place"
	end

	for _, root in roots() do
		table.insert(
			self.connections,
			root.DescendantAdded:Connect(function(descendant: Instance)
				if descendant:IsA("ModuleScript") and not isReloadCopy(descendant) then
					self:_schedule(reasonFor(descendant))
				end
			end)
		)
		table.insert(
			self.connections,
			root.DescendantRemoving:Connect(function(descendant: Instance)
				if descendant:IsA("ModuleScript") and not isReloadCopy(descendant) then
					self:_schedule(reasonFor(descendant))
				end
			end)
		)
	end

	return self
end

return Place
