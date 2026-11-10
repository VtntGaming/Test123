--!native
--!optimize 2
-- Runs arena matches, enforces void/arena bounds, and applies placement rewards and daily win progress.
local MatchService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ServerScriptService = game:GetService("ServerScriptService")

local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local SimulationState = require(ReplicatedStorage.Simulation.State)
local Monetization = require(ServerScriptService.Services.AnalyticsService.Monetization)
local ArenaLighting = require(script.Parent.Helper.ArenaLighting)
local arenaLighting = ArenaLighting.new(Lighting)

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local AbilityConfig = require(SharedModules:WaitForChild("AbilityConfig"))
local RobuxShopConfig = require(SharedModules.RobuxShopConfig)
local PassesConfig = RobuxShopConfig.Passes
local CoinRewardsConfig = GameConfig.CoinRewards

local RagdollService = require(script.Parent:WaitForChild("RagdollService"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Protection = require(script.Parent:WaitForChild("CombatService"):WaitForChild("Protection"))
local ArenaDestructionService = require(script.Parent:WaitForChild("ArenaDestructionService"))
local ArenaShrinkService = require(script.Parent:WaitForChild("ArenaShrinkService"))
local ArenaFallingService = require(script.Parent:WaitForChild("ArenaFallingService"))
local RanksService = require(script.Parent:WaitForChild("RanksService")) -- [Ranks]
local AnalyticsService = require(script.Parent.AnalyticsService)
local VotingService = require(script.Parent.VotingService)
local DailyWinsService = require(script.Parent.DailyWinsService)
local CoinsUtil = require(ReplicatedStorage.Utils.CoinsUtil)
local LeagueUtil = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("LeagueUtil"))
local PlayLoserSoundEvent = game.ReplicatedStorage.Events.PlayLoserSoundEvent
local MatchEndKOEvent = game.ReplicatedStorage.Events:FindFirstChild("MatchEndKOEvent")
local Events = game.ReplicatedStorage.Events

local ARENA_DROP_HEIGHT = 20
local ARENA_DROP_TIME = 1

local ArenaDropEvent = Events:FindFirstChild("ArenaDropEvent")
local function updateUsageAndPreferred(player, prefix, currentEq, prefAttr)
	if not currentEq or currentEq == "" then return end
	local attrName = prefix .. currentEq
	local newUses = ((PlayerData.Get(player, attrName) :: number?) or 0) + 1
	PlayerData.Set(player, attrName, newUses)

	local currentPref = PlayerData.Get(player, prefAttr)
	if currentPref ~= currentEq and newUses > (currentPref and (PlayerData.Get(player, prefix .. currentPref) :: number?) or 0) then
		PlayerData.Set(player, prefAttr, currentEq)
	end
end

local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")
local KOEvent = Events:WaitForChild("KOEvent")
local ShowResultEvent = Events:WaitForChild("ShowResult") :: RemoteEvent
--local ShowMatchSummaryEvent = Events:WaitForChild("ShowMatchSummary")
local SpawnVisualCoinsEvent = Events:WaitForChild("SpawnVisualCoins")

local Assets = ReplicatedStorage:WaitForChild("Assets")
local PunchingBagTemplate = Assets:WaitForChild("PunchingBag"):WaitForChild("PunchingBag")
local NpcTemplate = Assets:WaitForChild("Npcs"):WaitForChild("Npc")
local ArenasFolder = Assets:WaitForChild("Arenas")

-- ==========================================
-- VARIABLES
-- ==========================================
local initialized = false
local playerConnections = {}
local currentState = "Waiting"
local timer = 0
local spawnedNPCs = {}
local pendingDevArena = nil
local devMatch = false
local devStarting = false
local matchWake = Instance.new("BindableEvent")
local wakeRevision = 0

local LOBBY_BAG_CFRAME = CFrame.new(110.748, 282.951, 35.526)*CFrame.fromEulerAngles(0,math.rad(86),0)
local LOBBY_NPC_CFRAME = CFrame.new(58.508, 282.951, 77.59)*CFrame.fromEulerAngles(0,math.rad(-11.915),0)

local lobbyBag = nil
local lobbyNPC = nil

local MAX_LIVES = 3
local voidHandled = setmetatable({}, {__mode = "k"})
local resolvingVoid = setmetatable({}, {__mode = "k"})
local arenaOutsideSince: {[Model]: number} = setmetatable({}, {__mode = "k"})

local TRAINING_OUTSIDE_TIMEOUT = 3
local TRAINING_BOUNDS_MARGIN = 2 -- Studs of tolerance at the edges.
-- Weak keys avoid retaining removed actors.
local trainingOutsideSince = setmetatable({}, { __mode = "k" })

local lastPositions = {}

-- [Ranks] Identity of the current match. Trophy results are only applied to
-- players whose "MatchId" attribute matches, and only once per match.
local matchId = 0
local matchResolved = false -- true from the end of a match until the next beginMatch
local matchSize = 0
local remainingPlayers = 0
local eliminatedPlayers = {}

-- ==========================================
-- MATCH IDENTITY & STATE (Ranks)
-- ==========================================

local function setRemainingPlayers(count)
	remainingPlayers = math.max(0, count)
	ReplicatedValues.Set(ReplicatedStorage, "RemainingPlayers", remainingPlayers)
end

local function countPlayersOnArena()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerData.Get(player, "IsOnArena") then
			count += 1
		end
	end
	return count
end

local function countAliveNPCs()
	local count = 0
	for _, npc in CollectionService:GetTagged("ArenaNPC") do
		if npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then
			count += 1
		end
	end
	return count
end

local function resetEliminationResults(playerCount)
	table.clear(eliminatedPlayers)
	setRemainingPlayers(playerCount)
end

local function createPlayerResult(player, placement)
	return {
		UserId = player.UserId,
		Name = player.Name,
		Icon = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=48&h=48`,
		Placement = placement,
		RankRating = LeagueUtil.GetLeagueIndex((PlayerData.Get(player, "Trophies") :: number?) or 0),
		RatingChange = (PlayerData.Get(player, "MatchTrophyDelta") :: number?) or 0,
	}
end

local function getResultListing()
	local listing = table.clone(eliminatedPlayers)
	table.sort(listing, function(a, b)
		if a.Placement == b.Placement then
			return a.UserId < b.UserId
		end
		return a.Placement < b.Placement
	end)
	return listing
end

-- Single writer of currentState: also publishes it so RanksService can tell
-- whether a leaving player was mid-match (no require cycle needed).
local function setState(newState)
	if newState == "Intermission" and currentState ~= newState then
		VotingService:Reset()
		if currentState == "Waiting" then
			timer = GameConfig.VoteTime
		else
			timer = GameConfig.IntermissionTime + GameConfig.VoteTime
		end
		VotingService:SetVotingEnabled(true, timer)
	elseif currentState == "Intermission" and newState ~= currentState then
		VotingService:SetVotingEnabled(false)
	end

	currentState = newState
	ReplicatedValues.Set(ReplicatedStorage, "MatchState", newState)
end

-- Called right before the arena teleport. Size only counts players still in the game.
local function beginMatch(participants) --98548063446402
	matchId += 1
	matchResolved = false
	local size = 0
	for _, player in ipairs(participants) do
		if player.Parent == Players then
			size += 1
			PlayerData.Set(player, "MatchId", matchId)
		end
	end
	matchSize = size
	resetEliminationResults(size)
	for _, player in ipairs(participants) do
		if player.Parent == Players then
			PlayerData.Set(player, "MatchTrophyDelta", 0)
		end
	end
	ReplicatedValues.Set(ReplicatedStorage, "MatchId", matchId)
	ReplicatedValues.Set(ReplicatedStorage, "MatchSize", matchSize)
end

-- ==========================================
-- ABILITIES & INVULNERABILITY LOGIC
-- ==========================================
local function removeInvulnerability(player)
	Protection.Clear(player, "Spawn")
end

local function applyInvulnerability(player)
	Protection.Set(player, "Spawn", AbilityConfig.Abilities.SpawnInvulnerability.Duration, player.Character)
end

-- ==========================================
-- MAP REGENERATION & ENVIRONMENT LOGIC
-- ==========================================
local function clearArenaMap()
	table.clear(arenaOutsideSince)
	arenaLighting:Restore()
	for _, arena in ipairs(CollectionService:GetTagged("DestroyableArena")) do arena:Destroy() end
	local fallbackArena = Workspace:FindFirstChild(GameConfig.ArenaName)
	if fallbackArena then fallbackArena:Destroy() end
end

local function spawnArenaMap()
	clearArenaMap()
	local targetArenaName = ReplicatedValues.GetString(ReplicatedStorage, "NextArena") or "DefaultArena"
	local template = ArenasFolder:FindFirstChild(targetArenaName) or ArenasFolder:FindFirstChild("DefaultArena")
	if not template then return false end

	local newArena = template:Clone()
	newArena.Name = GameConfig.ArenaName
	CollectionService:AddTag(newArena, "DestroyableArena")

	arenaLighting:Apply(newArena)

	newArena.Parent = Workspace
	task.wait(0.1)
	return true
end

-- ==========================================
-- ENTITY & SPAWN LOGIC
-- ==========================================
local function setFrozen(actor, player, frozen)
	if not SimulationState.Records[actor] and actor:IsA("Model") then
		RagdollService.RegisterActor(actor, if player then "Player" else "NPC", player)
	end
	if player then
		PlayerData.Set(player, "IsFrozen", frozen)
	end
	if frozen then
		CombatService.CancelActor(actor)
		if player then
			CombatService.CancelAbilities(player, actor)
		end
	end
	local humanoid = actor:FindFirstChildOfClass("Humanoid")
	SimulationState.Queue(actor, function()
		actor:SetAttribute("IsFrozen", frozen)
		if humanoid then
			humanoid.UseJumpPower = false
			humanoid.WalkSpeed = if frozen then 0 else GameConfig.Movement.WalkSpeed
			humanoid.JumpHeight = if frozen then 0 else GameConfig.Movement.JumpHeight
			humanoid.Jump = false
		end
	end)
end

local function freezeArenaEntities(isFrozen)
	for _, player in Players:GetPlayers() do
		if player.Character and PlayerData.Get(player, "IsOnArena") then
			setFrozen(player.Character, player, isFrozen)
		end
	end
	for _, npc in CollectionService:GetTagged("ArenaNPC") do setFrozen(npc, nil, isFrozen) end
end

-- Knockback releases all of its ownership before a teleport; normal movement
-- statistics never count the teleport as traveled distance.
local function relocate(entity, destination, reason)
	arenaOutsideSince[entity] = nil
	local player = if entity:IsA("Model") then Players:GetPlayerFromCharacter(entity) else nil
	CombatService.CancelActor(entity)
	if player then
		CombatService.CancelAbilities(player, entity)
		lastPositions[player.UserId] = nil
	end
	RagdollService.Cancel(entity, reason or "Teleport", destination)
	SimulationState.Queue(entity, function()
		local record = SimulationState.Records[entity]
		if record then
			record.Root.CFrame = destination
			record.Root.AssemblyLinearVelocity, record.Root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			Attributes.Set(record.Root, "KBActive", false)
			Attributes.Set(record.Root, "KBRecoveryRequested", false)
			Attributes.Set(record.Root, "SADropAt", nil)
		end
	end)
	entity:SetAttribute("LastHitBy", nil)
end


-- Drops a player from the sky to groundCF. Anchored during the fall so physics,
-- ragdoll and void checks can't interfere. Cancelled if the teleport is superseded.
local function dropIn(player, char, groundCF, teleportRevision)
	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		return
	end
	local from = groundCF + Vector3.new(0, ARENA_DROP_HEIGHT, 0)
	relocate(char, from, "MatchTeleport")
	PlayerData.Set(player, "ArenaDropping", true)
	SimulationState.Queue(char, function()
		Attributes.Set(root, "SADropAt", time())
		Attributes.Set(root, "SADropDuration", ARENA_DROP_TIME)
		Attributes.Set(root, "SADropFrom", from)
		Attributes.Set(root, "SADropTo", groundCF)
		Attributes.Set(root, "SADropToken", teleportRevision)
		Attributes.Set(root, "SADropDone", nil)
	end)
	local connection
	local function finish(landed)
		if connection then
			connection:Disconnect()
			connection = nil
		end
		if root.Parent then
			SimulationState.Queue(char, function()
				if Attributes.Get(root, "SADropToken") == teleportRevision then
					Attributes.Set(root, "SADropAt", nil)
					root.Anchored = false
				end
			end)
		end
		if (PlayerData.Get(player, "TeleportRevision") :: number?) == teleportRevision then
			PlayerData.Set(player, "ArenaDropping", nil)
			if player.Parent == Players then
				ArenaDropEvent:FireClient(player, if landed then "Land" else "Cancel")
			end
		end
		lastPositions[player.UserId] = nil
	end
	connection = RunService.PostSimulation:Connect(function()
		if
			player.Parent ~= Players
			or player.Character ~= char
			or not char.Parent
			or humanoid.Health <= 0
			or (PlayerData.Get(player, "TeleportRevision") :: number?) ~= teleportRevision
		then
			finish(false)
			return
		end
		if Attributes.Get(root, "SADropDone") == teleportRevision then
			finish(true)
		end
	end)
end

local function isInsideTrainingBounds(position, trainingAreas)
    for _, area in trainingAreas do
        if not area:IsA("BasePart") then
            continue
        end
        local relative = area.CFrame:PointToObjectSpace(position)
        local halfSize = area.Size * 0.5
        -- Ignore height so upward knockback alone doesn't trigger a reset.
        -- TrainingArea parts should be level, with no pitch or roll.
        if math.abs(relative.X) <= halfSize.X + TRAINING_BOUNDS_MARGIN
            and math.abs(relative.Z) <= halfSize.Z + TRAINING_BOUNDS_MARGIN
        then
            return true
        end
    end
    return false
end
local function getMaxLives(player: Player?)
	if player then
		return MAX_LIVES
			+ if PlayerData.Get(player, PassesConfig.VIP.Attribute) then PassesConfig.VIP.Benefits.ExtraLives else 0
	end
	return MAX_LIVES
end
local function getSpawnLocation(areaName)
	local areaFolder = Workspace:FindFirstChild(areaName)
	return areaFolder and areaFolder:FindFirstChild("Spawn")
end

local function getPositionOnCircle(centerCFrame, index, total, radius)
	local angle = ((index / total) * math.pi * 2) + math.random(-30, 30) / 100
	local offset = Vector3.new(
		math.cos(angle) * radius * math.random(70, 130) / 100,
		0,
		math.sin(angle) * radius * math.random(70, 130) / 100
	)
	return centerCFrame * CFrame.new(offset)
end

local function resetEntityPosition(entity, areaName)
	local spawnPart = getSpawnLocation(areaName)
	if not spawnPart or not entity then return end
	local destination = spawnPart.CFrame * CFrame.new(math.random(-4, 4), 5, math.random(-4, 4))
	relocate(entity, destination, "MatchReset")
	local player = if entity:IsA("Model") then Players:GetPlayerFromCharacter(entity) else nil
	if player and areaName == GameConfig.LobbyName then removeInvulnerability(player) end
	if entity:IsA("Model") then setFrozen(entity, player, areaName == GameConfig.ArenaName and currentState == "Starting") end
end

local function teleportPlayersToArea(playerList, areaName, freezeOnArrival)
	local spawnPart = getSpawnLocation(areaName)
	if not spawnPart then return end

	local isGoingToArena = (areaName == GameConfig.ArenaName)
	local totalPlayers = #playerList

	for i, player in ipairs(playerList) do
		if player.Parent ~= Players then continue end
		local teleportRevision = ((PlayerData.Get(player, "TeleportRevision") :: number?) or 0) + 1
		PlayerData.Set(player, "TeleportRevision", teleportRevision)
		PlayerData.Set(player, "TeleportingActive", true)
		local destination = if isGoingToArena then
			getPositionOnCircle(spawnPart.CFrame, i, totalPlayers, GameConfig.ArenaSpawnRadius or 15) + Vector3.new(0, 5, 0)
			else spawnPart.CFrame * CFrame.new(math.random(-4, 4), 5, math.random(-4, 4))
		local placedCharacter = player.Character
		local placedHumanoid = placedCharacter and placedCharacter:FindFirstChildOfClass("Humanoid")
		if placedCharacter and placedCharacter.Parent and placedCharacter:FindFirstChild("HumanoidRootPart")
			and placedHumanoid and placedHumanoid.Health > 0 then
			-- End the old hit before replacing zone/lives. The fixed-step void
			-- callback cannot score an old launch against the next match.
			if isGoingToArena and freezeOnArrival == true then
				dropIn(player, placedCharacter, destination, teleportRevision)
				setFrozen(placedCharacter, player, true)
			else
				relocate(placedCharacter, destination, "MatchTeleport")
				setFrozen(placedCharacter, player, isGoingToArena and freezeOnArrival == true)
			end
		else
			if placedCharacter then
				CombatService.CancelActor(placedCharacter)
				CombatService.CancelAbilities(player, placedCharacter)
				RagdollService.Cancel(placedCharacter, "MatchTransition")
			end
			placedCharacter = nil
		end
		local placedGeneration = placedCharacter and placedCharacter:GetAttribute("RagdollGeneration")
		PlayerData.Set(player, "IsOnArena", isGoingToArena)
		PlayerData.Set(player, "Lives", getMaxLives(player))

		if isGoingToArena then
			PlayerData.Set(player, "GamesPlayed", ((PlayerData.Get(player, "GamesPlayed") :: number?) or 0) + 1)
			updateUsageAndPreferred(
				player,
				"UseW_",
				PlayerData.Get(player, "EquippedBaseWeapon") :: string?,
				"PreferredWeapon"
			)
			updateUsageAndPreferred(
				player,
				"UseA_",
				PlayerData.Get(player, "EquippedAbility") :: string?,
				"PreferredAbility"
			)

			PlayerData.Set(player, "CarriedChests", "")
			PlayerData.Set(player, "MatchKills", 0)
			PlayerData.Set(player, "MatchHits", 0)
			PlayerData.Set(player, "MatchStuds", 0)
		end

		task.spawn(function()
			if
				player.Parent ~= Players
				or (PlayerData.Get(player, "TeleportRevision") :: number?) ~= teleportRevision
			then
				return
			end
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")

			if not char or not char.Parent or not char:FindFirstChild("HumanoidRootPart") or (hum and hum.Health <= 0) then
				local loaded = pcall(function()
					player:LoadCharacter()
				end)
				if not loaded or player.Parent ~= Players then
					if (PlayerData.Get(player, "TeleportRevision") :: number?) == teleportRevision then
						PlayerData.Set(player, "TeleportingActive", nil)
					end
					return
				end
				char = player.Character
			end
			if not char then
				if (PlayerData.Get(player, "TeleportRevision") :: number?) == teleportRevision then
					PlayerData.Set(player, "TeleportingActive", nil)
				end
				return
			end

			local hrp = char:WaitForChild("HumanoidRootPart", 5)
			local newHum = char:WaitForChild("Humanoid", 5)
			task.wait(0.1)

			if char and hrp and newHum and player.Parent == Players and player.Character == char
				and (PlayerData.Get(player, "TeleportRevision") :: number?) == teleportRevision then
				if char ~= placedCharacter or char:GetAttribute("RagdollGeneration") ~= placedGeneration then
					if char ~= placedCharacter or char:GetAttribute("RagdollGeneration") ~= placedGeneration then
						if isGoingToArena and freezeOnArrival == true then
							dropIn(player, char, destination, teleportRevision)
							setFrozen(char, player, true)
						else
							relocate(char, destination, "MatchTeleport")
						end
					end				end
				if isGoingToArena then
					setFrozen(char, player, freezeOnArrival == true)
					--applyInvulnerability(player)
				else
					setFrozen(char, player, false)
					removeInvulnerability(player)
				end
			end
			if (PlayerData.Get(player, "TeleportRevision") :: number?) == teleportRevision then
				PlayerData.Set(player, "TeleportingActive", nil)
			end
		end)
	end
end

local function getReadyPlayers()
	local readyPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerData.Get(player, "DataLoaded") == true
			and not PlayerData.Get(player, "IsAFK")
		then
			table.insert(readyPlayers, player)
		end
	end
	return readyPlayers
end

local function onCharacterAdded(player, char)
	local hrp = char:WaitForChild("HumanoidRootPart", 5)
	local hum = char:WaitForChild("Humanoid", 5)
	task.wait(0.1)

	if not hrp or not hum or player.Character ~= char or PlayerData.Get(player, "TeleportingActive") then
		return
	end

	if PlayerData.Get(player, "IsOnArena") then
		resetEntityPosition(char, GameConfig.ArenaName)
		applyInvulnerability(player)
		if currentState == "Starting" then
			setFrozen(char, player, true)
		end
	else
		resetEntityPosition(char, GameConfig.LobbyName)
	end
end

local function setupPlayer(player)
	if playerConnections[player] then return end
	playerConnections[player] = player.CharacterAdded:Connect(function(char) onCharacterAdded(player, char) end)
	if player.Character then task.spawn(onCharacterAdded, player, player.Character) end
end

-- ==========================================
-- LOBBY & ARENA ASSETS LOGIC
-- ==========================================
local function setupLobbyBag()
	if lobbyBag then lobbyBag:Destroy() end
	lobbyBag = PunchingBagTemplate:Clone()
	lobbyBag:PivotTo(LOBBY_BAG_CFRAME)
	if not lobbyBag:HasTag("TrainingBag") then CollectionService:AddTag(lobbyBag, "TrainingBag") end
	lobbyBag.Parent = Workspace
end

local function setupLobbyNPC()
	if lobbyNPC then lobbyNPC:Destroy() end
	lobbyNPC = NpcTemplate:Clone()
	lobbyNPC.Name = "Lobby_Trainer"
	lobbyNPC:PivotTo(LOBBY_NPC_CFRAME)
	lobbyNPC:SetAttribute("SpawnPosition", LOBBY_NPC_CFRAME.Position)
	lobbyNPC:SetAttribute("TerritoryRadius", 25)
	CollectionService:AddTag(lobbyNPC, "LobbyNPC")
	lobbyNPC.Parent = Workspace
end

local function clearArenaAssets()
	for _, npc in ipairs(spawnedNPCs) do if npc then npc:Destroy() end end
	table.clear(spawnedNPCs)
end

local function spawnArenaNPCs()
	local spawnPart = getSpawnLocation(GameConfig.ArenaName)
	if not spawnPart then return end

	local numNPCs = GameConfig.NPCsToSpawn or 3
	for i = 1, numNPCs do
		local npc = NpcTemplate:Clone()
		npc.Name = "Noob_NPC_" .. i
		local targetCF = getPositionOnCircle(spawnPart.CFrame, i, numNPCs, GameConfig.ArenaSpawnRadius or 15)
		npc:PivotTo(targetCF + Vector3.new(0, 5, 0))
		npc:SetAttribute("IsOnArena", true)
		npc:SetAttribute("IsFrozen", true)
		npc:SetAttribute("Lives", getMaxLives())
		CollectionService:AddTag(npc, "ArenaNPC")
		npc.Parent = Workspace
		table.insert(spawnedNPCs, npc)
	end
end

-- ==========================================
-- REWARDS LOGIC
-- ==========================================

local function getPlacementCoins(rank)
	if rank < 1 then return 0 end
	local fixed = CoinRewardsConfig.Placement[rank]
	if fixed then return fixed end
	return if rank <= CoinRewardsConfig.PlacementDefaultMaxRank then CoinRewardsConfig.PlacementDefault else 0
end

local function givePlacementReward(player, rank)
	if not player then return end
	local reward = getPlacementCoins(rank)
	if reward > 0 then
		local amount, balance, vipBonus = CoinsUtil:GiveCoins(player, reward, "MatchReward")
		local context = if PlayerData.Get(player, "Has2xCoins") == true then "2xApplied" else "2xNotApplied"
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = amount, Balance = balance,
			TransactionType = "Gameplay", ItemSku = "Placement:" .. tostring(rank), Activity = "PlacementReward", Context = context,
		})
		AnalyticsService.RecordCustom(player, Monetization.VipBonus(player, vipBonus, "PlacementReward", context))
	end
end

local function grantDelayedCoinsSecurely(targetPlayer: Player, amount: number, activity: string)
	for i = 1, amount do
		task.delay(i * CoinRewardsConfig.KillDripInterval, function()
			if targetPlayer and targetPlayer.Parent then
				local awarded, balance, vipBonus = CoinsUtil:GiveCoins(targetPlayer, 1)
				AnalyticsService.RecordEconomy(targetPlayer, {
					Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = awarded, Balance = balance,
					TransactionType = "Gameplay", ItemSku = activity, Activity = activity, Context = "2xNotApplied",
				})
				AnalyticsService.RecordCustom(targetPlayer, Monetization.VipBonus(targetPlayer, vipBonus, activity, "2xNotApplied"))
			end
		end)
	end
end

local function processEntityKillRewards(entity, fallPos: Vector3)
	local lastHitterName = entity:GetAttribute("LastHitBy")
	if not lastHitterName then return end

	local hitter = Players:FindFirstChild(lastHitterName)
	local isSelfKill = (entity:IsA("Model") and Players:GetPlayerFromCharacter(entity) == hitter)

	if hitter and not isSelfKill then
		if entity:HasTag("TrainingBag") then
			PlayerData.Set(hitter, "BagScore", ((PlayerData.Get(hitter, "BagScore") :: number?) or 0) + 1)
		elseif not entity:HasTag("LobbyNPC") then
			local victim = Players:GetPlayerFromCharacter(entity)
			if CoinRewardsConfig.ArenaKillsOnly and victim and not PlayerData.Get(victim, "IsOnArena") then
				entity:SetAttribute("LastHitBy", nil)
				return
			end
			PlayerData.Set(hitter, "Kills", ((PlayerData.Get(hitter, "Kills") :: number?) or 0) + 1)
			PlayerData.Set(hitter, "MatchKills", ((PlayerData.Get(hitter, "MatchKills") :: number?) or 0) + 1)

			grantDelayedCoinsSecurely(hitter, if victim then CoinRewardsConfig.KillPlayer else CoinRewardsConfig.KillNPC, if victim then "PlayerKill" else "NPCKill")
			SpawnVisualCoinsEvent:FireAllClients(fallPos, hitter)
		end
	end
	entity:SetAttribute("LastHitBy", nil)
end

local function processWinner(winnerPlayer)
	if not winnerPlayer then return end
	PlayerData.Set(winnerPlayer, "Wins", ((PlayerData.Get(winnerPlayer, "Wins") :: number?) or 0) + 1)
	PlayerData.Set(winnerPlayer, "Wins_Day", ((PlayerData.Get(winnerPlayer, "Wins_Day") :: number?) or 0) + 1)
	PlayerData.Set(winnerPlayer, "Wins_Week", ((PlayerData.Get(winnerPlayer, "Wins_Week") :: number?) or 0) + 1)
	PlayerData.Set(winnerPlayer, "Wins_Month", ((PlayerData.Get(winnerPlayer, "Wins_Month") :: number?) or 0) + 1)
	DailyWinsService.RecordWin(winnerPlayer, matchId)
end

-- ==========================================
-- ZONE & OUT OF BOUNDS LOGIC
-- ==========================================
local function isPointInPart(point, part)
	local rel = part.CFrame:PointToObjectSpace(point)
	local halfSize = part.Size / 2
	return math.abs(rel.X) <= halfSize.X and math.abs(rel.Y) <= halfSize.Y and math.abs(rel.Z) <= halfSize.Z
end

-- Last life lost: placement, coins, trophies, result screen, back to the lobby.
local function eliminatePlayer(player, entity)
	-- rank = finishing position: players still on the arena (self included) + living arena NPCs.
	-- rank 1 only happens when the last two players fall in the same tick; it counts as a win.
	local rank = countPlayersOnArena() + countAliveNPCs()
	givePlacementReward(player, rank)

	local oldRating = (PlayerData.Get(player, "Trophies") :: number?) or 0
	RanksService.ApplyMatchResult(player, rank, matchSize, matchId) -- idempotent per match
	local newRating = (PlayerData.Get(player, "Trophies") :: number?) or oldRating
	table.insert(eliminatedPlayers, 1, createPlayerResult(player, rank))

	if rank ~= 1 then
		PlayLoserSoundEvent:FireClient(player)
	end

	PlayerData.Set(player, "IsOnArena", false)
	setRemainingPlayers(countPlayersOnArena())

	-- Ranks 1-2 get their result screen at match end, with the final listing.
	if rank > 2 then
		ShowResultEvent:FireClient(player, rank, getResultListing(), remainingPlayers, oldRating, newRating)
	end
	resetEntityPosition(entity, GameConfig.LobbyName)
end

local function resolveVoid(entity, fallPos, player)
	-- [KO] Who landed the final hit? Read BEFORE processEntityKillRewards clears LastHitBy.
	-- Only real players that are not the victim count (NPC attackers / self falls -> nil).
	local lastHitBy = entity:GetAttribute("LastHitBy")
	local killer = if lastHitBy then Players:FindFirstChild(lastHitBy) else nil
	local killerName = if killer and killer:IsA("Player") and killer ~= player then killer.Name else nil

	local fallPosNormalize = Vector3.new(fallPos.X, GameConfig.VoidHeight, fallPos.Z)

	-- Once the match result is locked (celebration window), arena falls change nothing:
	-- no kill coins, no lives lost, no placement.
	local onArena = (player ~= nil and PlayerData.Get(player, "IsOnArena") == true) or entity:HasTag("ArenaNPC")
	local locked = matchResolved and onArena

	if locked then
		entity:SetAttribute("LastHitBy", nil)
	else
		processEntityKillRewards(entity, fallPosNormalize)
	end

	local eliminated = false -- [KO] true when this entity just lost its LAST life

	if player then
		if not PlayerData.Get(player, "IsOnArena") then
			PlayerData.Set(player, "Deaths", ((PlayerData.Get(player, "Deaths") :: number?) or 0) + 1)
			resetEntityPosition(entity, GameConfig.LobbyName)
		elseif locked then
			resetEntityPosition(entity, GameConfig.ArenaName)
			applyInvulnerability(player)
		else
			PlayerData.Set(player, "Deaths", ((PlayerData.Get(player, "Deaths") :: number?) or 0) + 1)
			local lives = math.max(0, ((PlayerData.Get(player, "Lives") :: number?) or getMaxLives(player)) - 1)
			PlayerData.Set(player, "Lives", lives)
			if lives == 0 then
				eliminated = true
				eliminatePlayer(player, entity)
			else
				resetEntityPosition(entity, GameConfig.ArenaName)
				applyInvulnerability(player)
			end
		end

	elseif entity:HasTag("TrainingBag") then
		relocate(entity, LOBBY_BAG_CFRAME, "BagVoid")

	elseif entity:HasTag("LobbyNPC") then
		relocate(entity, LOBBY_NPC_CFRAME, "TrainerVoid")
		setFrozen(entity, nil, false)

	elseif entity:HasTag("ArenaNPC") then
		if locked then
			resetEntityPosition(entity, GameConfig.ArenaName)
		else
			local lives = math.max(0, (entity:GetAttribute("Lives") or getMaxLives()) - 1)
			entity:SetAttribute("Lives", lives)
			if lives == 0 then
				eliminated = true
				CombatService.CancelActor(entity)
				RagdollService.Cancel(entity, "Eliminated")
				entity:Destroy()
			else
				resetEntityPosition(entity, GameConfig.ArenaName)
			end
		end
	end

	-- [KO] Deciding KO = someone just lost their last life and no other opponent is left.
	--  * PvP : <= 1 player left on the arena, no NPC alive
	--  * Solo: the last NPC was eliminated
	--  * A player losing while NPCs are still alive is NOT a KO
	local isDecidingKO = currentState == "Playing"
		and not matchResolved
		and eliminated
		and countPlayersOnArena() <= 1
		and countAliveNPCs() == 0
	-- 3rd argument = name of the player who landed the final blow (or nil)
	KOEvent:FireAllClients(fallPosNormalize + Vector3.yAxis * 60, isDecidingKO, killerName)
end

-- Shared KO credit / lives path for void crossings and the arena outside timeout.
local function handleVoidLoss(entity: Instance, fallPos: Vector3)
	if not entity or not entity.Parent or resolvingVoid[entity] then return end
	local player = if entity:IsA("Model") then Players:GetPlayerFromCharacter(entity) else nil
	if player and PlayerData.Get(player, "TeleportingActive") then
		return
	end
	local generation = entity:GetAttribute("RagdollGeneration") or entity
	if voidHandled[entity] == generation then return end
	voidHandled[entity], resolvingVoid[entity] = generation, true
	if entity:IsA("Model") then arenaOutsideSince[entity] = nil end

	-- Always release the lock, even on error, so the entity is never stuck falling.
	local ok, err = xpcall(resolveVoid, debug.traceback, entity, fallPos, player)
	resolvingVoid[entity] = nil
	if not ok then
		warn("[MatchService] HandleVoid failed:", err)
	end
end

-- Cartoon calls this at the exact fixed-step crossing; ordinary movement uses polling.
function MatchService.HandleVoid(entity: Instance, fallPos: Vector3)
	if fallPos.Y >= GameConfig.VoidHeight then return end
	handleVoidLoss(entity, fallPos)
end

local function getCombatArenaBounds(): (CFrame?, Vector3?)
	local arena = Workspace:FindFirstChild(GameConfig.ArenaName)
	if not arena or not arena:IsA("Model") then return nil, nil end
	-- Match the crowd-cheer volume's model selection, with the configured larger margin.
	local block = arena:FindFirstChild("Block")
	local main = if block and block:IsA("Folder") then block:FindFirstChild("Main") else nil
	local bounds = if main and main:IsA("Model") then main else arena
	if not bounds:FindFirstChildWhichIsA("BasePart", true) then return nil, nil end
	local frame, size = bounds:GetBoundingBox()
	return frame, (size + GameConfig.ArenaBounds.SizeOffset) * 0.5
end

local function processZonesAndBounds()
	local trainingAreas = CollectionService:GetTagged("TrainingArea")
	local arenaFrame, arenaHalfSize = getCombatArenaBounds()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character then continue end
		if not root or PlayerData.Get(player, "TeleportingActive") or PlayerData.Get(player, "ArenaDropping") then
			arenaOutsideSince[character] = nil
			continue
		end
		local position = RagdollService.GetAuthoritativePosition(character) or root.Position
		if PlayerData.Get(player, "IsOnArena") then
			local last = lastPositions[player.UserId]
			if last then
				-- Total travel includes knockback. Relocate clears history before teleports.
				PlayerData.Set(
					player,
					"MatchStuds",
					((PlayerData.Get(player, "MatchStuds") :: number?) or 0) + (position - last).Magnitude
				)
			end
			lastPositions[player.UserId] = position
		else lastPositions[player.UserId] = nil end
		if position.Y < GameConfig.VoidHeight then
			MatchService.HandleVoid(character, position)
			position = RagdollService.GetAuthoritativePosition(character) or root.Position
		else
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if PlayerData.Get(player, "IsOnArena") == true and arenaFrame and arenaHalfSize
				and humanoid and humanoid.Health > 0 then
				local relative = arenaFrame:PointToObjectSpace(position)
				local isInside = math.abs(relative.X) <= arenaHalfSize.X
					and math.abs(relative.Y) <= arenaHalfSize.Y
					and math.abs(relative.Z) <= arenaHalfSize.Z
				if isInside then
					arenaOutsideSince[character] = nil
				else
					local outsideSince = arenaOutsideSince[character]
					if not outsideSince then
						arenaOutsideSince[character] = now
					elseif now - outsideSince > GameConfig.ArenaBounds.OutsideTimeout then
						handleVoidLoss(character, position)
						position = RagdollService.GetAuthoritativePosition(character) or root.Position
					end
				end
			else
				arenaOutsideSince[character] = nil
			end
		end
		local training = false
		if not PlayerData.Get(player, "IsOnArena") then
			for _, area in trainingAreas do
				if isPointInPart(position, area) then
					training = true
					break
				end
			end
		end
		if PlayerData.Get(player, "IsInTrainingArea") ~= training then
			PlayerData.Set(player, "IsInTrainingArea", training)
		end
	end
	
	for _, tag in { "TrainingBag", "LobbyNPC", "ArenaNPC" } do
		for _, actor in CollectionService:GetTagged(tag) do
			if not actor:IsDescendantOf(Workspace) then
				trainingOutsideSince[actor] = nil
				continue
			end
			local position = RagdollService.GetAuthoritativePosition(actor)
			if not position then
				trainingOutsideSince[actor] = nil
				continue
			end
			-- Preserve the existing immediate void reset.
			if position.Y < GameConfig.VoidHeight then
				trainingOutsideSince[actor] = nil
				MatchService.HandleVoid(actor, position)
				continue
			end
			-- Only training actors get the outside-area timeout.
			if tag == "ArenaNPC" then
				continue
			end
			-- Avoid repeated resets if no training zones are configured.
			if #trainingAreas == 0 then
				trainingOutsideSince[actor] = nil
				continue
			end
			if isInsideTrainingBounds(position, trainingAreas) then
				trainingOutsideSince[actor] = nil
				continue
			end
			local outsideSince = trainingOutsideSince[actor]
			if not outsideSince then
				trainingOutsideSince[actor] = now
				continue
			end
			if now - outsideSince <= TRAINING_OUTSIDE_TIMEOUT then
				continue
			end
			trainingOutsideSince[actor] = nil
			if tag == "TrainingBag" then
				relocate(actor, LOBBY_BAG_CFRAME, "TrainingBounds")
			elseif tag == "LobbyNPC" then
				relocate(actor, LOBBY_NPC_CFRAME, "TrainingBounds")
				setFrozen(actor, nil, false)
			end
		end
	end
end

-- ==========================================
-- MATCH STATE
-- ==========================================
local function SelectRandomArena()
	local arenaName = VotingService:GetResult()
	VotingService:SetVotingEnabled(false)
	ReplicatedValues.Set(ReplicatedStorage, "NextArena", arenaName)
end

local function startPlaying()
	setState("Playing")
	for _, player in Players:GetPlayers() do
		AnalyticsService.RecordMatchStarted(player, matchId)
	end
	timer = GameConfig.MatchTimeLimit
	freezeArenaEntities(false)
	local arena = Workspace:FindFirstChild(GameConfig.ArenaName)
	local arenaType = arena and arena:GetAttribute("ArenaType") or "None"
	if arenaType == "Destruction" then ArenaDestructionService.Start()
	elseif arenaType == "Shrink" then ArenaShrinkService.Start()
	elseif arenaType == "Falling" then ArenaFallingService.Start() end
	UpdateGameStateEvent:FireAllClients("Playing", timer)
end

-- Queue through the state worker, so map spawning/teleports cannot run concurrently.
function MatchService.StartArenaMatch(arenaName)
	if not initialized then return false, "MatchService is not initialized yet." end
	if devStarting or pendingDevArena then return false, "A developer match is already starting." end
	if type(arenaName) ~= "string" then return false, "Usage: /startmatch <arena name>" end
	local template
	for _, arena in ArenasFolder:GetChildren() do
		if string.lower(arena.Name) == string.lower(arenaName) and arena:IsA("Model") then
			template = arena
			break
		end
	end
	if not template then return false, "Unknown arena: " .. arenaName end
	local spawn = template:FindFirstChild("Spawn")
	if not template.Archivable or not spawn or not spawn:IsA("BasePart") then
		return false, "Arena must be clonable and contain a Spawn part: " .. template.Name
	end
	if #getReadyPlayers() == 0 then return false, "No data-loaded, non-AFK players are ready." end
	pendingDevArena = template.Name
	wakeRevision += 1
	matchWake:Fire()
	return true, "Starting match on " .. template.Name .. "."
end

local function startDevMatch(arenaName)
	VotingService:Reset()
	setState("Starting")
	ReplicatedValues.Set(ReplicatedStorage, "LockAFK", true)
	ArenaDestructionService.Stop()
	ArenaShrinkService.Stop()
	ArenaFallingService.Stop()
	local previousPlayers = {}
	for _, player in Players:GetPlayers() do
		if PlayerData.Get(player, "IsOnArena") then
			table.insert(previousPlayers, player)
		end
	end
	teleportPlayersToArea(previousPlayers, GameConfig.LobbyName, false)
	clearArenaAssets()
	ReplicatedValues.Set(ReplicatedStorage, "NextArena", arenaName)
	if not spawnArenaMap() then
		devMatch = false
		setState("Waiting")
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)
		return
	end
	local participants = getReadyPlayers()
	if #participants == 0 then
		clearArenaMap()
		devMatch = false
		setState("Waiting")
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)
		return
	end
	devMatch = true
	beginMatch(participants)
	if #participants == 1 then spawnArenaNPCs() end
	teleportPlayersToArea(participants, GameConfig.ArenaName, false)
	startPlaying()
	ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)
end

local function updateMatchState()
	local currentPlayers = getReadyPlayers()
	local requiredPlayers = RunService:IsStudio() and GameConfig.MinPlayersToStartStudio or GameConfig.MinPlayersToStart

	local alivePlayersInArena = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if PlayerData.Get(p, "IsOnArena") then
			table.insert(alivePlayersInArena, p)
		end
	end

	local npcsAliveCount = 0
	for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
		if npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then npcsAliveCount += 1 end
	end
	local totalAliveInArena = #alivePlayersInArena + npcsAliveCount

	if currentState == "Waiting" then
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)

		if #currentPlayers >= requiredPlayers then
			setState("Intermission")
		else
			UpdateGameStateEvent:FireAllClients("Waiting", 0)
		end

	elseif currentState == "Intermission" then
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)

		if #currentPlayers < requiredPlayers then
			setState("Waiting")
		else
			if timer <= 0 then
				SelectRandomArena()
				if not spawnArenaMap() then
					warn("[MatchService] Failed to build arena map for preparation.")
					setState("Waiting")
					UpdateGameStateEvent:FireAllClients("Waiting", 0)
					return
				end

				setState("Preparing")
				timer = GameConfig.PreparingTime or 10
				UpdateGameStateEvent:FireAllClients("Preparing", timer)
			else
				timer -= 1
				UpdateGameStateEvent:FireAllClients("Intermission", timer)
			end
		end

	elseif currentState == "Preparing" then
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", timer <= 5)

		if timer <= 0 then
			if #currentPlayers < requiredPlayers then
				ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)
				clearArenaAssets()
				clearArenaMap()
				setState("Waiting")
				UpdateGameStateEvent:FireAllClients("Waiting", 0)
			else
				devMatch = false
				if #currentPlayers == 1 then spawnArenaNPCs() end
				beginMatch(currentPlayers) -- [Ranks]

				task.wait(0.35)
				teleportPlayersToArea(currentPlayers, GameConfig.ArenaName, true)
				task.wait(1)
				setState("Starting")
				timer = 3
				--UpdateGameStateEvent:FireAllClients("Starting", timer)
			end
		else
			timer -= 1
			UpdateGameStateEvent:FireAllClients("Preparing", timer)
		end
	elseif currentState == "Starting" then
		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", true)
		UpdateGameStateEvent:FireAllClients("Starting", timer)

		if timer < 0 then
			startPlaying()
		else
			timer -= 1
		end

	elseif currentState == "Playing" then

		ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)

		local isMatchOver = false
		local winnerName = nil

		if timer <= 0 or #currentPlayers < (if devMatch then 1 else requiredPlayers) then
			isMatchOver = true
			if #alivePlayersInArena == 1 and npcsAliveCount == 0 then winnerName = alivePlayersInArena[1].Name end
		elseif totalAliveInArena <= 1 then
			isMatchOver = true
			if #alivePlayersInArena == 1 then winnerName = alivePlayersInArena[1].Name end
		end

		if isMatchOver then
			matchResolved = true
			-- [Ranks] Resolve trophies BEFORE the celebration wait: during those 5 s
			-- players can still fall or leave, and that must not change the result.
			-- Survivors who didn't win (timer ran out) get a draw.
			local matchWinner = if winnerName then Players:FindFirstChild(winnerName) else nil
			for _, p in ipairs(alivePlayersInArena) do
				RanksService.ApplyMatchResult(p, if p == matchWinner then 1 else nil, matchSize, matchId)
			end
			local finalListing = getResultListing()
			if matchWinner then
				table.insert(finalListing, createPlayerResult(matchWinner, 1))
				table.sort(finalListing, function(a, b)
					if a.Placement == b.Placement then
						return a.UserId < b.UserId
					end
					return a.Placement < b.Placement
				end)
			end
			MatchEndKOEvent:FireAllClients(winnerName, timer <= 0)
			for _ = 1, 50 do
				task.wait(0.1)
				if pendingDevArena then return end
			end
			for _, result in ipairs(finalListing) do
				if result.Placement <= 2 then
					local resultPlayer = Players:GetPlayerByUserId(result.UserId)
					if resultPlayer then
						local newRating = (PlayerData.Get(resultPlayer, "Trophies") :: number?) or 0
						local oldRating = newRating
							- ((PlayerData.Get(resultPlayer, "MatchTrophyDelta") :: number?) or 0)
						ShowResultEvent:FireClient(resultPlayer, result.Placement, finalListing, 0, oldRating, newRating)
					end
				end
			end
			setState("Intermission")
			if winnerName then
				local winner = Players:FindFirstChild(winnerName)
				processWinner(winner)
				givePlacementReward(winner, 1)

				-- INVIA I DATI DELLA VITTORIA AL CLIENT
				--task.delay(0.5, function()
				--	ShowMatchSummaryEvent:FireClient(winner, {
				--		Result = "Win",
				--		Kills = winner:GetAttribute("MatchKills") or 0,
				--		Lives = winner:GetAttribute("Lives") or 0,
				--		Hits = winner:GetAttribute("MatchHits") or 0,
				--		Studs = math.floor(winner:GetAttribute("MatchStuds") or 0),
				--		Trophies = winner:GetAttribute("MatchTrophyDelta") or 0, -- [Ranks]
				--	})
				--end)
			end
			
			UpdateGameStateEvent:FireAllClients("GameOver", alivePlayersInArena[1])

			local spawnedArena = Workspace:FindFirstChild(GameConfig.ArenaName)
			local arenaType = spawnedArena and spawnedArena:GetAttribute("ArenaType") or "None"

			if arenaType == "Destruction" then ArenaDestructionService.Stop()
			elseif arenaType == "Shrink" then ArenaShrinkService.Stop()
			elseif arenaType == "Falling" then ArenaFallingService.Stop() end

			clearArenaAssets()
			teleportPlayersToArea(currentPlayers, GameConfig.LobbyName, false)
			clearArenaMap()
			freezeArenaEntities(false)
			resetEliminationResults(#Players:GetPlayers())
			devMatch = false
		else
			UpdateGameStateEvent:FireAllClients("Playing", timer)
			timer -= 1
		end
	else
		UpdateGameStateEvent:FireAllClients("Playing", timer)
		if not ReplicatedValues.GetBoolean(ReplicatedStorage, "TimeStopActive") then
			timer -= 1
		end
	end
	
end

-- ==========================================
-- INIT
-- ==========================================
function MatchService.Init()
	if initialized then return end
	initialized = true
	VotingService:Setup()
	VotingService:Start()
	RagdollService.SetVoidHandler(MatchService.HandleVoid)

	-- [Ranks] Publish the initial match context (read by RanksService on player leave).
	ReplicatedValues.Set(ReplicatedStorage, "MatchId", matchId)
	ReplicatedValues.Set(ReplicatedStorage, "MatchSize", matchSize)
	setRemainingPlayers(#Players:GetPlayers())
	setState(currentState)

	setupLobbyBag()
	setupLobbyNPC()
	clearArenaMap()

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		if playerConnections[player] then
			playerConnections[player]:Disconnect()
			playerConnections[player] = nil
		end
		lastPositions[player.UserId] = nil
		if (currentState == "Starting" or currentState == "Playing") and PlayerData.Get(player, "IsOnArena") then
			setRemainingPlayers(remainingPlayers - 1)
		end
	end)
	for _, player in ipairs(Players:GetPlayers()) do setupPlayer(player) end

	task.spawn(function()
		while true do
			processZonesAndBounds()
			task.wait(0.2)
		end
	end)

	task.spawn(function()
		while true do
			if pendingDevArena then
				local arenaName = pendingDevArena
				pendingDevArena = nil
				devStarting = true
				local success, message = xpcall(startDevMatch, debug.traceback, arenaName)
				devStarting = false
				if not success then
					devMatch = false
					setState("Waiting")
					ReplicatedValues.Set(ReplicatedStorage, "LockAFK", false)
					warn("[MatchService] Developer match failed:", message)
				end
			else
				updateMatchState()
			end
			if pendingDevArena then continue end
			wakeRevision += 1
			local revision = wakeRevision
			task.delay(1, function()
				if wakeRevision == revision then matchWake:Fire() end
			end)
			matchWake.Event:Wait()
		end
	end)
end

return MatchService
