--!strict
-- New-player tutorial (server side).
--  * Persists `TutorialCompleted` (saved by PlayerDataService through DefaultAttributes).
--  * Marks existing/veteran players as completed so they never see the tutorial.
--  * Validates completion (the player really entered an arena) and grants the reward.
-- The guided steps themselves live in Controllers/TutorialController (client).

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local CoinsUtil = require(ReplicatedStorage.Utils.CoinsUtil)

--// References
local Events = ReplicatedStorage:WaitForChild("Events")
local TutorialEvent = Events:WaitForChild("TutorialEvent") :: RemoteEvent
local SpawnVisualCoinsEvent = Events:WaitForChild("SpawnVisualCoins") :: RemoteEvent

--// Constants
local COIN_REWARD = 500
local DATA_LOAD_TIMEOUT = 60
-- Players who already played before the tutorial existed are treated as veterans.
local VETERAN_MIN_GAMES_PLAYED = 2
local VETERAN_MIN_WINS = 1

--// State
local enteredArena: { [Player]: boolean } = {}
local finishing: { [Player]: boolean } = {}

local TutorialService = {}

local function number(value: any): number
	return if type(value) == "number" then value else 0
end

local function isVeteran(player: Player): boolean
	return number(PlayerData.Get(player, "GamesPlayed")) >= VETERAN_MIN_GAMES_PLAYED
		or number(PlayerData.Get(player, "Wins")) >= VETERAN_MIN_WINS
end

local function setupPlayer(player: Player)
	enteredArena[player] = false

	PlayerData.Observe(player, "IsOnArena", function()
		if PlayerData.Get(player, "IsOnArena") == true then
			enteredArena[player] = true
		end
	end)

	task.spawn(function()
		local waited = 0
		while player.Parent == Players and PlayerData.Get(player, "DataLoaded") ~= true do
			if waited >= DATA_LOAD_TIMEOUT then return end
			waited += task.wait(0.25)
		end
		if player.Parent ~= Players then return end

		if PlayerData.Get(player, "TutorialCompleted") ~= true and isVeteran(player) then
			PlayerData.Set(player, "TutorialCompleted", true)
		end
	end)
end

local function onTutorialEvent(player: Player, action: unknown)
	if PlayerData.Get(player, "DataLoaded") ~= true then
		return
	end
	if PlayerData.Get(player, "TutorialCompleted") == true then
		return
	end
	if finishing[player] then return end

	if action == "Skip" then
		PlayerData.Set(player, "TutorialCompleted", true)
		TutorialEvent:FireClient(player, "Done", 0)

	elseif action == "Complete" then
		-- Must really have been inside an arena this session.
		if not enteredArena[player] then return end
		finishing[player] = true

		PlayerData.Set(player, "TutorialCompleted", true)
		local amount = CoinsUtil:GiveCoins(player, COIN_REWARD, "TutorialReward")

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			SpawnVisualCoinsEvent:FireAllClients(root.Position, player, 35, NumberRange.new(3, 5))
		end
		TutorialEvent:FireClient(player, "Done", amount)
	end
end

function TutorialService.Init()
	TutorialEvent.OnServerEvent:Connect(onTutorialEvent)

	Players.PlayerAdded:Connect(setupPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		enteredArena[player] = nil
		finishing[player] = nil
	end)
end

return TutorialService
