--!strict
-- 保存先。DataStore（チームで共有）と plugin の設定（このマシンだけ）の 2 つを同じ形で扱う。
--
-- 呼び手は Luau の値をそのまま渡す。JSON 文字列への符号化はこの中でやる。
-- 保存先へ置くのは必ず JSON 文字列で、Luau のテーブルをそのまま置くことはしない。テーブルを
-- 置くと、Open Cloud がそれをどんな JSON に落とすかに全部が乗る（空のテーブルが配列と辞書の
-- どちらになるか、が典型）。文字列にしておけば、符号化するのは常にここだけになる。
--
-- 符号化をこの境界に閉じ込めると、Session が Roblox の API に触らなくなる。おかげで履歴の
-- 計画（Apply の差分・巻き戻し）を Lune のテストから偽の保存先で回せる。

local Store = {}

export type Result = { ok: true, value: any } | { ok: false, error: string }

export type Backend = {
	kind: string,
	label: string,
	get: (key: string) -> Result,
	set: (key: string, value: any) -> Result,
	-- 競合したときに諦めるために、変換関数が nil を返したら書かない
	update: (key: string, transform: (any) -> any) -> Result,
}

local function ok(value: any): Result
	return { ok = true, value = value }
end

local function err(message: string): Result
	return { ok = false, error = message }
end

local function encode(value: any): string
	return game:GetService("HttpService"):JSONEncode(value)
end

local function decode(key: string, text: string): (boolean, any)
	local success, value = pcall(function()
		return game:GetService("HttpService"):JSONDecode(text)
	end)
	if not success then
		return false, `{key}: not readable as JSON`
	end
	return true, value
end

--[[
	DataStore。place が universe に紐づいて公開されていて、Studio の
	File > Experience Settings > Security > Enable Studio Access to API Services が要る。
]]
function Store.dataStore(name: string, scope: string?): Backend
	local service = game:GetService("DataStoreService")
	local store = if scope == nil then service:GetDataStore(name) else service:GetDataStore(name, scope)

	-- 既定の GetAsync は 4 秒キャッシュする。Apply の直後に古い値を読むと履歴がずれるので切る
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false

	return {
		kind = "datastore",
		label = if scope == nil then `DataStore "{name}"` else `DataStore "{name}" ({scope})`,

		get = function(key: string): Result
			local success, raw = pcall(function()
				return store:GetAsync(key, options)
			end)
			if not success then
				return err(tostring(raw))
			end
			if raw == nil then
				return ok(nil)
			end
			if type(raw) ~= "string" then
				return err(`{key}: not a value rosheet wrote (not a JSON string)`)
			end
			local decoded, value = decode(key, raw)
			return if decoded then ok(value) else err(value)
		end,

		set = function(key: string, value: any): Result
			local success, failure = pcall(function()
				store:SetAsync(key, encode(value))
			end)
			return if success then ok(value) else err(tostring(failure))
		end,

		update = function(key: string, transform: (any) -> any): Result
			local aborted = false
			local success, raw = pcall(function()
				return store:UpdateAsync(key, function(current: string?)
					local value: any = nil
					if current ~= nil and type(current) == "string" then
						local decoded, result = decode(key, current)
						if decoded then
							value = result
						end
					end
					local next = transform(value)
					if next == nil then
						aborted = true
						return nil
					end
					return encode(next)
				end)
			end)
			if not success then
				return err(tostring(raw))
			end
			if aborted then
				return err("Conflict: someone else wrote first")
			end
			local decoded, value = decode(key, raw :: string)
			return if decoded then ok(value) else err(value)
		end,
	}
end

--[[
	MemoryStore。共有下書きの速い経路。

	DataStore と同じ Backend の形にしてあるので、呼び手は保存先の違いを知らずに済む。違うのは
	性質の方で、こちらは**揮発する**（`MEMORY_TTL_SECONDS` 触られないと消える）。下書きの永続は
	DataStore 側が持ち、こちらは「いま編集している人どうしを速く繋ぐ」ためだけに使う。

	**1 項目 30KB までしか載らない。** 実測（placeId 102760853725708 の編集モード）で 30720 は
	通り、32768 は `ItemValueSizeTooLarge` で落ちる。だから下書きは値ごとではなくセル単位の差分で
	持つ（`Draft.luau` の冒頭）。それでもあふれる大きさになりうるので、呼び手は書く前に
	`Draft.fitsInMemoryStore` で見る。

	SortedMap を使うのは、キーで引ける唯一の型のため（Queue は読んだ人が消費してしまうので、
	同じ下書きを全員が読む用途には使えない）。
]]
-- 触られなくなった下書きが残り続けないだけの長さ。書くたびに延びるので、編集中に消えることはない
local MEMORY_TTL_SECONDS = 60 * 60

