--!strict
-- rosheet の Studio プラグイン。
--
-- ツールバーは 1 つだけ作る。プラグインが読み込み直されるたびに CreateToolbar を呼ぶと、
-- 同じ名前のボタンが増えていく。

local App = require(script.App)
local Live = require(script.Live)

local RunService = game:GetService("RunService")

local WIDGET_ID = "rosheetEditor"
local TITLE = "rosheet"

local toolbar = plugin:CreateToolbar(TITLE)
local toggle = toolbar:CreateButton("rosheet", "Edit master data", "rbxasset://textures/StudioSharedUI/menu.png")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	WIDGET_ID,
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 960, 420, 480, 260)
)
widget.Title = TITLE
widget.Name = WIDGET_ID
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local app: any = nil

local function open()
	if app == nil then
		-- 開くまで何も読まない。place を開いただけで DataStore を叩きに行かないように
		app = App.new(widget, plugin)
	else
		app:reload()
	end
end

local function close()
	if app ~= nil then
		app:destroy()
		app = nil
	end
end

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
	if widget.Enabled then
		open()
	else
		close()
	end
end)

toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- プレイテストが終わったら配信用のフォルダを片付ける。編集モードに残すと place が汚れる
RunService:GetPropertyChangedSignal("RunState"):Connect(function()
	if not Live.isPlaying() then
		Live.clear()
	end
end)

plugin.Unloading:Connect(function()
	close()
	Live.clear()
end)

if widget.Enabled then
	toggle:SetActive(true)
	open()
end
