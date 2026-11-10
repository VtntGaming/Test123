--!native
--!optimize 2
-- Runs arena matches, enforces void/arena bounds, and applies placement rewards and daily win progress.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
local Monetization = require(ServerScriptService.Services.AnalyticsService.Monetization)

local MatchService = {}
local initialized = false
local BotService = require(script.Parent.BotService)
local BotConfig = require(script.Parent.Helper.BotConfig)
local LobbyNPCService = require(script.Parent:WaitForChild("LobbyNPCService"))
local playerConnections = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ArenaLighting = require(script.Parent.Helper.ArenaLighting)
local arenaLighting = ArenaLighting.new(Lighting)

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local LeagueConfig = require(SharedModules:WaitForChild("LeagueConfig"))
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
	local newUses = (player:GetAttribute(attrName) or 0) + 1
	player:SetAttribute(attrName, newUses)

	local currentPref = player:GetAttribute(prefAttr)
	if currentPref ~= currentEq and newUses > (currentPref and player:GetAttribute(prefix .. currentPref) or 0) then
		player:SetAttribute(prefAttr, currentEq)
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
local matchNPCCount = 0
local eliminatedArenaNPCCount = 0
local remainingPlayers = 0
local eliminatedPlayers = {}

-- ==========================================
-- MATCH IDENTITY & STATE (Ranks)
-- ==========================================

local function incrementGamesPlayed(player)
	player:SetAttribute("GamesPlayed", (player:GetAttribute("GamesPlayed") or 0) + 1)
end

local function isUnranked(player)
	return (player:GetAttribute("GamesPlayed") or 0) < LeagueConfig.GamesPlayedRequirement
end

local function getDisplayedRatings(player, oldRating, newRating)
	local gamesPlayed = player:GetAttribute("GamesPlayed") or 0
	if gamesPlayed < LeagueConfig.GamesPlayedRequirement then
		return 0, 0, true
	end

	if gamesPlayed == LeagueConfig.GamesPlayedRequirement then
		return 0, newRating, false
	end

	return oldRating, newRating, false
end

local function setRemainingPlayers(count)
	remainingPlayers = math.max(0, count)
	ReplicatedStorage:SetAttribute("RemainingPlayers", remainingPlayers)
end

local function countPlayersOnArena()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("IsOnArena") then
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
	return math.max(count, matchNPCCount - eliminatedArenaNPCCount)
end

local function countAliveParticipants()
	return countPlayersOnArena() + countAliveNPCs()
end

local function resetEliminationResults(participantCount)
	table.clear(eliminatedPlayers)
	setRemainingPlayers(participantCount)
end

local function createPlayerResult(player, placement)
	local unranked = isUnranked(player)
	return {
		UserId = player.UserId,
		Name = player.Name,
		Icon = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=48&h=48`,
		Placement = placement,
		RankRating = if unranked then 0 else LeagueUtil.GetLeagueIndex(player:GetAttribute("Trophies") or 0),
		RatingChange = if unranked then 0 else player:GetAttribute("MatchTrophyDelta") or 0,
		IsUnranked = unranked,
	}
end

local function createBotResult(bot: Model, placement: number)
	local userId = bot:GetAttribute("UserId")
	local trophies = bot:GetAttribute("Trophies") or 0
	local unranked = (bot:GetAttribute("GamesPlayed") or 0) < LeagueConfig.GamesPlayedRequirement
	local newTrophies = trophies
	if not unranked and matchSize >= LeagueConfig.MinPlayersForTrophies then
		newTrophies = math.max(0, trophies + RanksService.ComputeDelta(trophies, placement, matchSize))
	end
	local ratingChange = newTrophies - trophies

	return {
		UserId = if type(userId) == "number" then userId else 0,
		Name = bot:GetAttribute("Username") or bot.Name,
		Icon = if type(userId) == "number"
			then `rbxthumb://type=AvatarHeadShot&id={userId}&w=48&h=48`
			else "",
		Placement = placement,
		RankRating = if unranked then 0 else LeagueUtil.GetLeagueIndex(newTrophies),
		RatingChange = if unranked then 0 else ratingChange,
		IsUnranked = unranked,
		IsBot = true,
	}
end

local function getResultListing()
	local listing = table.clone(eliminatedPlayers)
	table.sort(listing, function(a, b)
		if a.Placement == b.Placement then
			if a.UserId == b.UserId then
				return a.Name < b.Name
			end
			return a.UserId < b.UserId
		end
		return a.Placement < b.Placement
	end)
	return listing
end