function Store.memoryStore(name: string): Backend
	local service = game:GetService("MemoryStoreService")
	local map = service:GetSortedMap(name)

	return {
		kind = "memorystore",
		label = `MemoryStore "{name}"`,

		get = function(key: string): Result
			local success, raw = pcall(function()
				return map:GetAsync(key)
			end)
			if not success then
				return err(tostring(raw))
			end
			if raw == nil then
				return ok(nil)
			end
			if type(raw) ~= "string" then
				return err(`{key}: not a value rosheet wrote (not a JSON string)`)
			end
			local decoded, value = decode(key, raw)
			return if decoded then ok(value) else err(value)
		end,

		set = function(key: string, value: any): Result
			local success, failure = pcall(function()
				map:SetAsync(key, encode(value), MEMORY_TTL_SECONDS)
			end)
			return if success then ok(value) else err(tostring(failure))
		end,

		update = function(key: string, transform: (any) -> any): Result
			local aborted = false
			local success, raw = pcall(function()
				return map:UpdateAsync(key, function(current: any)
					local value: any = nil
					if current ~= nil and type(current) == "string" then
						local decoded, result = decode(key, current)
						if decoded then
							value = result
						end
					end
					local next = transform(value)
					if next == nil then
						aborted = true
						return nil
					end
					return encode(next)
				end, MEMORY_TTL_SECONDS)
			end)
			if not success then
				return err(tostring(raw))
			end
			if aborted then
				return err("Conflict: someone else wrote first")
			end
			if type(raw) ~= "string" then
				return err(`{key}: not a value rosheet wrote (not a JSON string)`)
			end
			local decoded, value = decode(key, raw :: string)
			return if decoded then ok(value) else err(value)
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
		label = "Local plugin settings",

		get = function(key: string): Result
			local success, raw = pcall(function()
				return plugin:GetSetting(settingKey(key))
			end)
			if not success then
				return err(tostring(raw))
			end
			if raw == nil then
				return ok(nil)
			end
			if type(raw) ~= "string" then
				return err(`{key}: holds a non-string value`)
			end
			local decoded, value = decode(key, raw)
			return if decoded then ok(value) else err(value)
		end,

		set = function(key: string, value: any): Result
			local success, failure = pcall(function()
				plugin:SetSetting(settingKey(key), encode(value))
			end)
			return if success then ok(value) else err(tostring(failure))
		end,

		update = function(key: string, transform: (any) -> any): Result
			local success, value = pcall(function()
				local current = plugin:GetSetting(settingKey(key))
				local decodedValue: any = nil
				if current ~= nil and type(current) == "string" then
					local decoded, result = decode(key, current)
					if decoded then
						decodedValue = result
					end
				end
				local next = transform(decodedValue)
				if next ~= nil then
					plugin:SetSetting(settingKey(key), encode(next))
				end
				return next
			end)
			if not success then
				return err(tostring(value))
			end
			if value == nil then
				return err("Conflict: someone else wrote first")
			end
			return ok(value)
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
	-- 実測すると 2 通り返る。エンジンからの `StudioAccessToApisNotAllowed` と、
	-- API Services からの `502 ... Reason: Studio access to APIs is not allowed.`。
	-- 片方だけ見ていると、もう片方のときに生の 502 が出るだけで次の手が分からない
	local lowered = string.lower(message)
	local blocked = string.find(lowered, "studioaccesstoapisnotallowed", 1, true) ~= nil
		or string.find(lowered, "studio access to apis is not allowed", 1, true) ~= nil
	if blocked then
		return false,
			"Studio cannot reach the API services. Turn on "
				.. '"Enable Studio Access to API Services" in File > Game Settings > Security '
				.. "(the place also has to be published)"
	end
	return false, message
end

return Store
