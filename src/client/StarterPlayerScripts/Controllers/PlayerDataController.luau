--!strict
-- Attaches native player-data observers and reconciles acknowledgements for local settings.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)

--// References
local LocalPlayer = Players.LocalPlayer :: Player

--// Types
export type Controller = {
	-- Initializes native player-data observation and setting acknowledgements once.
	Init: () -> (),
	-- Attaches observers to players already present when the controller loads.
	Setup: (Controller) -> (),
	-- Attaches player lifetime listeners and the authoritative settings response handler.
	Start: (Controller) -> (),
}

--// Properties
local Initialized = false

--// Controller
local Controller: Controller = {} :: Controller

--// APIs
function Controller:Setup()
	for _, player in Players:GetPlayers() do
		PlayerData.Attach(player)
	end
end

function Controller:Start()
	Players.PlayerAdded:Connect(function(player)
		PlayerData.Attach(player)
	end)
	Players.PlayerRemoving:Connect(PlayerData.Release)
	task.spawn(function()
		local events = ReplicatedStorage:WaitForChild("Events")
		local settings = events:WaitForChild("UpdateSettingEvent") :: RemoteEvent
		settings.OnClientEvent:Connect(function(action: string, key: string, first: unknown, second: unknown, revision: number?)
			if action == "State" then
				PlayerData.ApplySettingState(LocalPlayer, key, first, second :: number)
			elseif action == "Ack" then
				PlayerData.ResolveSetting(LocalPlayer, key, first :: number, second, revision :: number)
			end
		end)
		settings:FireServer("Sync")
	end)
end

function Controller.Init()
	if Initialized then
		return
	end
	Initialized = true
	Controller:Setup()
	Controller:Start()
end

return Controller