-- Single writer of currentState: also publishes it so RanksService can tell
-- whether a leaving player was mid-match (no require cycle needed).
local function setState(newState)
	if newState ~= currentState then
		if newState == "Intermission" then
			if currentState == "Waiting" then
				timer = GameConfig.VoteTime
			else
				timer = GameConfig.IntermissionTime + GameConfig.VoteTime
			end
			-- Keep votes cast during the match (or before dropping to Waiting).
			-- Only start a fresh pool if voting was closed (e.g. a failed Preparing).
			if not VotingService:IsOpen() then
				VotingService:Reset()
			end
			VotingService:SetVoteDeadline(timer)
		elseif newState == "Waiting" and VotingService:IsOpen() then
			-- Not enough players: keep votes, remove the countdown.
			VotingService:OpenVoting()
		end
	end

	currentState = newState
	ReplicatedStorage:SetAttribute("MatchState", newState)
end

-- Called right before the arena teleport. Size only counts players still in the game.
local function beginMatch(participants, arenaNPCCount: number?) --98548063446402
	matchId += 1
	matchResolved = false
	matchNPCCount = arenaNPCCount or 0
	eliminatedArenaNPCCount = 0
	local size = 0
	for _, player in ipairs(participants) do
		if player.Parent == Players then
			size += 1
			player:SetAttribute("MatchId", matchId)
		end
	end
	matchSize = size + (arenaNPCCount or 0)
	resetEliminationResults(matchSize)
	for _, player in ipairs(participants) do
		if player.Parent == Players then
			player:SetAttribute("MatchTrophyDelta", 0)
			player:SetAttribute("MatchCoinsEarned", 0)
		end
	end
	ReplicatedStorage:SetAttribute("MatchId", matchId)
	ReplicatedStorage:SetAttribute("MatchSize", matchSize)
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

-- Bot version of the player spawn protection: same Duration/Transparency, IsInvulnerable on the model
-- (RagdollService.ApplyHit rejects hits on it). Re-applying keeps the ORIGINAL transparencies.
local botSpawnShield = setmetatable({}, { __mode = "k" })
local function applyBotInvulnerability(npc)
	local cfg = AbilityConfig.Abilities.SpawnInvulnerability
	local prev = botSpawnShield[npc]
	local saved = if prev then prev.saved else {}
	local token = { saved = saved }
	botSpawnShield[npc] = token
	for _, d in npc:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			if saved[d] == nil then saved[d] = d.Transparency end
			d.Transparency = math.max(saved[d], cfg.Transparency)
		end
	end
	npc:SetAttribute("IsInvulnerable", true)
	task.delay(cfg.Duration, function()
		if botSpawnShield[npc] ~= token then return end
		botSpawnShield[npc] = nil
		if not npc.Parent then return end
		npc:SetAttribute("IsInvulnerable", nil)
		for d, t in saved do
			if d.Parent then d.Transparency = t end
		end
	end)
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
	local targetArenaName = ReplicatedStorage:GetAttribute("NextArena") or "DefaultArena"
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
	actor:SetAttribute("IsFrozen", frozen)
	if player then player:SetAttribute("IsFrozen", frozen) end
	local hum = actor:FindFirstChildOfClass("Humanoid")
	if frozen then
		CombatService.CancelActor(actor)
		if player then CombatService.CancelAbilities(player, actor) end
	end
	if hum then
		hum.UseJumpPower = false
		hum.WalkSpeed = if frozen then 0 else GameConfig.Movement.WalkSpeed
		hum.JumpHeight = if frozen then 0 else GameConfig.Movement.JumpHeight
		hum.JumpPower = if frozen then 0 else 50
		hum.Jump = false
	end
end

local function freezeArenaEntities(isFrozen)
	for _, player in Players:GetPlayers() do
		if player.Character and player:GetAttribute("IsOnArena") then setFrozen(player.Character, player, isFrozen) end
	end
	for _, npc in CollectionService:GetTagged("ArenaNPC") do setFrozen(npc, nil, isFrozen) end
end

-- Knockback releases all of its ownership before a teleport; normal movement
-- statistics never count the teleport as traveled distance.
local function relocate(entity, destination, reason)
	arenaOutsideSince[entity] = nil
	local player = if entity:IsA("Model") then Players:GetPlayerFromCharacter(entity) else nil
	CombatService.CancelActor(entity)
	if player then CombatService.CancelAbilities(player, entity); lastPositions[player.UserId] = nil end
	RagdollService.Cancel(entity, reason or "Teleport", destination)
	entity:PivotTo(destination)
	local root = if entity:IsA("BasePart") then entity else entity:FindFirstChild("HumanoidRootPart") or entity.PrimaryPart
	if root then root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero end
	entity:SetAttribute("LastHitBy", nil)
end


