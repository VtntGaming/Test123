--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)
local BotConfig = require(ServerScriptService.Services.Helper.BotConfig)
local NPCEntity = require(script:WaitForChild("NPCEntity"))
local BotService = require(script.Parent:WaitForChild("BotService"))

type NPCEntityType = typeof(NPCEntity.new())

type ArenaAppearance = NPCEntity.ArenaAppearance

export type Profile = ArenaAppearance & {
	EquippedAbility: string,
	EquippedWeapon: string,
	EquippedWeaponSkin: string, -- ADD THIS
	Aggression: number,
}

export type LobbyNPCServiceType = {
	Init: () -> (),
	GetNPCSlots: () -> number,
	AssignToArena: (spawnPart: BasePart, list: { Model }, minCount: number?) -> number,
	ReturnArenaNPCs: () -> (),
	Owns: (model: Model) -> boolean,
}

local LobbyNPCService = {} :: LobbyNPCServiceType
local MAX_BOTS: number = BotConfig.MaxBots or (BotConfig :: any).NPCCount or 10 -- BotConfig.MaxBots: bots while one real player is on the server
local RandomGenerator = Random.new()
local npcEntities: { [Model]: NPCEntityType } = {}
local initialized = false
local refillRunning = false
local FULL_JOIN_CHANCE = 0.35 -- chance that every available bot joins the match
local AFK_CHANCE = 0.75 -- chance that a bot that sits the round out shows AFK (others just wander in the lobby)

local function arenaNPCCount(): number
	local count = 0
	for _, entity in npcEntities do
		if entity.IsInArena and not entity.IsDestroyed then
			count += 1
		end
	end
	for _, model in CollectionService:GetTagged("ArenaNPC") do
		if model:IsDescendantOf(Workspace) and not npcEntities[model :: any] then
			count += 1
		end
	end
	return count
end

