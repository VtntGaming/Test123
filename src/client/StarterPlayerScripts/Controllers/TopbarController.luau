-- Presents topbar controller behavior using logical Player data access.
local TopbarController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local SocialService = game:GetService("SocialService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local HapticService = game:GetService("HapticService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local DailyRewardController = require(script.Parent.DailyRewardController)
local Icon = require(ReplicatedStorage:WaitForChild("TopbarPlus"):WaitForChild("Icon"))
local SpectateController = require(script.Parent:WaitForChild("SpectateController"))
local SettingsController = require(script.Parent:WaitForChild("SettingsController"))

-- ==========================================
-- STATE & VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local SFX = SoundService:WaitForChild("SFX")
local uiSelectSound = SFX:WaitForChild("UISelect")
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateSettingEvent = Events:WaitForChild("UpdateSettingEvent")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")

local isMatchPlaying = false
local initialized = false

-- ==========================================
-- UTILS & FEEDBACK
-- ==========================================
local function triggerHapticFeedback()
	if HapticService:IsMotorSupported(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small) then
		HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0.5)
		task.delay(0.1, function() HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0) end)
	end
end

local function applySoundToIcon(icon)
	icon:bindEvent("selected", function()
		if uiSelectSound then SoundService:PlayLocalSound(uiSelectSound) end
		triggerHapticFeedback()
	end)
	icon:bindEvent("deselected", function()
		if uiSelectSound then SoundService:PlayLocalSound(uiSelectSound) end
	end)
end

local function applyThemeToIcon(icon, sizeX, sizeY, textYOffset)
	pcall(function()
		if type(icon.modifyTheme) == "function" then
			local themeProps = {
				{"IconLabel", "Font", Enum.Font.LuckiestGuy},
				{"IconLabel", "TextYAlignment", Enum.TextYAlignment.Center}
			}
			if textYOffset then
				table.insert(themeProps, {"IconLabel", "AnchorPoint", Vector2.new(0, 0.5)})
				table.insert(themeProps, {"IconLabel", "Position", UDim2.new(0, 0, 0.5, textYOffset)})
			end
			if sizeX and sizeY then
				table.insert(themeProps, {"IconImage", "Size", UDim2.new(sizeX, 0, sizeY, 0)})
				table.insert(themeProps, {"IconImage", "ScaleType", Enum.ScaleType.Fit})
			end
			icon:modifyTheme(themeProps)
		elseif sizeX and sizeY then
			icon:set("iconImageSize", UDim2.new(sizeX, 0, sizeY, 0))
		end
	end)
end

local function createStyledIcon(imageId, sizeX, sizeY, caption, orderLayout)
	local icon = Icon.new():setRight():setOrder(orderLayout):setImage(imageId):setCaption(caption)
	icon.deselectWhenOtherIconSelected = false
	applyThemeToIcon(icon, sizeX, sizeY)
	applySoundToIcon(icon)
	return icon
end

local function setupCharacterSounds(character)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp then return end

	task.spawn(function()
		hrp:WaitForChild("Running", 5)
		for _, child in ipairs(hrp:GetChildren()) do
			if child:IsA("Sound") then child.SoundGroup = SFX end
		end
	end)
end

local function updateSettingAttribute(settingName, newValue)
	local request = PlayerData.SetLocal(LocalPlayer, settingName, newValue)
	UpdateSettingEvent:FireServer(settingName, newValue, request)
end