-- Drops a player from the sky to groundCF. Anchored during the fall so physics,
-- ragdoll and void checks can't interfere. Cancelled if the teleport is superseded.
local function dropIn(player, char, groundCF, teleportRevision)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum then return end

	relocate(char, groundCF + Vector3.new(0, ARENA_DROP_HEIGHT, 0), "MatchTeleport")
	hrp.Anchored = true
	player:SetAttribute("ArenaDropping", true)
	--ArenaDropEvent:FireClient(player, "Start", ARENA_DROP_TIME)

	local startCF = hrp.CFrame
	local t = 0
	local conn
	local function finish(landed)
		if conn then conn:Disconnect() end
		if hrp.Parent then hrp.Anchored = false end
		if player:GetAttribute("ArenaDropping") then player:SetAttribute("ArenaDropping", nil) end
		lastPositions[player.UserId] = nil
		if player.Parent == Players then
			ArenaDropEvent:FireClient(player, if landed then "Land" else "Cancel")
		end
	end

	conn = RunService.Heartbeat:Connect(function(dt)
		if player.Parent ~= Players or player.Character ~= char or not char.Parent or hum.Health <= 0
			or player:GetAttribute("TeleportRevision") ~= teleportRevision then
			return finish(false)
		end
		t += dt
		local alpha = math.clamp(t / ARENA_DROP_TIME, 0, 1)
		char:PivotTo(startCF:Lerp(groundCF, alpha * alpha)) -- ease-in = gravity feel
		if alpha >= 1 then finish(true) end
	end)
end

-- LobbyNPCService.AssignToArena puts bots straight onto the arena (NPCEntity.MoveToArena). Left like that they stand /
-- fall in the arena for ~0.6s before the drop-in starts, so they look like they were "just there" and never drop in.
-- stageBotsForDrop lifts them (anchored) to the drop height in the same frame they are assigned and remembers the floor
-- point; dropInBots then plays the same fall + landing clip players get. Nobody ever sees a bot on the floor first.
local pendingBotDrops: { [Model]: CFrame } = {}

local function findBotGroundCF(npc: Model): CFrame
	local pivot = npc:GetPivot()
	local root = npc:FindFirstChild("HumanoidRootPart")
	local hum = npc:FindFirstChildOfClass("Humanoid")
	local ignore: { Instance } = {}
	for _, actor in CollectionService:GetTagged("BotActor") do table.insert(ignore, actor) end
	for _, player in Players:GetPlayers() do
		if player.Character then table.insert(ignore, player.Character) end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true -- same surfaces a walking bot would stand on
	local hit = Workspace:Raycast(pivot.Position + Vector3.new(0, 3, 0), Vector3.new(0, -120, 0), params)
	if not hit or not root or not hum then return pivot end
	-- resting height of the root above the floor = HipHeight + half the root's height (+0.1 keeps the feet out of the floor)
	local restHeight = hum.HipHeight + root.Size.Y * 0.5 + 0.1
	return CFrame.new(hit.Position + Vector3.new(0, restHeight, 0)) * pivot.Rotation
end

local function stageBotsForDrop()
	for _, npc in CollectionService:GetTagged("BotActor") do
		local root = npc:FindFirstChild("HumanoidRootPart")
		if not root or not npc:HasTag("ArenaNPC") or root.Anchored or BotService.IsDropping(npc) or pendingBotDrops[npc] then continue end
		local groundCF = findBotGroundCF(npc)
		pendingBotDrops[npc] = groundCF
		relocate(npc, groundCF + Vector3.new(0, ARENA_DROP_HEIGHT, 0), "MatchTeleport")
		root.Anchored = true
	end
end

