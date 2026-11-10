local SettingsService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ==========================================
-- VARIABLES & CONFIG
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateSettingEvent = Events:WaitForChild("UpdateSettingEvent")

local ALLOWED_SETTINGS = {
	Setting_SFXVolume = "number",
	Setting_MusicVolume = "number",
	Setting_PerformanceMode = "boolean",
	Setting_AutoAim = "boolean",
	Setting_InstantChestGamepass = "boolean",
	IsAFK = "boolean",
	Hardware = "string"
}

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================

-- This method ensure the client also changed to that attribute
local function forceAttribute(player: Player, settingName: string, value: any)
	player:SetAttribute(settingName, value)
	UpdateSettingEvent:FireClient(player, settingName, value)
end

local function onSettingUpdated(player: Player, settingName, newValue)
	local expectedType = ALLOWED_SETTINGS[settingName]
	if not expectedType then return end

	if type(newValue) ~= expectedType then return end

	if expectedType == "number" then
		newValue = math.clamp(newValue, 0, 100)
	end

	if settingName == "IsAFK" then
		local isOnArena = player:GetAttribute("IsOnArena")

		if isOnArena then
			forceAttribute(player, "IsAFK", false)
		end
	end

	player:SetAttribute(settingName, newValue)
end

local function CheckPlayer(player: Player)
	player:GetAttributeChangedSignal("IsOnArena"):Connect(function()
		local isOnArena = player:GetAttribute("IsOnArena")

		if isOnArena then
			local isAFK = player:GetAttribute("IsAFK")
			
			if isAFK then
				-- Player is forced to join the match even if they are AFK
				forceAttribute(player, "IsAFK", false)				
			end
		end
	end)
end

-- ==========================================
-- INIT
-- ==========================================
function SettingsService.Init()
	UpdateSettingEvent.OnServerEvent:Connect(onSettingUpdated)

	for _, player in Players:GetPlayers() do
		CheckPlayer(player)
	end

	Players.PlayerAdded:Connect(CheckPlayer)
end

return SettingsService