-- ==========================================
-- INIT
-- ==========================================
function TopbarController.Init()
	if initialized then return end
	initialized = true
	while PlayerData.Get(LocalPlayer, "Setting_AutoAim") == nil or PlayerData.Get(LocalPlayer, "IsAFK") == nil do
		task.wait(0.1)
	end

	local spectateIcon = createStyledIcon("rbxassetid://107916573786833", 0.7, 0.7, "Spectate arena players.", 1)
	SpectateController.Init()
	local syncingSpectateIcon = false
	spectateIcon:bindEvent("toggled", function(_, isSelected)
		if not syncingSpectateIcon then SpectateController.Toggle(isSelected) end
	end)
	local function syncSpectateIcon()
		local available = SpectateController.CanSpectate()
		if not available and PlayerData.Get(LocalPlayer, "IsSpectating") == true then
			SpectateController.Toggle(false)
		end
		local active = PlayerData.Get(LocalPlayer, "IsSpectating") == true
		syncingSpectateIcon = true
		if spectateIcon.isSelected ~= active then
			if active then spectateIcon:select() else spectateIcon:deselect() end
		end
		spectateIcon:setEnabled(available)
		syncingSpectateIcon = false
	end
	SpectateController.AvailabilityChanged:Connect(syncSpectateIcon)
	PlayerData.Observe(LocalPlayer, "IsSpectating", syncSpectateIcon)
	syncSpectateIcon()

	local afkIcon = Icon.new():setRight():setOrder(3)
		:setLabel('<font color="rgb(255,255,255)">AFK</font>', "Deselected")
		:setLabel('<font color="rgb(255,50,50)">AFK</font>', "Selected")
		:setCaption("Stay in the Lobby (AFK)")
	afkIcon.deselectWhenOtherIconSelected = false
	applyThemeToIcon(afkIcon, nil, nil, 3) 
	applySoundToIcon(afkIcon)
	afkIcon:bindEvent("toggled", function(_, isSelected)
		updateSettingAttribute("IsAFK", isSelected) 
	end)

	if PlayerData.Get(LocalPlayer, "IsAFK") == true then
		afkIcon:select()
	end
	
	local shiftLockIcon = createStyledIcon("rbxassetid://76793826179993", 0.7, 0.7, "Toggle Shift Lock", 3)
	shiftLockIcon.deselectWhenOtherIconSelected = false
	shiftLockIcon:setEnabled(
		(PlayerData.Get(LocalPlayer, "IsOnArena") == true) or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
	)

	shiftLockIcon:bindEvent("toggled", function(_, isSelected) 
		if PlayerData.Get(LocalPlayer, "ShiftLock") ~= isSelected then
			PlayerData.SetLocal(LocalPlayer, "ShiftLock", isSelected)
		end
	end)

	PlayerData.Observe(LocalPlayer, "ShiftLock", function()
		local isLocked = PlayerData.Get(LocalPlayer, "ShiftLock") == true
		if shiftLockIcon.isSelected ~= isLocked then
			if isLocked then shiftLockIcon:select() else shiftLockIcon:deselect() end
		end
	end)

	local inviteIcon = createStyledIcon("rbxassetid://127632225079659", 0.7, 0.7, "Invite your friends!", 4)
	inviteIcon:bindEvent("selected", function(icon) 
		pcall(function() SocialService:PromptGameInvite(LocalPlayer) end)
		icon:deselect() 
	end)

	local settingsIcon = createStyledIcon("rbxassetid://113361755071027", 0.7, 0.7, "Open Settings!", 5)
	settingsIcon:bindEvent("toggled", function(_, isSelected) SettingsController.Toggle(isSelected) end)

	if LocalPlayer.Character then task.spawn(setupCharacterSounds, LocalPlayer.Character) end
	LocalPlayer.CharacterAdded:Connect(setupCharacterSounds)
	
	local dailyIcon = Icon.new()
	dailyIcon:setImage("rbxassetid://113857418569077")
	dailyIcon:setRight()
	dailyIcon:setOrder(1)
	dailyIcon:setCaption("Open the daily rewards")
	applySoundToIcon(dailyIcon)
	if DailyRewardController.CanClaim then
		dailyIcon:notify()
	else
		DailyRewardController.NotifyDaily:Once(function()			
			dailyIcon:notify()
		end)
	end

	dailyIcon:bindEvent("toggled", function(_, isSelected) 
		DailyRewardController.Toggle()
	end)

	-- ==========================================
	-- UI VISIBILITY LOGIC
	-- ==========================================
	local function updateUIVisibility()
		local inArena = PlayerData.Get(LocalPlayer, "IsOnArena") == true
		local isAllowedToFight = inArena or (PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)

		inviteIcon:setEnabled(not inArena)
		syncSpectateIcon()
		afkIcon:setEnabled(not inArena)
		dailyIcon:setEnabled(not isAllowedToFight)
		shiftLockIcon:setEnabled(isAllowedToFight)

		--if (inArena or not isMatchPlaying) and spectateIcon.isSelected then 
		--	spectateIcon:deselect() 
		--end
	end

	PlayerData.Observe(LocalPlayer, "IsOnArena", updateUIVisibility)
	PlayerData.Observe(LocalPlayer, "IsInTrainingArea", updateUIVisibility)

	UpdateGameStateEvent.OnClientEvent:Connect(function(state)
		isMatchPlaying = (state == "Playing")
		updateUIVisibility()
	end)

	updateUIVisibility()
end

return TopbarController