-- Bots drop in exactly like players (same height, time, easing, 0.25s delay), then play the landing clip.
local function dropInBots()
	for npc, groundCF in pendingBotDrops do
		pendingBotDrops[npc] = nil
		task.delay(0.25, function()
			local root = npc:FindFirstChild("HumanoidRootPart")
			if not npc.Parent or not root then return end
			local startCF, t, conn = npc:GetPivot(), 0, nil
			conn = RunService.Heartbeat:Connect(function(dt)
				if not npc.Parent or not root.Parent then conn:Disconnect() return end
				t += dt
				local alpha = math.clamp(t / ARENA_DROP_TIME, 0, 1)
				npc:PivotTo(startCF:Lerp(groundCF, alpha * alpha))
				if alpha >= 1 then
					conn:Disconnect()
					root.Anchored = false
					root.AssemblyLinearVelocity = Vector3.zero
					BotService.PlayLanding(npc)
				end
			end)
		end)
	end
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
		return MAX_LIVES + if player:GetAttribute(PassesConfig.VIP.Attribute) then PassesConfig.VIP.Benefits.ExtraLives else 0
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
		local teleportRevision = (player:GetAttribute("TeleportRevision") or 0) + 1
		player:SetAttribute("TeleportRevision", teleportRevision)
		player:SetAttribute("TeleportingActive", true)
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
				setFrozen(placedCharacter, player, true)
				task.delay(0.25, function()
					dropIn(player, placedCharacter, destination, teleportRevision)
				end)
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
		player:SetAttribute("IsOnArena", isGoingToArena)
		player:SetAttribute("Lives", getMaxLives(player))

		if isGoingToArena then
			incrementGamesPlayed(player)
			updateUsageAndPreferred(player, "UseW_", player:GetAttribute("EquippedBaseWeapon"), "PreferredWeapon")
			updateUsageAndPreferred(player, "UseA_", player:GetAttribute("EquippedAbility"), "PreferredAbility")

			player:SetAttribute("CarriedChests", "")
			player:SetAttribute("MatchKills", 0)
			player:SetAttribute("MatchHits", 0)
			player:SetAttribute("MatchStuds", 0)
		end

		task.spawn(function()
			if player.Parent ~= Players or player:GetAttribute("TeleportRevision") ~= teleportRevision then return end
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")

			if not char or not char.Parent or not char:FindFirstChild("HumanoidRootPart") or (hum and hum.Health <= 0) then
				local loaded = pcall(function()
					player:LoadCharacter()
				end)
				if not loaded or player.Parent ~= Players then
					if player:GetAttribute("TeleportRevision") == teleportRevision then player:SetAttribute("TeleportingActive", nil) end
					return
				end
				char = player.Character
			end
			if not char then
				if player:GetAttribute("TeleportRevision") == teleportRevision then player:SetAttribute("TeleportingActive", nil) end
				return
			end

			local hrp = char:WaitForChild("HumanoidRootPart", 5)
			local newHum = char:WaitForChild("Humanoid", 5)
			task.wait(0.1)

			if char and hrp and newHum and player.Parent == Players and player.Character == char
				and player:GetAttribute("TeleportRevision") == teleportRevision then
				if char ~= placedCharacter or char:GetAttribute("RagdollGeneration") ~= placedGeneration then
					if char ~= placedCharacter or char:GetAttribute("RagdollGeneration") ~= placedGeneration then
						if isGoingToArena and freezeOnArrival == true then
							setFrozen(char, player, true)
							dropIn(player, char, destination, teleportRevision)
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
			if player:GetAttribute("TeleportRevision") == teleportRevision then player:SetAttribute("TeleportingActive", nil) end
		end)
	end
end

local function getReadyPlayers()
	local readyPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("DataLoaded") == true
			and not player:GetAttribute("IsAFK")
		then
			table.insert(readyPlayers, player)
		end
	end
	return readyPlayers
end

-- True when real players are on the server but every one of them is AFK: the bots keep playing among themselves.
local function botsShouldPlayAlone(): boolean
	local loaded = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("DataLoaded") == true then
			if not player:GetAttribute("IsAFK") then return false end
			loaded += 1
		end
	end
	return loaded > 0
end

local function onCharacterAdded(player, char)
	local hrp = char:WaitForChild("HumanoidRootPart", 5)
	local hum = char:WaitForChild("Humanoid", 5)
	task.wait(0.1)

	if not hrp or not hum or player.Character ~= char or player:GetAttribute("TeleportingActive") then return end

	if player:GetAttribute("IsOnArena") then
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
	CollectionService:AddTag(lobbyNPC, "TraningNPC")
	lobbyNPC.Parent = Workspace
end

local function clearArenaAssets()
	LobbyNPCService.ReturnArenaNPCs()
	BotService.ClearBots() -- also cancels bots that are still loading their avatar
	for _, npc in ipairs(spawnedNPCs) do
		if npc and npc.Parent and not LobbyNPCService.Owns(npc) then
			npc:Destroy()
		end
	end
	table.clear(spawnedNPCs)
	matchNPCCount = 0
	eliminatedArenaNPCCount = 0
end

