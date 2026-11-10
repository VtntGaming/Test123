-- Presents settings controller behavior using logical Player data access.
local SettingsController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateSettingEvent = Events:WaitForChild("UpdateSettingEvent")

local SFX = SoundService:WaitForChild("SFX")
local Soundtrack = SoundService:WaitForChild("Soundtrack")

local ui = {}
local state = {
	originalGraphics = {
		GlobalShadows = Lighting.GlobalShadows,
		EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
		EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
		PostEffects = {}
	}
}

-- ==========================================
-- GRAPHICS LOGIC
-- ==========================================
local function cacheOriginalGraphics()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("PostEffect") then state.originalGraphics.PostEffects[child] = child.Enabled end
	end
end

local function applyPerformanceMode(isEnabled)
	Lighting.GlobalShadows = not isEnabled and state.originalGraphics.GlobalShadows or false
	Lighting.EnvironmentSpecularScale = isEnabled and 0 or state.originalGraphics.EnvironmentSpecularScale
	Lighting.EnvironmentDiffuseScale = isEnabled and 0 or state.originalGraphics.EnvironmentDiffuseScale

	for effect, originalState in pairs(state.originalGraphics.PostEffects) do 
		effect.Enabled = not isEnabled and originalState or false 
	end
end

local function updateSettingAttribute(settingName, newValue)
	local request = PlayerData.SetLocal(LocalPlayer, settingName, newValue)
	UpdateSettingEvent:FireServer(settingName, newValue, request)
end

-- ==========================================
-- UI WIDGETS LOGIC
-- ==========================================
local function setupSlider(labelName, settingName, soundGroup)
	local label = ui.ScrollingFrame:WaitForChild(labelName)
	local valLabel = label:WaitForChild("Value")
	local sliderFrame = label:WaitForChild("SliderFrame")
	local sliderBtn = sliderFrame:WaitForChild("SliderButton")
	local fillFrame = sliderFrame:WaitForChild("FillFrame")

	local function setPercentage(pct)
		pct = math.clamp(pct, 0, 1)
		sliderBtn.Position = UDim2.new(pct, 0, 0.5, 0)
		if fillFrame then fillFrame.Size = UDim2.new(pct, 0, 1, 0) end

		local displayVal = math.floor(pct * 100)
		valLabel.Text = tostring(displayVal)
		soundGroup.Volume = pct
	end

	local initVal = PlayerData.Get(LocalPlayer, settingName) or 50
	setPercentage(initVal / 100)

	local isDragging = false
	sliderBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDragging = true
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if isDragging then
				isDragging = false
				updateSettingAttribute(settingName, tonumber(valLabel.Text))
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if isDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local mouseX = input.Position.X
			local sliderX = sliderFrame.AbsolutePosition.X
			local sliderWidth = sliderFrame.AbsoluteSize.X

			local pct = (mouseX - sliderX) / sliderWidth
			setPercentage(pct)
		end
	end)
end

local function setupSwitch(labelName, settingName, callback)
	local label = ui.ScrollingFrame:WaitForChild(labelName)
	local switchBtn = label:WaitForChild("SwitchButton")
	local switchName = switchBtn:WaitForChild("SwitchName")

	local function updateVisuals(isOn)
		switchName.Text = isOn and "On" or "Off"
		switchBtn.Image = isOn and "rbxassetid://91229983629314" or "rbxassetid://113463660089692"
		if callback then callback(isOn) end
	end

	local startVal = PlayerData.Get(LocalPlayer, settingName)
	if startVal == nil then startVal = false end
	updateVisuals(startVal)

	switchBtn.MouseButton1Click:Connect(function()
		local newVal = not PlayerData.Get(LocalPlayer, settingName)
		updateSettingAttribute(settingName, newVal)
		updateVisuals(newVal)
	end)
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function SettingsController.Toggle(forceState)
	local isOpening = forceState
	if isOpening == nil then
		isOpening = not ui.SettingsFrame.Visible
	end

	UIInteractionController.ToggleFrame(ui.SettingsFrame, isOpening)
end

-- ==========================================
-- INIT
-- ==========================================
function SettingsController.Init()
	cacheOriginalGraphics()

	while PlayerData.Get(LocalPlayer, "Setting_AutoAim") == nil or PlayerData.Get(LocalPlayer, "IsAFK") == nil do
		task.wait(0.1)
	end

	local MainGui = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui")
	ui.SettingsFrame = MainGui:WaitForChild("SettingsFrame")
	ui.ScrollHolder = ui.SettingsFrame:WaitForChild("ScrollHolder")
	ui.ScrollingFrame = ui.ScrollHolder:WaitForChild("ScrollingFrame")
	ui.SettingsFrame.Visible = false

	local closeBtn = ui.SettingsFrame:FindFirstChild("ExitButton")
	if closeBtn then
		closeBtn.MouseButton1Click:Connect(function() SettingsController.Toggle(false) end)
	end

	setupSlider("SFXLabel", "Setting_SFXVolume", SFX)
	setupSlider("MusicLabel", "Setting_MusicVolume", Soundtrack)

	setupSwitch("PerformanceLabel", "Setting_PerformanceMode", applyPerformanceMode)
	setupSwitch("AimAssistLabel", "Setting_AutoAim", nil)
end

return SettingsController
