-- Presents bottombar controller behavior using logical Player data access.
local BottombarController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local HapticService = game:GetService("HapticService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local SFX = SoundService:WaitForChild("SFX")
local uiSelectSound = SFX:WaitForChild("UISelect")

local ui = {}
local state = {
	isExpanded = false,
	currentLevel = 1,
	currentExp = 0,
	requiredExp = 10
}

-- Larghezza ridotta dato che abbiamo tolto "Lv."
local COLLAPSED_WIDTH = 60
local EXPANDED_WIDTH = 250
local BAR_HEIGHT = 32

-- ==========================================
-- EXP FORMULA (Client Side)
-- ==========================================	
local function getExpRequirement(level)
	local baseExp = 10
	local incrementPerLevel = 2
	return baseExp + ((level - 1) * incrementPerLevel)
end

-- ==========================================
-- FEEDBACK LOGIC
-- ==========================================
local function triggerHapticFeedback()
	if HapticService:IsMotorSupported(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small) then
		HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0.5)
		task.delay(0.1, function() HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0) end)
	end
end

local function playClickSound()
	if uiSelectSound then SoundService:PlayLocalSound(uiSelectSound) end
	triggerHapticFeedback()
end

-- ==========================================
-- UI GENERATION
-- ==========================================
local function createBottombarUI()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	if playerGui:FindFirstChild("BottombarGui") then
		playerGui.BottombarGui:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BottombarGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 50
	screenGui.Parent = playerGui

	-- Container principale (Stile Topbar di Roblox)
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, COLLAPSED_WIDTH, 0, BAR_HEIGHT)
	mainFrame.AnchorPoint = Vector2.new(1, 1)
	mainFrame.Position = UDim2.new(1, -20, 1, -20)
	mainFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	mainFrame.BackgroundTransparency = 0.5
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui

	-- Questo valore (1, 0) rende gli angoli totalmente sferici (forma a pillola)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) 
	corner.Parent = mainFrame

	local clickBtn = Instance.new("TextButton")
	clickBtn.Size = UDim2.new(1, 0, 1, 0)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Text = ""
	clickBtn.Parent = mainFrame

	-- Icona (Stella)
	local starIcon = Instance.new("ImageLabel")
	starIcon.Size = UDim2.new(0, 18, 0, 18)
	starIcon.AnchorPoint = Vector2.new(0, 0.5)
	starIcon.Position = UDim2.new(0, 10, 0.5, 0) -- Spostato leggermente per via dell'angolo smussato
	starIcon.BackgroundTransparency = 1
	starIcon.Image = "rbxassetid://6787855845"
	starIcon.Parent = mainFrame

	-- Testo del Livello (Solo numero)
	local lvlText = Instance.new("TextLabel")
	lvlText.Name = "LevelText"
	lvlText.Size = UDim2.new(0, 25, 1, 0)
	lvlText.Position = UDim2.new(0, 30, 0, 0)
	lvlText.BackgroundTransparency = 1
	lvlText.Font = Enum.Font.GothamBold
	lvlText.TextColor3 = Color3.fromRGB(255, 255, 255)
	lvlText.TextSize = 14
	lvlText.TextXAlignment = Enum.TextXAlignment.Left
	lvlText.Text = "1"
	lvlText.Parent = mainFrame

	-- Contenitore della Progress Bar
	local progressContainer = Instance.new("Frame")
	progressContainer.Name = "ProgressContainer"
	-- Lascia 16px di respiro a destra per via della curva sferica
	progressContainer.Size = UDim2.new(0, EXPANDED_WIDTH - COLLAPSED_WIDTH - 16, 0, 12)
	progressContainer.AnchorPoint = Vector2.new(0, 0.5)
	progressContainer.Position = UDim2.new(0, COLLAPSED_WIDTH, 0.5, 0)
	progressContainer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	progressContainer.BackgroundTransparency = 0.6
	progressContainer.Parent = mainFrame

	local pCorner = Instance.new("UICorner")
	pCorner.CornerRadius = UDim.new(1, 0)
	pCorner.Parent = progressContainer

	local progressFill = Instance.new("Frame")
	progressFill.Name = "ProgressFill"
	progressFill.Size = UDim2.new(0, 0, 1, 0)
	progressFill.BackgroundColor3 = Color3.fromRGB(255, 215, 0) -- Oro
	progressFill.Parent = progressContainer

	local fCorner = Instance.new("UICorner")
	fCorner.CornerRadius = UDim.new(1, 0)
	fCorner.Parent = progressFill

	local expText = Instance.new("TextLabel")
	expText.Name = "ExpText"
	expText.Size = UDim2.new(1, 0, 1, 0)
	expText.BackgroundTransparency = 1
	expText.Font = Enum.Font.GothamBold
	expText.TextColor3 = Color3.fromRGB(255, 255, 255)
	expText.TextSize = 10
	expText.Text = "0 / 10 EXP"
	expText.ZIndex = 2
	expText.Parent = progressContainer

	ui.MainFrame = mainFrame
	ui.ClickBtn = clickBtn
	ui.LevelText = lvlText
	ui.ProgressFill = progressFill
	ui.ExpText = expText

	return screenGui
end

-- ==========================================
-- UPDATE LOGIC
-- ==========================================
local function updateDataVisuals()
	state.currentLevel = PlayerData.Get(LocalPlayer, "Level") or 1
	state.currentExp = PlayerData.Get(LocalPlayer, "Experience") or 0
	state.requiredExp = getExpRequirement(state.currentLevel)

	-- Aggiorna Testi: rimosso il "Lv."
	if ui.LevelText then ui.LevelText.Text = tostring(state.currentLevel) end
	if ui.ExpText then ui.ExpText.Text = state.currentExp .. " / " .. state.requiredExp .. " EXP" end

	-- Anima la barra (Percentuale)
	local fillPercentage = math.clamp(state.currentExp / state.requiredExp, 0, 1)
	if ui.ProgressFill then
		TweenService:Create(ui.ProgressFill, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(fillPercentage, 0, 1, 0)
		}):Play()
	end
end

local function toggleExpand()
	state.isExpanded = not state.isExpanded
	playClickSound()

	local targetWidth = state.isExpanded and EXPANDED_WIDTH or COLLAPSED_WIDTH

	if ui.MainFrame then
		TweenService:Create(ui.MainFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, targetWidth, 0, BAR_HEIGHT)
		}):Play()
	end
end

-- ==========================================
-- INIT
-- ==========================================
function BottombarController.Init()
	--[[
	-- Aspetta che i dati si carichino
	while PlayerData.Get(LocalPlayer, "Level") == nil do
		task.wait(0.1)
	end

	createBottombarUI()
	updateDataVisuals()

	-- Interazione
	ui.ClickBtn.MouseButton1Click:Connect(toggleExpand)

	-- Aggiornamenti in tempo reale
	PlayerData.Observe(LocalPlayer, "Level", updateDataVisuals)
	PlayerData.Observe(LocalPlayer, "Experience", updateDataVisuals)

	-- Nascondi quando si entra in Arena
	PlayerData.Observe(LocalPlayer, "IsOnArena", function()
		if ui.MainFrame then
			ui.MainFrame.Visible = not PlayerData.Get(LocalPlayer, "IsOnArena")
		end
	end)
	]]
end

return BottombarController