-- Total bots = MaxBots - real players, so the server population stays at MaxBots (0 players = MaxBots bots, every player removes one).
-- Bots fighting in the arena count towards the total, so the lobby only holds what is left.
local function desiredLobbyNPCCount(): number
	return math.clamp(MAX_BOTS - #Players:GetPlayers() - arenaNPCCount(), 0, MAX_BOTS)
end

local function pruneMissingEntities()
	for model, entity in npcEntities do
		if entity.IsDestroyed or ((entity.IsReady or entity.IsInArena) and not model.Parent) then
			npcEntities[model] = nil
		end
	end
end

local function lobbyNPCCount(): number
	local count = 0
	for _, entity in npcEntities do
		if not entity.IsDestroyed and not entity.IsInArena then
			count += 1
		end
	end
	return count
end

local function removeExcessLobbyNPCs(targetCount: number)
	local excess = lobbyNPCCount() - targetCount
	if excess <= 0 then return end

	for model, entity in npcEntities do
		if excess <= 0 then break end
		if not entity.IsInArena then
			entity:Destroy()
			npcEntities[model] = nil
			excess -= 1
		end
	end
end

local function refillLobbyNPCs()
	if refillRunning then return end
	refillRunning = true

	task.spawn(function()
		while true do
			pruneMissingEntities()
			if lobbyNPCCount() >= desiredLobbyNPCCount() then break end

			local profile = NPCEntity.CreateProfile()
			if lobbyNPCCount() >= desiredLobbyNPCCount() then
				profile.Description:Destroy()
				break
			end

			local entity = NPCEntity.new()
			local spawnPart = Workspace:WaitForChild(GameConfig.LobbyName):WaitForChild("Spawn") :: BasePart
			local spawnCFrame = spawnPart.CFrame * CFrame.new(
				RandomGenerator:NextNumber(-spawnPart.Size.X * 0.35, spawnPart.Size.X * 0.35),
				spawnPart.Size.Y * 0.5 + 3,
				RandomGenerator:NextNumber(-spawnPart.Size.Z * 0.35, spawnPart.Size.Z * 0.35)
			)
			entity:Setup(profile, spawnCFrame)
			npcEntities[entity.Model] = entity
			entity:Start()
		end

		refillRunning = false
	end)
end

local function reconcileNPCCount()
	pruneMissingEntities()
	removeExcessLobbyNPCs(desiredLobbyNPCCount())
	refillLobbyNPCs()
end

-- Random amount of lobby bots that join the arena each round (BotConfig.LobbyBotsMin..LobbyBotsMax), never the same twice in a row.
-- The rest keep wandering in the lobby.
local lastAssignCount: number? = nil
local function rollAssignCount(available: number, minCount: number?): number
	local low = math.clamp(math.max(BotConfig.LobbyBotsMin or available, minCount or 1), 1, available)
	local high = math.clamp(BotConfig.LobbyBotsMax or available, low, available)
	local count = RandomGenerator:NextInteger(low, high)
	if high > low and count == lastAssignCount then
		count = low + (count - low + RandomGenerator:NextInteger(1, high - low)) % (high - low + 1)
	end
	lastAssignCount = count
	return count
end

function LobbyNPCService.Init()
	if initialized then return end
	initialized = true

	-- A bot that is eliminated mid-match is destroyed by MatchService: refill the lobby so it shows up there again.
	CollectionService:GetInstanceRemovedSignal("ArenaNPC"):Connect(function(model)
		if npcEntities[model :: any] then task.delay(1.5, reconcileNPCCount) end
	end)

	task.delay(5, function()
		Players.PlayerAdded:Connect(function()
			task.defer(reconcileNPCCount)
		end)
		Players.PlayerRemoving:Connect(function()
			task.defer(reconcileNPCCount)
		end)
		reconcileNPCCount()
	end)
end

function LobbyNPCService.GetNPCSlots(): number
	return desiredLobbyNPCCount()
end

function LobbyNPCService.AssignToArena(spawnPart: BasePart, list: { Model }, minCount: number?): number
	pruneMissingEntities()
	local available: {any} = {}
	for _, entity in npcEntities do
		if entity.IsReady and not entity.IsInArena and not entity.IsDestroyed then
			table.insert(available, entity)
		end
	end

	local count = math.min(#available, desiredLobbyNPCCount())
	if count == 0 then return 0 end
	-- shuffle so a different set of bots joins each round
	for i = #available, 2, -1 do
		local j = RandomGenerator:NextInteger(1, i)
		available[i], available[j] = available[j], available[i]
	end
	-- sometimes everybody joins, otherwise a random amount joins and part of the rest sits AFK in the lobby
	local totalAvailable = count
	if RandomGenerator:NextNumber() >= FULL_JOIN_CHANCE then
		count = rollAssignCount(count, minCount)
	end
	for index = count + 1, #available do
		local afkModel = available[index].Model
		if afkModel then afkModel:SetAttribute("IsAFK", RandomGenerator:NextNumber() < AFK_CHANCE) end
	end

	local radius = GameConfig.ArenaSpawnRadius or 15
	local assignedCount = 0
	for index = 1, count do
		local angle = ((index - 1) / count) * math.pi * 2
		local targetCFrame = spawnPart.CFrame
			* CFrame.new(math.cos(angle) * radius, 5, math.sin(angle) * radius)
		local entity = available[index]
		entity.Model:SetAttribute("IsAFK", false)
		if entity:MoveToArena(targetCFrame) then
			local profile = entity.Profile
			if profile and BotService.AdoptArenaNPC(entity.Model, {
				Weapon = profile.EquippedWeapon,
				WeaponSkin = profile.EquippedWeaponSkin, -- ADD THIS
				Ability = profile.EquippedAbility,
				Aggression = profile.Aggression,
				VIP = profile.HasVIP,
				}, list) then

				assignedCount += 1
				continue
			end

			entity:ReturnToLobby()
			warn(`LobbyNPCService: failed to assign {entity.Model.Name} to the arena`)
		end
	end

	return assignedCount
end

function LobbyNPCService.ReturnArenaNPCs()
	for model, entity in npcEntities do
		if entity.IsInArena then
			BotService.ReleaseArenaNPC(model)
			entity:ReturnToLobby()
		end
	end
	task.defer(reconcileNPCCount)
end

function LobbyNPCService.Owns(model: Model): boolean
	return npcEntities[model] ~= nil
end

return LobbyNPCService
