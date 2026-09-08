--!strict
-- 履歴の読み書き。src/store.js が定める形をプラグイン側で実装する。
--
-- Apply の手順は「先に head を進めて番号を取る → その番号で blob と commit を書く」。
-- 逆順（書いてから head を進める）だと、2 人が同時に Apply したときに同じ commit 番号へ
-- 両方が書き込み、後から書いた方が相手を消す。番号を先に取れば衝突のしようがない。
--
-- 読み手は commit が見つからないことを許す。番号を取った直後にプラグインが落ちると、
-- head が指す commit が存在しない瞬間ができるため。その場合は 1 つ前まで戻って読む。

local Schema = require(script.Parent.Schema)
local Rows = require(script.Parent.Rows)

-- Store.luau をここで require しない。あれは DataStoreService と HttpService に触るので、
-- 引き込むと履歴の計画を Lune のテストから回せなくなる。要るのは形だけなので型だけ持つ
export type Result = { ok: true, value: any } | { ok: false, error: string }

export type Backend = {
	kind: string,
	label: string,
	get: (key: string) -> Result,
	set: (key: string, value: any) -> Result,
	update: (key: string, transform: (any) -> any) -> Result,
}

local Session = {}

local HEAD_KEY = "head"
local LOG_KEY = "log"
local SCHEMA_KEY = "schema"
local SEQ_DIGITS = 6
local LOG_LIMIT = 200
local MAX_KEY_LENGTH = 50
-- head が指す commit が無いときに遡る上限。これ以上壊れていたら黙って古い値を出さない
local MAX_WALK_BACK = 5

export type Commit = {
	seq: number,
	parent: number?,
	at: string?,
	by: string?,
	note: string,
	sheets: { [string]: number },
	revertOf: number?,
}

export type State = {
	head: number,
	commit: Commit,
	dataset: { [string]: Rows.SheetValue },
}

local function formatSeq(seq: number): string
	return string.format(`%0{SEQ_DIGITS}d`, seq)
end

function Session.commitKey(seq: number): string
	return `commit.{formatSeq(seq)}`
end

function Session.blobKey(seq: number, sheetName: string): string
	return `blob.{formatSeq(seq)}.{sheetName}`
end

function Session.checkSheetNames(schema: Schema.Normalized)
	for _, sheet in schema.sheets do
		local length = #Session.blobKey(0, sheet.name)
		if length > MAX_KEY_LENGTH then
			error(`Sheet name is too long (the DataStore key would exceed {MAX_KEY_LENGTH} characters): {sheet.name}`, 0)
		end
	end
end

local function emptyCommit(): Commit
	return { seq = 0, parent = nil, at = nil, by = nil, note = "", sheets = {} }
end

--[[ 無いキーは nil。符号化は保存先の中でやるので、ここは Luau の値だけを扱う ]]
local function readJson(backend: Backend, key: string): (boolean, any)
	local result = backend.get(key)
	if not result.ok then
		return false, result.error
	end
	return true, result.value
end

local function writeJson(backend: Backend, key: string, value: any): (boolean, string?)
	local result = backend.set(key, value)
	return result.ok, if result.ok then nil else result.error
end

function Session.publishSchema(backend: Backend, schema: Schema.Normalized): (boolean, string?)
	return writeJson(backend, SCHEMA_KEY, schema)
end

function Session.readSchema(backend: Backend): (boolean, any)
	return readJson(backend, SCHEMA_KEY)
end

function Session.readHead(backend: Backend): (boolean, any)
	local success, head = readJson(backend, HEAD_KEY)
	if not success then
		return false, head
	end
	return true, if head == nil then 0 else head.seq
end

--[[ commit が指す blob を集めてデータセットに戻す ]]
local function readDataset(
	backend: Backend,
	schema: Schema.Normalized,
	commit: Commit
): (boolean, any)
	local raw: { [string]: any } = {}
	for _, sheet in schema.sheets do
		local blobSeq = commit.sheets[sheet.name]
		-- この commit より後にスキーマへ足されたシートは、その commit には入っていない
		if blobSeq ~= nil then
			local success, value = readJson(backend, Session.blobKey(blobSeq, sheet.name))
			if not success then
				return false, value
			end
			if value == nil then
				return false, `{Session.blobKey(blobSeq, sheet.name)} is missing`
			end
			raw[sheet.name] = value
		end
	end

	local normalized, dataset = pcall(Rows.normalizeDataset, schema, raw)
	if not normalized then
		return false, tostring(dataset)
	end
	return true, dataset
end

function Session.readCommit(backend: Backend, seq: number): (boolean, any)
	if seq == 0 then
		return true, emptyCommit()
	end
	return readJson(backend, Session.commitKey(seq))
end