local function spawnArenaNPCs()
	local spawnPart = getSpawnLocation(GameConfig.ArenaName)
	if not spawnPart then return 0 end

	local npcCapacity = LobbyNPCService.GetNPCSlots()
	-- bot-only match (everyone AFK): at least 2 bots, otherwise the match would end instantly
	local assignedCount = LobbyNPCService.AssignToArena(spawnPart, spawnedNPCs, if botsShouldPlayAlone() then 2 else nil)
	if assignedCount > 0 or npcCapacity <= 0 then return assignedCount end

	-- Solo match: human-like bots (BotConfig.BotsWhenSolo) replace the plain noob NPCs
	if BotConfig.Enabled and (BotConfig.BotsWhenSolo or 0) > 0 then
		return BotService.SpawnArenaBots(spawnPart, spawnedNPCs, 6)
	end

	local numNPCs = math.min(GameConfig.NPCsToSpawn or 3, npcCapacity)
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
	return numNPCs
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
		player:SetAttribute("MatchCoinsEarned", (player:GetAttribute("MatchCoinsEarned") or 0) + amount)
		local context = if player:GetAttribute("Has2xCoins") == true then "2xApplied" else "2xNotApplied"
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = amount, Balance = balance,
			TransactionType = "Gameplay", ItemSku = "Placement:" .. tostring(rank), Activity = "PlacementReward", Context = context,
		})
		AnalyticsService.RecordCustom(player, Monetization.VipBonus(player, vipBonus, "PlacementReward", context))
	end
end

local function grantDelayedCoinsSecurely(targetPlayer: Player, amount: number, activity: string)
	local rewardMatchId = matchId
	for i = 1, amount do
		task.delay(i * CoinRewardsConfig.KillDripInterval, function()
			if targetPlayer and targetPlayer.Parent then
				local awarded, balance, vipBonus = CoinsUtil:GiveCoins(targetPlayer, 1)
				if targetPlayer:GetAttribute("MatchId") == rewardMatchId then
					targetPlayer:SetAttribute("MatchCoinsEarned", (targetPlayer:GetAttribute("MatchCoinsEarned") or 0) + awarded)
				end
				AnalyticsService.RecordEconomy(targetPlayer, {
					Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = awarded, Balance = balance,
					TransactionType = "Gameplay", ItemSku = activity, Activity = activity, Context = "2xNotApplied",
				})
				AnalyticsService.RecordCustom(targetPlayer, Monetization.VipBonus(targetPlayer, vipBonus, activity, "2xNotApplied"))
			end
		end)
	end
end

local function getMatchCoinBalances(player: Player): (number, number)
	local newCoins = player:GetAttribute("Coins") or 0
	local earnedCoins = player:GetAttribute("MatchCoinsEarned") or 0
	return newCoins - earnedCoins, newCoins
end

local function processEntityKillRewards(entity, fallPos: Vector3)
	local lastHitterName = entity:GetAttribute("LastHitBy")
	if not lastHitterName then return end

	local hitter = Players:FindFirstChild(lastHitterName)
	local isSelfKill = (entity:IsA("Model") and Players:GetPlayerFromCharacter(entity) == hitter)

	if hitter and not isSelfKill then
		if entity:HasTag("TrainingBag") then
			hitter:SetAttribute("BagScore", (hitter:GetAttribute("BagScore") or 0) + 1)
		elseif not entity:HasTag("TraningNPC") then
			local victim = Players:GetPlayerFromCharacter(entity)
			if CoinRewardsConfig.ArenaKillsOnly and victim and not victim:GetAttribute("IsOnArena") then
				entity:SetAttribute("LastHitBy", nil)
				return
			end
			hitter:SetAttribute("Kills", (hitter:GetAttribute("Kills") or 0) + 1)
			hitter:SetAttribute("MatchKills", (hitter:GetAttribute("MatchKills") or 0) + 1)

			grantDelayedCoinsSecurely(hitter, if victim then CoinRewardsConfig.KillPlayer else CoinRewardsConfig.KillNPC, if victim then "PlayerKill" else "NPCKill")
			SpawnVisualCoinsEvent:FireAllClients(fallPos, hitter)
		end
	end
	entity:SetAttribute("LastHitBy", nil)
end

local function processWinner(winnerPlayer)
	if not winnerPlayer then return end
	winnerPlayer:SetAttribute("Wins", (winnerPlayer:GetAttribute("Wins") or 0) + 1)
	winnerPlayer:SetAttribute("Wins_Day", (winnerPlayer:GetAttribute("Wins_Day") or 0) + 1)
	winnerPlayer:SetAttribute("Wins_Week", (winnerPlayer:GetAttribute("Wins_Week") or 0) + 1)
	winnerPlayer:SetAttribute("Wins_Month", (winnerPlayer:GetAttribute("Wins_Month") or 0) + 1)
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

