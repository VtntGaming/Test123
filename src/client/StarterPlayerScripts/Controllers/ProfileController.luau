-- Presents profile controller behavior using logical Player data access.
local ProfileController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local MainGui = PlayerGui:WaitForChild("MainGui")
local ProfileFrame = MainGui:WaitForChild("ProfileFrame")

local HARDWARE_ICONS = {
	["Controller"] = "rbxassetid://72973314898936",
	["Mobile"] = "rbxassetid://118357127629338",
	["PC"] = "rbxassetid://103495637950753"
}

local state = {
	hoveredPlayer = nil,
	lastClickTime = 0,
	lastPosition = Vector2.zero
}

local hoverHighlight = Instance.new("Highlight")
hoverHighlight.FillColor, hoverHighlight.FillTransparency, hoverHighlight.OutlineTransparency = Color3.fromRGB(255, 255, 255), 0.8, 1

local hoverPrompt = Instance.new("Frame")
hoverPrompt.Size, hoverPrompt.BackgroundColor3, hoverPrompt.BackgroundTransparency, hoverPrompt.Visible, hoverPrompt.ZIndex = UDim2.new(0, 210, 0, 28), Color3.fromRGB(0, 0, 0), 0.5, false, 10
Instance.new("UICorner", hoverPrompt).CornerRadius = UDim.new(1, 0)
local hoverPromptText = Instance.new("TextLabel", hoverPrompt)
hoverPromptText.Size, hoverPromptText.BackgroundTransparency, hoverPromptText.Font, hoverPromptText.TextColor3, hoverPromptText.TextSize, hoverPromptText.ZIndex = UDim2.new(1, 0, 1, 0), 1, Enum.Font.GothamBold, Color3.fromRGB(255, 255, 255), 12, 11
hoverPrompt.Parent = MainGui

-- ==========================================
-- LOGIC
-- ==========================================
local function getTargetFromScreenPosition(pos2D)
	local ray = Camera:ViewportPointToRay(pos2D.X, pos2D.Y)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 100)
	local model = result and result.Instance and result.Instance:FindFirstAncestorOfClass("Model")
	return model and Players:GetPlayerFromCharacter(model) or nil, model
end

local function openPlayerProfile(targetPlayer)
	local stats = ProfileFrame:WaitForChild("Stats")
	local info = ProfileFrame:WaitForChild("InfoHolder")
	local canvasGroup = ProfileFrame:WaitForChild("PlayerIconHolder"):WaitForChild("CanvasGroup")

	-- L'immagine viene creata DENTRO il CanvasGroup, così non sborda. ZIndex impostato a 10.
	local icon = canvasGroup:FindFirstChild("PlayerIcon") or Instance.new("ImageLabel", canvasGroup)
	icon.Name, icon.Size, icon.BackgroundTransparency, icon.ZIndex, icon.Image = "PlayerIcon", UDim2.new(1, 0, 1, 0), 1, 10, ""

	local wins, kills, time =
		PlayerData.Get(targetPlayer, "Wins") or 0,
		PlayerData.Get(targetPlayer, "Kills") or 0,
		PlayerData.Get(targetPlayer, "Playtime") or 0
	local hw = PlayerData.Get(targetPlayer, "Hardware") or "PC"

	info:WaitForChild("PlayerName").Text = targetPlayer.DisplayName
	info:WaitForChild("PlayerNickName").Text = "@" .. targetPlayer.Name

	local platform = info:WaitForChild("Platform")
	platform:WaitForChild("TextLabel").Text = hw
	platform:WaitForChild("PlatformIcon").Image = HARDWARE_ICONS[hw] or HARDWARE_ICONS["PC"]

	stats:WaitForChild("TotalWins"):WaitForChild("StatsLabel").Text = tostring(wins)
	stats:WaitForChild("Eliminations"):WaitForChild("StatsLabel").Text = tostring(kills)
	stats:WaitForChild("TimePlayed"):WaitForChild("StatsLabel").Text = string.format("%d:%02d", math.floor(time / 3600), math.floor((time % 3600) / 60))
	stats:WaitForChild("GamesPlayed"):WaitForChild("StatsLabel").Text =
		tostring(PlayerData.Get(targetPlayer, "GamesPlayed") or 0)
	stats:WaitForChild("PreferredAbility"):WaitForChild("StatsLabel").Text = PlayerData.Get(
		targetPlayer,
		"PreferredAbility"
	) or "N/A"
	stats:WaitForChild("PreferredWeapon"):WaitForChild("StatsLabel").Text = PlayerData.Get(
		targetPlayer,
		"PreferredWeapon"
	) or "N/A"

	task.spawn(function()
		local content, isReady = Players:GetUserThumbnailAsync(targetPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		if isReady then icon.Image = content end
	end)

	UIInteractionController.ToggleFrame(ProfileFrame, true)
end

-- ==========================================
-- INPUT HANDLING
-- ==========================================
local function handleMouseHover()
	if PlayerData.Get(LocalPlayer, "IsOnArena") or PlayerData.Get(LocalPlayer, "IsInTrainingArea") or ProfileFrame.Visible then
		hoverHighlight.Parent, hoverPrompt.Visible, state.hoveredPlayer = nil, false, nil
		return
	end

	local mousePos = UserInputService:GetMouseLocation()
	local playerFound, hitModel = getTargetFromScreenPosition(mousePos)

	if playerFound then
		state.hoveredPlayer, hoverHighlight.Parent = playerFound, hitModel

		hoverPromptText.Text = "Double click to open " .. (playerFound == LocalPlayer and "your" or playerFound.Name .. "'s") .. " profile!"
		hoverPrompt.Position, hoverPrompt.Visible = UDim2.fromOffset(mousePos.X + 15, mousePos.Y + 15), true
	else
		hoverHighlight.Parent, hoverPrompt.Visible, state.hoveredPlayer = nil, false, nil
	end
end

local function handleInputBegan(input: InputObject, processed)
	if processed or (input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch) then return end
	if
		PlayerData.Get(LocalPlayer, "IsOnArena")
		or PlayerData.Get(LocalPlayer, "IsInTrainingArea")
		or ProfileFrame.Visible
	then
		return
	end

	local screenSize = workspace.CurrentCamera.ViewportSize.Magnitude
	local inputPos = Vector2.new(input.Position.X, input.Position.Y)
	local now = os.clock()
	local elapsed = now - state.lastClickTime
	if elapsed < 0.3 then
		local canInteract = true
		if input.UserInputType == Enum.UserInputType.Touch then
			-- Prevent the case where player wanted to zoom out or moving
			local distanceWithLastPos = (inputPos - state.lastPosition).Magnitude

			if elapsed < 0.05 or distanceWithLastPos > screenSize * 0.1 then
				canInteract = false
			end
		end
		local target = getTargetFromScreenPosition(Vector2.new(input.Position.X, input.Position.Y)) or state.hoveredPlayer
		if target and canInteract then openPlayerProfile(target) end
	end
	state.lastClickTime = now
	state.lastPosition = inputPos
end

-- ==========================================
-- INIT
-- ==========================================
function ProfileController.Init()
	ProfileFrame:WaitForChild("ExitButton").MouseButton1Click:Connect(function() 
		UIInteractionController.ToggleFrame(ProfileFrame, false) 
	end)

	RunService.RenderStepped:Connect(handleMouseHover)
	UserInputService.InputBegan:Connect(handleInputBegan)
end

return ProfileController