--[[
	現在の値を読む。head が指す commit がまだ書かれていない瞬間があるので、少しだけ遡る。
]]
function Session.readCurrent(backend: Backend, schema: Schema.Normalized): (boolean, any)
	local success, head = Session.readHead(backend)
	if not success then
		return false, head
	end

	local seq = head :: number
	for _ = 0, MAX_WALK_BACK do
		local found, commit = Session.readCommit(backend, seq)
		if not found then
			return false, commit
		end
		if commit ~= nil then
			local read, dataset = readDataset(backend, schema, commit)
			if not read then
				return false, dataset
			end
			return true, { head = head, commit = commit, dataset = dataset } :: State
		end
		if seq == 0 then
			break
		end
		seq -= 1
	end

	return false, `Cannot find commit #{head} that head points at`
end

function Session.readLog(backend: Backend): (boolean, any)
	local success, log = readJson(backend, LOG_KEY)
	if not success then
		return false, log
	end
	return true, if log == nil then { entries = {} } else log
end

local function appendLog(backend: Backend, commit: Commit, changed: { string })
	local success, log = Session.readLog(backend)
	if not success then
		return
	end

	local entries = { {
		seq = commit.seq,
		at = commit.at,
		by = commit.by,
		note = commit.note,
		changed = changed,
		revertOf = commit.revertOf,
	} }
	for _, entry in log.entries do
		if #entries >= LOG_LIMIT then
			break
		end
		table.insert(entries, entry)
	end

	-- 履歴の一覧は表示用の要約なので、書けなくても Apply 自体は成功にする
	writeJson(backend, LOG_KEY, { entries = entries })
end

--[[ head を 1 つ進めて自分の commit 番号を確保する。誰かが先に進めていたら諦める ]]
local function reserve(backend: Backend, expected: number): (boolean, any)
	local result = backend.update(HEAD_KEY, function(current: any): any
		local seq = if current == nil then 0 else current.seq
		if seq ~= expected then
			return nil
		end
		return { seq = expected + 1 }
	end)

	if not result.ok then
		return false, result.error
	end
	return true, expected + 1
end

local function writeCommit(
	backend: Backend,
	commit: Commit,
	blobs: { { key: string, value: any } },
	changed: { string }
): (boolean, any)
	for _, blob in blobs do
		local written, failure = writeJson(backend, blob.key, blob.value)
		if not written then
			return false, failure
		end
	end

	local written, failure = writeJson(backend, Session.commitKey(commit.seq), commit)
	if not written then
		return false, failure
	end

	appendLog(backend, commit, changed)
	return true, commit
end

--[[
	Apply。変わったシートだけ新しい blob を作り、変わらないシートは前の commit の blob を指し直す。
]]
function Session.apply(
	backend: Backend,
	schema: Schema.Normalized,
	state: State,
	next: { [string]: Rows.SheetValue },
	meta: { at: string, by: string, note: string? }
): (boolean, any)
	local changed: { string } = {}
	for _, sheet in schema.sheets do
		local before = state.dataset[sheet.name]
		local after = next[sheet.name]
		if state.commit.sheets[sheet.name] == nil or not Rows.equal(sheet, before, after) then
			table.insert(changed, sheet.name)
		end
	end

	if #changed == 0 then
		return true, nil
	end

	local reserved, seq = reserve(backend, state.head)
	if not reserved then
		return false, seq
	end

	local sheets: { [string]: number } = {}
	local blobs: { { key: string, value: any } } = {}
	for _, sheet in schema.sheets do
		if table.find(changed, sheet.name) ~= nil then
			sheets[sheet.name] = seq
			table.insert(blobs, { key = Session.blobKey(seq, sheet.name), value = next[sheet.name] })
		else
			sheets[sheet.name] = state.commit.sheets[sheet.name]
		end
	end

	local commit: Commit = {
		seq = seq,
		parent = if state.head == 0 then nil else state.head,
		at = meta.at,
		by = meta.by,
		note = if meta.note == nil then "" else meta.note,
		sheets = sheets,
	}

	return writeCommit(backend, commit, blobs, changed)
end

--[[
	巻き戻し。昔の commit と同じ中身を指す新しい commit を積む。blob は既にあるので書かない。
	履歴を書き換えないので、戻したあとにさらに戻れる。
]]
function Session.revert(
	backend: Backend,
	state: State,
	target: Commit,
	meta: { at: string, by: string, note: string? }
): (boolean, any)
	if target.seq == 0 then
		return false, "Commit #0 is a sentinel and cannot be restored"
	end

	local reserved, seq = reserve(backend, state.head)
	if not reserved then
		return false, seq
	end

	local changed: { string } = {}
	for name in target.sheets do
		table.insert(changed, name)
	end
	table.sort(changed)

	local commit: Commit = {
		seq = seq,
		parent = state.head,
		at = meta.at,
		by = meta.by,
		note = if meta.note == nil then `revert to #{target.seq}` else meta.note,
		sheets = table.clone(target.sheets),
		revertOf = target.seq,
	}

	return writeCommit(backend, commit, {}, changed)
end

Session.HEAD_KEY = HEAD_KEY
Session.LOG_KEY = LOG_KEY
Session.SCHEMA_KEY = SCHEMA_KEY

return Session
