--!strict
local CommandService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players") :: Players
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local AbilityConfig = require(SharedModules:WaitForChild("AbilityConfig"))

-- Create or reference a RemoteEvent for client notifications
local Events = ReplicatedStorage:WaitForChild("Events")
local ShowNotificationEvent = Events:FindFirstChild("ShowNotificationEvent") or Instance.new("RemoteEvent")
ShowNotificationEvent.Name = "ShowNotificationEvent"
ShowNotificationEvent.Parent = Events

-- ==========================================
-- CONSTANTS
-- ==========================================
local OWNED_ABILITY_ATTR = "OwnedAbilities"
local EQUIPPED_ABILITY_ATTR = "EquippedAbility"

-- ==========================================
-- HELPER FUNCTIONS
-- ==========================================
local function findMatchingPlayer(nameQuery: string): Player?
	local query = string.lower(nameQuery)
	for _, player in ipairs(Players:GetPlayers()) do
		if string.lower(player.Name) == query or string.lower(player.DisplayName) == query then
			return player
		end
		if string.sub(string.lower(player.Name), 1, #query) == query then
			return player
		end
	end
	return nil
end

local function parseArgs(message: string): {string}
	local args = {}
	for word in string.gmatch(message, "%S+") do
		table.insert(args, word)
	end
	return args
end

-- ==========================================
-- CORE COMMAND LOGIC
-- ==========================================
function CommandService.SetPlayerAbility(executor: Player, targetPlayer: Player, abilityName: string): boolean
	local abilityList = AbilityConfig.Abilities :: {[string]: any}

	-- Match ability name
	local matchedAbility: string? = nil
	for name in pairs(abilityList) do
		if string.lower(name) == string.lower(abilityName) then
			matchedAbility = name
			break
		end
	end

	if not matchedAbility then
		ShowNotificationEvent:FireClient(executor, "Error", `Ability '<b>{abilityName}</b>' does not exist!`)
		return false
	end

	-- Check owned abilities
	local ownedStr = targetPlayer:GetAttribute(OWNED_ABILITY_ATTR) or ""
	local ownedTable = string.split(ownedStr, ",")
	local alreadyOwned = table.find(ownedTable, matchedAbility) ~= nil

	if not alreadyOwned then
		if ownedStr == "" then
			targetPlayer:SetAttribute(OWNED_ABILITY_ATTR, matchedAbility)
		else
			targetPlayer:SetAttribute(OWNED_ABILITY_ATTR, ownedStr .. "," .. matchedAbility)
		end
	end
	-- Equip ability
	targetPlayer:SetAttribute(EQUIPPED_ABILITY_ATTR, matchedAbility)

	-- Notify Target Player
	ShowNotificationEvent:FireClient(targetPlayer, "Success", `Equipped ability: <b>{matchedAbility}</b>`)

	-- Only notify executor if they are modifying SOMEONE ELSE
	if executor ~= targetPlayer then
		ShowNotificationEvent:FireClient(executor, "Info", `Set <b>{targetPlayer.Name}</b>'s ability to <b>{matchedAbility}</b>`)
	end


	return true
end

function CommandService.ProcessCommand(executor: Player, message: string)
	local args = parseArgs(message)
	local cmd = string.lower(args[1] or "")

	if cmd == "/set" or cmd == "/setability" then
		local targetQuery = args[2]
		local abilityQuery = args[3]

		if not targetQuery or not abilityQuery then
			ShowNotificationEvent:FireClient(executor, "Warning", "Usage: /set <player> <ability>")
			return
		end

		local targetPlayer = findMatchingPlayer(targetQuery)
		if not targetPlayer then
			ShowNotificationEvent:FireClient(executor, "Error", `Player '<b>{targetQuery}</b>' not found!`)
			return
		end

		CommandService.SetPlayerAbility(executor, targetPlayer, abilityQuery)
	end
end
function CommandService.Init()
	-- USE DEV COMMAND SERVICE INSTEAD


	-- -- Only use legacy Player.Chatted if TextChatService is NOT active
	-- if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
	-- 	Players.PlayerAdded:Connect(function(player)
	-- 		player.Chatted:Connect(function(message)
	-- 			CommandService.ProcessCommand(player, message)
	-- 		end)
	-- 	end)

	-- 	for _, player in ipairs(Players:GetPlayers()) do
	-- 		player.Chatted:Connect(function(message)
	-- 			CommandService.ProcessCommand(player, message)
	-- 		end)
	-- 	end
	-- else
	-- 	-- Modern TextChatService support
	-- 	local setCmd = Instance.new("TextChatCommand")
	-- 	setCmd.Name = "SetAbilityCommand"
	-- 	setCmd.PrimaryAlias = "/set"
	-- 	setCmd.SecondaryAlias = "/setability"
	-- 	setCmd.Parent = TextChatService:WaitForChild("TextChatCommands")

	-- 	setCmd.Triggered:Connect(function(textSource, rawText)
	-- 		local player = Players:GetPlayerByUserId(textSource.UserId)
	-- 		if player then
	-- 			CommandService.ProcessCommand(player, rawText)
	-- 		end
	-- 	end)
	-- end
end


return CommandService
