--!strict
-- Publishes coherent owner setting snapshots and acknowledges individual optimistic requests.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)

--// References
local AllowedSettings = PlayerData.Schema.Settings
local UpdateSettingEvent = ReplicatedStorage.Events.UpdateSettingEvent

--// Types
export type Service = {
	-- Attaches current and future player observers and request handling once.
	Init: () -> (),
	-- Attaches existing player records.
	Setup: (Service) -> (),
	-- Starts request and player-lifetime listeners.
	Start: (Service) -> (),
}

--// Properties
local Initialized = false
local Connections: { [Player]: PlayerData.Connection } = {}
local Service: Service = {} :: Service

local function Publish(player: Player, key: string)
	if not PlayerData.HasRecord(player) or player.Parent ~= Players then return end
	UpdateSettingEvent:FireClient(player, "State", key, PlayerData.Get(player, key), PlayerData.Version(player, key))
end

local function Attach(player: Player)
	if Connections[player] then return end
	Connections[player] = PlayerData.ObserveAll(player, function(key: string)
		if AllowedSettings[key] then Publish(player, key) end
	end)
end

local function OnSettingUpdated(player: Player, key: unknown, value: unknown, request: unknown)
	if not PlayerData.HasRecord(player) then return end
	if key == "Sync" then
		for name in AllowedSettings do Publish(player, name) end
		return
	end
	if type(key) ~= "string" or AllowedSettings[key] == nil then return end
	if request ~= nil and (type(request) ~= "number" or request ~= request or request <= 0
		or request >= math.huge or request % 1 ~= 0) then return end
	local valid = type(value) == AllowedSettings[key]
	if type(value) == "number" then
		valid = valid and value == value and math.abs(value) < math.huge
		if valid then value = math.clamp(value, 0, 100) end
	end
	if valid then PlayerData.Set(player, key, value) end
	if type(request) == "number" then
		UpdateSettingEvent:FireClient(player, "Ack", key, request, PlayerData.Get(player, key), PlayerData.Version(player, key))
	end
end

function Service:Setup()
	for _, player in Players:GetPlayers() do Attach(player) end
end

function Service:Start()
	Players.PlayerAdded:Connect(Attach)
	Players.PlayerRemoving:Connect(function(player: Player)
		local connection = Connections[player]
		if connection then connection:Disconnect(); Connections[player] = nil end
	end)
	UpdateSettingEvent.OnServerEvent:Connect(OnSettingUpdated)
end

function Service.Init()
	if Initialized then return end
	Initialized = true
	Service:Setup()
	Service:Start()
end

return Service
