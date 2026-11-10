local CodeController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer :: Player
local RedeemFunction = ReplicatedStorage:WaitForChild("Events"):WaitForChild("RedeemCodeFunction")
local NotificationUtil = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NotificationUtil"))

local busy = false

local function submit(textBox)
	if busy then return end
	local text = textBox.Text
	if text == "" then return end

	busy = true
	local ok, success, message = pcall(function()
		return RedeemFunction:InvokeServer(text)
	end)
	busy = false

	if not ok then
		NotificationUtil.Show("Warning", "Could not reach the server, try again")
		return
	end

	NotificationUtil.Show(success and "Success" or "Warning", message)
	if success then textBox.Text = "" end
end

function CodeController.Init()
	local MainGui = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui")
	local settingsFrame = MainGui:WaitForChild("SettingsFrame")
	local row = settingsFrame:WaitForChild("ScrollHolder"):WaitForChild("ScrollingFrame"):WaitForChild("CodeLabel")
	local background = row:WaitForChild("Background")
	local textBox = background:WaitForChild("EnterCode") :: TextBox

	textBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then submit(textBox) end
	end)

	local redeemButton = background:FindFirstChild("RedeemButton")
	if redeemButton then
		redeemButton.MouseButton1Click:Connect(function() submit(textBox) end)
	end
end

return CodeController