--!strict
-- Apply した値をプレイテスト中のゲームへ届ける。
--
-- 置き場は ReplicatedStorage の RosheetLive フォルダ。ゲーム側の `bind` がこれを見つけたら
-- 同梱値の代わりに使う。本番ではこのフォルダが存在しないので、`bind` は同梱値をそのまま返す。
--
-- 編集モードでは何も作らない。編集モードで Instance を足すと place が変更済みになり、
-- そのまま保存されて本番へ紛れ込む。作るのはプレイテストが走っている間だけ。

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "RosheetLive"
local SCHEMA_NAME = "__schema"
local VERSION_NAME = "__version"

local Live = {}

function Live.isPlaying(): boolean
	return RunService:IsRunning()
end

local function folder(): Folder?
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	return if existing ~= nil and existing:IsA("Folder") then existing else nil
end

local function ensureFolder(): Folder
	local existing = folder()
	if existing ~= nil then
		return existing
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = ReplicatedStorage
	return created
end

local function setValue(parent: Folder, name: string, text: string)
	local value = parent:FindFirstChild(name)
	if value == nil or not value:IsA("StringValue") then
		if value ~= nil then
			value:Destroy()
		end
		value = Instance.new("StringValue")
		;(value :: StringValue).Name = name
		;(value :: StringValue).Parent = parent
	end
	;(value :: StringValue).Value = text
end

--[[
	現在の値をまるごと配信する。version を最後に上げるのは、ゲーム側が version の変化を
	合図に読み直すため（途中の状態を読ませない）。
]]
function Live.publish(schema: any, dataset: { [string]: any }, seq: number)
	if not Live.isPlaying() then
		return
	end

	local parent = ensureFolder()
	setValue(parent, SCHEMA_NAME, HttpService:JSONEncode(schema))
	for _, sheet in schema.sheets do
		setValue(parent, sheet.name, HttpService:JSONEncode(dataset[sheet.name]))
	end

	local version = parent:FindFirstChild(VERSION_NAME)
	if version == nil or not version:IsA("IntValue") then
		if version ~= nil then
			version:Destroy()
		end
		version = Instance.new("IntValue")
		;(version :: IntValue).Name = VERSION_NAME
		;(version :: IntValue).Parent = parent
	end
	;(version :: IntValue).Value = seq
end

--[[ プレイテストが終わったら片付ける。編集モードに残すと place が汚れる ]]
function Live.clear()
	local existing = folder()
	if existing ~= nil then
		existing:Destroy()
	end
end

Live.FOLDER_NAME = FOLDER_NAME

return Live
