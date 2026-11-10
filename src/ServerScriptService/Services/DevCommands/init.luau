-- Chat commands are authorized on the server.
local DevCommandService = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local ToggleArenaBoundingBox = require(script:WaitForChild("Commands"):WaitForChild("ToggleArenaBoundingBox"))
local StartArenaMatch = require(script.Commands:WaitForChild("StartArenaMatch"))
local GrantAllItems = require(script.Commands:WaitForChild("GrantAllItems"))
local ResetPlayerData = require(script.Commands.ResetPlayerData)

local initialized = false
local lastCommandAt = {}
local COMMAND_COOLDOWN = 0.5

local function isDeveloper(player)
	return RunService:IsStudio() or player:GetAttribute("DevAccess") == true
end

function DevCommandService.Init()
	if initialized then
		return
	end
	initialized = true
	ToggleArenaBoundingBox.Init()

	-- All developer commands share the same server authorization and cooldown.
	local existing = TextChatService:FindFirstChild("DeveloperCommands")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "DeveloperCommands"
	folder.Parent = TextChatService

	for name, handler in {
		ToggleArenaBoundingBox = ToggleArenaBoundingBox,
		StartArenaMatch = StartArenaMatch,
		GiveAllWeapons = GrantAllItems.Weapons,
		GiveAllAbilities = GrantAllItems.Abilities,
		ResetPlayerData = ResetPlayerData,
	} do
		local command = Instance.new("TextChatCommand")
		command.Name = name
		command.PrimaryAlias = handler.PrimaryAlias
		command.SecondaryAlias = handler.SecondaryAlias
		command.Triggered:Connect(function(textSource, text)
			if not textSource then
				return
			end
			local player = Players:GetPlayerByUserId(textSource.UserId)
			if not player or not isDeveloper(player) then
				return
			end
			local now = os.clock()
			if lastCommandAt[player] and now - lastCommandAt[player] < COMMAND_COOLDOWN then
				return
			end
			lastCommandAt[player] = now
			local words = {}
			for word in string.gmatch(text, "%S+") do
				table.insert(words, word)
			end
			local success, message = pcall(handler.Trigger, player, words)
			if not success then
				warn("[DevCommandService]", name, "failed:", message)
			end
		end)
		command.Parent = folder
	end

	Players.PlayerRemoving:Connect(function(player)
		lastCommandAt[player] = nil
	end)
end

return DevCommandService
