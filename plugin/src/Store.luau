--!strict
-- 保存先。DataStore（チームで共有）と plugin の設定（このマシンだけ）の 2 つを同じ形で扱う。
--
-- 出入りする値は必ず JSON 文字列。Luau のテーブルをそのまま DataStore へ置くと、空テーブルが
-- `{}` と `[]` のどちらで読み戻るかが Open Cloud 側で決まってしまい、空の表が壊れる。
-- 符号化をこの境界に固定しておけば、CLI 側（src/opencloud.js）と必ず同じ形になる。

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Store = {}

export type Result = { ok: true, value: string? } | { ok: false, error: string }

export type Backend = {
	kind: string,
	label: string,
	get: (key: string) -> Result,
	set: (key: string, value: string) -> Result,
	-- 競合したときに諦めるために、変換関数が nil を返したら書かない
	update: (key: string, transform: (string?) -> string?) -> Result,
}

local function ok(value: string?): Result
	return { ok = true, value = value }
end

local function err(message: string): Result
	return { ok = false, error = message }
end

--[[
	DataStore。place が universe に紐づいて公開されていて、Studio の
	File > Experience Settings > Security > Enable Studio Access to API Services が要る。
]]
function Store.dataStore(name: string, scope: string?): Backend
	local store = if scope == nil then DataStoreService:GetDataStore(name) else DataStoreService:GetDataStore(name, scope)

	-- 既定の GetAsync は 4 秒キャッシュする。Apply の直後に古い値を読むと履歴がずれるので切る
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false

	return {
		kind = "datastore",
		label = if scope == nil then `DataStore "{name}"` else `DataStore "{name}" ({scope})`,

		get = function(key: string): Result
			local success, value = pcall(function()
				return store:GetAsync(key, options)
			end)
			if not success then
				return err(tostring(value))
			end
			if value == nil then
				return ok(nil)
			end
			if type(value) ~= "string" then
				return err(`{key}: rosheet が置いた値でない（JSON 文字列でない）`)
			end
			return ok(value)
		end,

		set = function(key: string, value: string): Result
			local success, failure = pcall(function()
				store:SetAsync(key, value)
			end)
			return if success then ok(value) else err(tostring(failure))
		end,

		update = function(key: string, transform: (string?) -> string?): Result
			local aborted = false
			local success, value = pcall(function()
				return store:UpdateAsync(key, function(current: string?)
					local next = transform(current)
					if next == nil then
						aborted = true
					end
					return next
				end)
			end)
			if not success then
				return err(tostring(value))
			end
			if aborted then
				return err("競合: 他の誰かが先に書き込んだ")
			end
			return ok(value :: string?)
		end,
	}
end

--[[
	plugin の設定。このマシンのこのユーザーだけに残る。place の公開も API Services も要らないので、
	まだ公開していない place や個人作業の退路として使う。
]]
function Store.pluginSettings(plugin: Plugin, namespace: string): Backend
	local function settingKey(key: string): string
		return `rosheet/{namespace}/{key}`
	end

	return {
		kind = "settings",
		label = "このマシンのプラグイン設定",

		get = function(key: string): Result
			local success, value = pcall(function()
				return plugin:GetSetting(settingKey(key))
			end)
			if not success then
				return err(tostring(value))
			end
			if value == nil then
				return ok(nil)
			end
			return if type(value) == "string" then ok(value) else err(`{key}: 文字列でない値が入っている`)
		end,

		set = function(key: string, value: string): Result
			local success, failure = pcall(function()
				plugin:SetSetting(settingKey(key), value)
			end)
			return if success then ok(value) else err(tostring(failure))
		end,

		update = function(key: string, transform: (string?) -> string?): Result
			local success, value = pcall(function()
				local current = plugin:GetSetting(settingKey(key))
				local next = transform(current)
				if next ~= nil then
					plugin:SetSetting(settingKey(key), next)
				end
				return next
			end)
			if not success then
				return err(tostring(value))
			end
			if value == nil then
				return err("競合: 他の誰かが先に書き込んだ")
			end
			return ok(value :: string)
		end,
	}
end

--[[
	DataStore が使えるか実際に 1 回読んで確かめる。GetDataStore は API が無くても成功するので、
	読むまで分からない。
]]
function Store.probe(backend: Backend): (boolean, string?)
	local result = backend.get("head")
	if result.ok then
		return true, nil
	end

	local message = result.error
	if string.find(message, "StudioAccessToApisNotAllowed", 1, true) ~= nil then
		return false,
			"Studio から API を叩けない。File > Experience Settings > Security の "
				.. '"Enable Studio Access to API Services" を入れて、place を公開しておく'
	end
	return false, message
end

function Store.encode(value: any): string
	return HttpService:JSONEncode(value)
end

function Store.decode(text: string): (boolean, any)
	local success, value = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	return success, value
end

return Store
