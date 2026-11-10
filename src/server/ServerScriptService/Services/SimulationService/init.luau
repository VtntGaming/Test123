--!strict
-- Initializes server authority and projects server-owned eligibility into predicted actor state.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Simulation = require(ReplicatedStorage.Simulation)
local State = require(ReplicatedStorage.Simulation.State)
local Types = require(ReplicatedStorage.Simulation.Types)

--// Types
export type Service = {
	-- Initializes authority validation and observer-driven eligibility once.
	Init: () -> (),
	-- Validates the existing place settings and initializes shared simulation.
	Setup: (Service) -> (),
	-- Projects changes from PlayerData and actor lifetimes without per-step inventory reconstruction.
	Start: (Service) -> (),
}

--// Properties
local Initialized = false
local Connections: { [Player]: PlayerData.Connection } = {}
local Relevant: { [string]: boolean } = {
	DataLoaded = true, IsFrozen = true, TeleportingActive = true, IsOnArena = true,
	IsInTrainingArea = true, EquippedAbility = true, EquippedBaseWeapon = true,
	OwnedAbilities = true, DevAccess = true,
}
local Dirty: { [Player]: boolean } = {}

--// Service
local Service: Service = {} :: Service

--// APIs
function Service:Setup()
	-- The open Studio place must match the project; Automatic mode does not replay our inputs.
	assert(Workspace.AuthorityMode == Enum.AuthorityMode.Server, "Set Workspace.AuthorityMode to Server before Play")
	assert(Workspace.StreamingEnabled, "Server authority requires Workspace.StreamingEnabled")
	Simulation.Init()
end

local function Project(record: Types.ActorRecord)
	local player = record.Owner
	if not player or not record.Ready or not PlayerData.HasRecord(player) then return end
	local allowed = PlayerData.Get(player, "DataLoaded") == true
		and PlayerData.Get(player, "IsFrozen") ~= true
		and PlayerData.Get(player, "TeleportingActive") ~= true
		and (PlayerData.Get(player, "IsOnArena") == true or PlayerData.Get(player, "IsInTrainingArea") == true)
	local rawAbility, rawWeapon = PlayerData.Get(player, "EquippedAbility"), PlayerData.Get(player, "EquippedBaseWeapon")
	local ability = if type(rawAbility) == "string" then rawAbility else nil
	local weapon = if type(rawWeapon) == "string" then rawWeapon else nil
	local owned = PlayerData.Get(player, "DevAccess") == true
		or (ability ~= nil and PlayerData.GetItemCount(player, "OwnedAbilities", ability) > 0)
	State.Queue(record.Actor, function()
		if State.Records[record.Actor] ~= record or not record.Ready then return end
		Attributes.Set(record.Root, "SACombatAllowed", allowed)
		Attributes.Set(record.Root, "SAEquippedAbility", ability)
		Attributes.Set(record.Root, "SAEquippedWeapon", weapon)
		Attributes.Set(record.Root, "SAAbilityAllowed", owned)
	end)
end

function Service:Start()
	local function attach(player: Player)
		if Connections[player] then return end
		Connections[player] = PlayerData.ObserveAll(player, function(key: string)
			if Relevant[key] then Dirty[player] = true end
		end)
		Dirty[player] = true
	end
	Players.PlayerAdded:Connect(attach)
	Players.PlayerRemoving:Connect(function(player: Player)
		local connection = Connections[player]
		if connection then connection:Disconnect() end
		Connections[player], Dirty[player] = nil, nil
	end)
	State.Observe(function(actor: Types.Actor, record: Types.ActorRecord?)
		if record and record.Owner then Dirty[record.Owner] = true end
	end)
	for _, player in Players:GetPlayers() do attach(player) end
	Simulation.AfterStep(function()
		for player in Dirty do
			Dirty[player] = nil
			local actor = player.Character
			local record = actor and State.Records[actor]
			if record then Project(record) end
		end
	end, 10)
end

function Service.Init()
	if Initialized then
		return
	end
	Initialized = true
	Service:Setup()
	Service:Start()
end

return Service