-- Last life lost: placement, coins and trophies; the complete result is shown when the match resolves.
local function eliminatePlayer(player, entity)
	-- rank = finishing position: players still on the arena (self included) + living arena NPCs.
	-- rank 1 only happens when the last two players fall in the same tick; it counts as a win.
	local rank = countPlayersOnArena() + countAliveNPCs()
	givePlacementReward(player, rank)

	RanksService.ApplyMatchResult(player, rank, matchSize, matchId) -- idempotent per match
	table.insert(eliminatedPlayers, 1, createPlayerResult(player, rank))

	if rank ~= 1 then
		PlayLoserSoundEvent:FireClient(player)
	end

	player:SetAttribute("IsOnArena", false)
	setRemainingPlayers(countAliveParticipants())

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
	local onArena = (player ~= nil and player:GetAttribute("IsOnArena") == true) or entity:HasTag("ArenaNPC")
	local locked = matchResolved and onArena

	if locked then
		entity:SetAttribute("LastHitBy", nil)
	else
		processEntityKillRewards(entity, fallPosNormalize)
	end

	local eliminated = false -- [KO] true when this entity just lost its LAST life
	local lifeLost = false -- true only when a life was actually removed (drives the CrowdCheer sound)

	if player then
		if not player:GetAttribute("IsOnArena") then
			player:SetAttribute("Deaths", (player:GetAttribute("Deaths") or 0) + 1)
			resetEntityPosition(entity, GameConfig.LobbyName)
		elseif locked then
			resetEntityPosition(entity, GameConfig.ArenaName)
			applyInvulnerability(player)
		else
			player:SetAttribute("Deaths", (player:GetAttribute("Deaths") or 0) + 1)
			local lives = math.max(0, (player:GetAttribute("Lives") or getMaxLives(player)) - 1)
			player:SetAttribute("Lives", lives)
			lifeLost = true
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

	elseif entity:HasTag("TraningNPC") then
		relocate(entity, LOBBY_NPC_CFRAME, "TrainerVoid")
		setFrozen(entity, nil, false)

	elseif entity:HasTag("ArenaNPC") then
		if locked then
			resetEntityPosition(entity, GameConfig.ArenaName)
			applyBotInvulnerability(entity)
		else
			local lives = math.max(0, (entity:GetAttribute("Lives") or getMaxLives()) - 1)
			entity:SetAttribute("Lives", lives)
			lifeLost = true
			if lives == 0 then
				eliminated = true
				CombatService.CancelActor(entity)
				RagdollService.Cancel(entity, "Eliminated")
				eliminatedArenaNPCCount += 1
				table.insert(eliminatedPlayers, 1, createBotResult(entity, countAliveParticipants() + 1))
				entity:Destroy()
				setRemainingPlayers(countAliveParticipants())
			else
				resetEntityPosition(entity, GameConfig.ArenaName)
				applyBotInvulnerability(entity)
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
	-- 4th = name of the player who lost the life (nil for NPCs), 5th = a life was really lost.
	-- Clients use these to play CrowdCheer only for the attacker and the victim.
	KOEvent:FireAllClients(fallPosNormalize + Vector3.yAxis * 60, isDecidingKO, killerName, if player then player.Name else nil, lifeLost)
end

-- Shared KO credit / lives path for void crossings and the arena outside timeout.
local function handleVoidLoss(entity: Instance, fallPos: Vector3)
	if not entity or not entity.Parent or resolvingVoid[entity] then return end
	local player = if entity:IsA("Model") then Players:GetPlayerFromCharacter(entity) else nil
	if player and player:GetAttribute("TeleportingActive") then return end
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
	if fallPos.Y >= GameConfig.VoidHeight and fallPos.Y <= GameConfig.SkyHeight then return end
	-- Shadow Clones are disposable: a clone knocked into the void just pops (no lives / KO / respawn logic).
	if entity:HasTag("ShadowClone") then
		pcall(RagdollService.Cancel, entity, "Void")
		entity:Destroy()
		return
	end
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
		if not root or player:GetAttribute("TeleportingActive") or player:GetAttribute("ArenaDropping") then
			arenaOutsideSince[character] = nil
			continue
		end
		local position = RagdollService.GetAuthoritativePosition(character) or root.Position
		if player:GetAttribute("IsOnArena") then
			local last = lastPositions[player.UserId]
			if last then
				-- Total travel includes knockback. Relocate clears history before teleports.
				player:SetAttribute("MatchStuds", (player:GetAttribute("MatchStuds") or 0) + (position - last).Magnitude)
			end
			lastPositions[player.UserId] = position
		else lastPositions[player.UserId] = nil end
		if not math.isfinite(position.Y) or position.Y < GameConfig.VoidHeight or position.Y > GameConfig.SkyHeight then
			MatchService.HandleVoid(character, position)
			position = RagdollService.GetAuthoritativePosition(character) or root.Position
		else
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if player:GetAttribute("IsOnArena") == true and arenaFrame and arenaHalfSize
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
		if not player:GetAttribute("IsOnArena") then
			for _, area in trainingAreas do if isPointInPart(position, area) then training = true; break end end
		end
		if player:GetAttribute("IsInTrainingArea") ~= training then player:SetAttribute("IsInTrainingArea", training) end
	end
	
	for _, tag in { "TrainingBag", "TraningNPC", "ArenaNPC" } do
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
			if not math.isfinite(position.Y) or position.Y < GameConfig.VoidHeight or position.Y > GameConfig.SkyHeight then
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
			elseif tag == "TraningNPC" then
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
	ReplicatedStorage:SetAttribute("NextArena", arenaName)
