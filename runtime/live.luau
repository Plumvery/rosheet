--!strict
-- 同梱値と、Studio の Apply で届いた値を繋ぐ。
--
--     local Guns = rosheet.bind(require(ReplicatedStorage.Config.guns), "guns")
--     print(Guns.get("AK47").damage)
--
-- 本番では ReplicatedStorage に RosheetLive が無いので、`bind` は同梱値をそのまま返す。
-- Studio のプレイテスト中だけ、プラグインが置いた値に切り替わる。
--
-- 戻り値は __index で毎回引き直すテーブル。Apply のたびに新しいテーブルを返す形にすると、
-- ゲーム側が最初に受け取った参照を持ち続けている限り値が入れ替わらない。

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "RosheetLive"
local SCHEMA_NAME = "__schema"
local VERSION_NAME = "__version"

local Live = {}

type Cached = { version: number, view: { [string]: any } }

local cache: { [string]: Cached } = {}

local function folder(): Folder?
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	return if existing ~= nil and existing:IsA("Folder") then existing else nil
end

local function readString(parent: Folder, name: string): string?
	local value = parent:FindFirstChild(name)
	return if value ~= nil and value:IsA("StringValue") then value.Value else nil
end

local function currentVersion(parent: Folder): number?
	local value = parent:FindFirstChild(VERSION_NAME)
	return if value ~= nil and value:IsA("IntValue") then value.Value else nil
end

local function keyColumn(parent: Folder, sheetName: string): string?
	local raw = readString(parent, SCHEMA_NAME)
	if raw == nil then
		return nil
	end

	local ok, schema = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok then
		return nil
	end

	for _, sheet in schema.sheets do
		if sheet.name == sheetName then
			return sheet.key
		end
	end
	return nil
end

--[[ 生成物と同じ形（rows / by<Key> / get）に組み直す ]]
local function buildView(sheetName: string, decoded: any, key: string?): { [string]: any }
	if typeof(decoded) ~= "table" then
		return {}
	end

	-- scalars は配列ではなく 1 枚のテーブル。そのまま返せば生成物と同じ形になる
	if #decoded == 0 and next(decoded) ~= nil then
		return decoded
	end

	local view: { [string]: any } = { rows = decoded }
	if key ~= nil then
		local index: { [string]: any } = {}
		for _, row in decoded do
			index[row[key]] = row
		end
		view[`by{string.upper(string.sub(key, 1, 1))}{string.sub(key, 2)}`] = index
		view.get = function(id: string)
			return index[id]
		end
	end
	return view
end

local function liveView(sheetName: string): { [string]: any }?
	local parent = folder()
	if parent == nil then
		return nil
	end

	local version = currentVersion(parent)
	if version == nil then
		return nil
	end

	local cached = cache[sheetName]
	if cached ~= nil and cached.version == version then
		return cached.view
	end

	local raw = readString(parent, sheetName)
	if raw == nil then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok then
		return nil
	end

	local view = buildView(sheetName, decoded, keyColumn(parent, sheetName))
	cache[sheetName] = { version = version, view = view }
	return view
end

--[[
	同梱値を、Studio では Apply 済みの値に差し替えて返す。型は同梱値のまま。
]]
function Live.bind<T>(baked: T, sheetName: string): T
	if not RunService:IsStudio() then
		return baked
	end

	return (
		setmetatable({}, {
			__index = function(_, key: string): any
				local live = liveView(sheetName)
				if live ~= nil and live[key] ~= nil then
					return live[key]
				end
				return (baked :: any)[key]
			end,
			__newindex = function()
				error("rosheet: the table returned by bind is read-only", 2)
			end,
		}) :: any
	) :: T
end

--[[ Apply のたびに走らせたい処理があるときに使う。戻り値で購読を切る ]]
function Live.onApplied(callback: (seq: number) -> ()): () -> ()
	local parent = folder()
	if parent == nil then
		return function() end
	end

	local value = parent:FindFirstChild(VERSION_NAME)
	if value == nil or not value:IsA("IntValue") then
		return function() end
	end

	local connection = value.Changed:Connect(function(seq)
		callback(seq)
	end)
	return function()
		connection:Disconnect()
	end
end

Live.FOLDER_NAME = FOLDER_NAME

return Live