end

local function startPlaying()
	setState("Playing")
	VotingService:Reset()      -- new map pool for the NEXT match
	VotingService:OpenVoting() -- open for the whole match, no countdown
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
	ReplicatedStorage:SetAttribute("LockAFK", true)
	ArenaDestructionService.Stop()
	ArenaShrinkService.Stop()
	ArenaFallingService.Stop()
	local previousPlayers = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("IsOnArena") then table.insert(previousPlayers, player) end
	end
	teleportPlayersToArea(previousPlayers, GameConfig.LobbyName, false)
	clearArenaAssets()
	ReplicatedStorage:SetAttribute("NextArena", arenaName)
	if not spawnArenaMap() then
		devMatch = false
		setState("Waiting")
		ReplicatedStorage:SetAttribute("LockAFK", false)
		return
	end
	local participants = getReadyPlayers()
	if #participants == 0 then
		clearArenaMap()
		devMatch = false
		setState("Waiting")
		ReplicatedStorage:SetAttribute("LockAFK", false)
		return
	end
	devMatch = true
	local arenaNPCCount = spawnArenaNPCs()
		--if #participants == 1 then spawnArenaNPCs() else 0
	beginMatch(participants, arenaNPCCount)
	teleportPlayersToArea(participants, GameConfig.ArenaName, false)
	startPlaying()
	ReplicatedStorage:SetAttribute("LockAFK", false)
end

local function updateMatchState()
	local currentPlayers = getReadyPlayers()
	local requiredPlayers = RunService:IsStudio() and GameConfig.MinPlayersToStartStudio or GameConfig.MinPlayersToStart
	local botsOnly = botsShouldPlayAlone()
	local enoughPlayers = #currentPlayers >= requiredPlayers or botsOnly -- all-AFK players no longer stop the game

	local alivePlayersInArena = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p:GetAttribute("IsOnArena") then table.insert(alivePlayersInArena, p) end
	end

	local npcsAliveCount = 0
	for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
		if npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then npcsAliveCount += 1 end
	end
	local totalAliveInArena = #alivePlayersInArena + npcsAliveCount

	if currentState == "Waiting" then
		ReplicatedStorage:SetAttribute("LockAFK", false)

		if enoughPlayers then
			setState("Intermission")
		else
			UpdateGameStateEvent:FireAllClients("Waiting", 0)
		end

	elseif currentState == "Intermission" then
		ReplicatedStorage:SetAttribute("LockAFK", false)

		if not enoughPlayers then
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
		ReplicatedStorage:SetAttribute("LockAFK", timer <= 5)

		if timer <= 0 then
			if not enoughPlayers then
				ReplicatedStorage:SetAttribute("LockAFK", false)
				clearArenaAssets()
				clearArenaMap()
				setState("Waiting")
				UpdateGameStateEvent:FireAllClients("Waiting", 0)
			else
				devMatch = false
				local arenaNPCCount = spawnArenaNPCs()
				stageBotsForDrop() -- lift lobby bots into the sky now, before they can be seen standing on the arena floor
					--if #currentPlayers == 1 then spawnArenaNPCs() else 0
				beginMatch(currentPlayers, arenaNPCCount) -- [Ranks]

				task.wait(0.35)
				dropInBots()
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
		ReplicatedStorage:SetAttribute("LockAFK", true)
		UpdateGameStateEvent:FireAllClients("Starting", timer)

		if timer < 0 then
			startPlaying()
		else
			timer -= 1
		end

	elseif currentState == "Playing" then
		
		ReplicatedStorage:SetAttribute("LockAFK", false)

		local isMatchOver = false
		local winnerName = nil

		if timer <= 0 or (#currentPlayers < (if devMatch then 1 else requiredPlayers) and not botsOnly) then
			isMatchOver = true
			if #alivePlayersInArena == 1 and npcsAliveCount == 0 then winnerName = alivePlayersInArena[1].Name end
		elseif totalAliveInArena <= 1 then
			isMatchOver = true
			if #alivePlayersInArena == 1 then winnerName = alivePlayersInArena[1].Name end
		end

		-- A bot that is the last one standing wins the match (every player died or left): that is never a draw.
		local botWinner: Model? = nil
		local botWinnerName: string? = nil
		if isMatchOver and not winnerName and #alivePlayersInArena == 0 and npcsAliveCount == 1 then
			for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
				if npc:IsA("Model") and npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then
					botWinner = npc
					botWinnerName = npc:GetAttribute("Username") or npc.Name
					break
				end
			end
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
			local survivingActors = {}
			for _, player in ipairs(alivePlayersInArena) do
				if player.Parent == Players and player:GetAttribute("IsOnArena") then
					table.insert(survivingActors, {
						Model = player.Character,
						Player = player,
						Name = player.Name,
						UserId = player.UserId,
					})
				end
			end
			for _, npc in ipairs(CollectionService:GetTagged("ArenaNPC")) do
				if npc:IsA("Model") and npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then
					local userId = npc:GetAttribute("ArenaAppearanceUserId")
					table.insert(survivingActors, {
						Model = npc,
						Name = npc:GetAttribute("Username") or npc.Name,
						UserId = if type(userId) == "number" then userId else 0,
					})
				end
			end
			table.sort(survivingActors, function(a, b)
				if matchWinner and a.Player == matchWinner then return true end
				if matchWinner and b.Player == matchWinner then return false end
				if a.UserId == b.UserId then
					return a.Name < b.Name
				end
				return a.UserId < b.UserId
			end)
			for placement, actor in ipairs(survivingActors) do
				if actor.Player then
					table.insert(finalListing, createPlayerResult(actor.Player, placement))
				else
					table.insert(finalListing, createBotResult(actor.Model, placement))
				end
			end
			table.sort(finalListing, function(a, b)
				if a.Placement == b.Placement then
					if a.UserId == b.UserId then return a.Name < b.Name end
					return a.UserId < b.UserId
				end
				return a.Placement < b.Placement
			end)
			local function showFinalResults()
				for _, result in ipairs(finalListing) do
					if not result.IsBot then
						local resultPlayer = Players:GetPlayerByUserId(result.UserId)
						if resultPlayer and resultPlayer:GetAttribute("MatchId") == matchId then
							local newRating = resultPlayer:GetAttribute("Trophies") or 0
							local oldRating = newRating - (resultPlayer:GetAttribute("MatchTrophyDelta") or 0)
							local displayOldRating, displayNewRating, unranked = getDisplayedRatings(resultPlayer, oldRating, newRating)
							local oldCoins, newCoins = getMatchCoinBalances(resultPlayer)
							ShowResultEvent:FireClient(resultPlayer, result.Placement, finalListing, 0, displayOldRating, displayNewRating, oldCoins, newCoins, unranked)
						end
					end
				end
			end
			MatchEndKOEvent:FireAllClients(winnerName or botWinnerName, timer <= 0)
			for _ = 1, 50 do
				task.wait(0.1)
				if pendingDevArena then
					showFinalResults()
					return
				end
			end
			if matchWinner and matchWinner.Parent == Players then
				givePlacementReward(matchWinner, 1)
			end
			showFinalResults()
			setState("Intermission")
			if winnerName then
				local winner = Players:FindFirstChild(winnerName)
				processWinner(winner)

				-- INVIA I DATI DELLA VITTORIA AL CLIENT
				-- English: SEND THE VICTORY DATA TO THE CLIENT.
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
			
			-- Bots have no Player object: send {Name, Character} so the client can still announce and show the winner
			local gameOverWinner: any = alivePlayersInArena[1]
			if not gameOverWinner and botWinnerName then
				gameOverWinner = {
					Name = botWinnerName,
					Character = if botWinner and botWinner.Parent then botWinner else nil,
				}
			end
			UpdateGameStateEvent:FireAllClients("GameOver", gameOverWinner)

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
		if not ReplicatedStorage:GetAttribute("TimeStopActive") then timer -= 1 end	
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
	ReplicatedStorage:SetAttribute("MatchId", matchId)
	ReplicatedStorage:SetAttribute("MatchSize", matchSize)
	setRemainingPlayers(#Players:GetPlayers())
	setState(currentState)

	setupLobbyBag()
	setupLobbyNPC()
	clearArenaMap()

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		if playerConnections[player] then playerConnections[player]:Disconnect(); playerConnections[player] = nil end
		lastPositions[player.UserId] = nil
		if (currentState == "Starting" or currentState == "Playing") and player:GetAttribute("IsOnArena") then
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
					ReplicatedStorage:SetAttribute("LockAFK", false)
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
