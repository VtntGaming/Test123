--!strict

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Services = script.Parent.Parent
local NpcService = require(Services:WaitForChild("NpcService"))
local RagdollService = require(Services:WaitForChild("RagdollService"))
local CombatService = require(Services:WaitForChild("CombatService")) -- training swings use the same pipeline as every M1
local BotConfig = require(Services:WaitForChild("Helper"):WaitForChild("BotConfig"))
local BotAnimator = require(Services:WaitForChild("Helper"):WaitForChild("BotAnimator"))

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local NpcTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Npcs"):WaitForChild("Npc") :: Model
local Assets = ReplicatedStorage:WaitForChild("Assets")
local WeaponsFolder = Assets:WaitForChild("Weapons")
local NpcAttackEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("NpcAttackEvent")
local Lobby = Workspace:WaitForChild(GameConfig.LobbyName)
local LobbySpawn = Lobby:WaitForChild("Spawn") :: BasePart
local LobbyNPCFolder = Lobby:FindFirstChild("LobbyNPCs")

if not LobbyNPCFolder then
	LobbyNPCFolder = Instance.new("Folder")
	LobbyNPCFolder.Name = "LobbyNPCs"
	LobbyNPCFolder.Parent = Lobby
end

local RandomGenerator = Random.new()

export type ArenaAppearance = {
	Description: HumanoidDescription,
	Username: string,
	UserId: number,
	Trophies: number,
	GamesPlayed: number,
	HasVIP: boolean,
}

export type Profile = ArenaAppearance & {
	EquippedAbility: string,
	EquippedWeapon: string,
	EquippedWeaponSkin: string,
	Aggression: number,
}

export type NPCEntity = {
	Model: Model,
	Profile: Profile?,
	IsReady: boolean,
	IsInArena: boolean,
	IsDestroyed: boolean,
	WanderRevision: number,
	AnimationRevision: number,
	Animator: any?,
	Setup: (self: NPCEntity, profile: Profile, spawnCFrame: CFrame) -> (),
	Start: (self: NPCEntity) -> (),
	MoveToArena: (self: NPCEntity, targetCFrame: CFrame) -> boolean,
	ReturnToLobby: (self: NPCEntity) -> (),
	Destroy: (self: NPCEntity) -> (),
}

export type NPCEntityModule = {
	new: () -> NPCEntity,
	CreateProfile: () -> Profile,
	Setup: (self: NPCEntity, profile: Profile, spawnCFrame: CFrame) -> (),
	Start: (self: NPCEntity) -> (),
	MoveToArena: (self: NPCEntity, targetCFrame: CFrame) -> boolean,
	ReturnToLobby: (self: NPCEntity) -> (),
	Destroy: (self: NPCEntity) -> (),
}

local NPCEntity = {} :: NPCEntityModule

local function chooseRandomName(names: { string }): string
	return names[RandomGenerator:NextInteger(1, #names)]
end

local function chooseLobbyPoint(): CFrame
	local margin = 4
	local halfX = math.max(0, LobbySpawn.Size.X * 0.5 - margin)
	local halfZ = math.max(0, LobbySpawn.Size.Z * 0.5 - margin)
	local localPosition = Vector3.new(
		RandomGenerator:NextNumber(-halfX, halfX),
		LobbySpawn.Size.Y * 0.5 + 3,
		RandomGenerator:NextNumber(-halfZ, halfZ)
	)
	local position = LobbySpawn.CFrame:PointToWorldSpace(localPosition)
	return CFrame.new(position) * CFrame.Angles(0, RandomGenerator:NextNumber(0, math.pi * 2), 0)
end
-- inHand = false: the weapon sits on the bot's torso (lobby look). inHand = true: it is held in the right hand (training).
local function equipLobbyWeapon(model: Model, weaponName: string, inHand: boolean?)
	local template = WeaponsFolder:FindFirstChild(weaponName)
	if not template or not template:IsA("Model") then
		warn(`LobbyNPCService: missing weapon model {weaponName}`)
		return
	end

	local old = model:FindFirstChild("EquippedWeapon")
	if old then old:Destroy() end

	local hand: Instance? = if inHand then (model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")) else nil
	if hand and not hand:IsA("BasePart") then hand = nil end
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	if not hand and (not torso or not torso:IsA("BasePart")) then
		warn(`LobbyNPCService: cannot equip weapon {weaponName} on {model.Name}`)
		return
	end

	local weapon = template:Clone()
	local main = weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then
		warn(`LobbyNPCService: weapon {weaponName} has no Main part`)
		weapon:Destroy()
		return
	end

	weapon.Name = "EquippedWeapon"

	-- Safely extract the BaseName ("Slap", "Bat", etc.) so skins get the correct rotations
	local info = WeaponConfig.GetWeaponInfo(weaponName)
	local baseId = info and info.BaseName or "Bat"

	weapon:SetAttribute("WeaponId", baseId)
	-- In the hand (training) the weapon is set up exactly like an arena bot's weapon (BotService.equipBotWeapon):
	-- WeaponName is the base id and the skin is only remembered in BotSkinApplied.
	weapon:SetAttribute("WeaponName", if hand then baseId else weaponName)
	if hand then weapon:SetAttribute("BotSkinApplied", weaponName) end
	for _, part in weapon:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Massless = true
			part.Anchored = false
			if part ~= main then
				local assemblyWeld = Instance.new("WeldConstraint")
				assemblyWeld.Name = "WeaponAssembly"
				assemblyWeld.Part0 = main
				assemblyWeld.Part1 = part
				assemblyWeld.Parent = part
			end
		end
	end

	weapon.Parent = model

	if hand then
		-- held in the right hand, same placement as BotService.equipBotWeapon
		local handPart = hand :: BasePart
		weapon:PivotTo(handPart.CFrame)
		local handWeld = Instance.new("WeldConstraint")
		handWeld.Name = "WeaponWeld"
		handWeld.Part0 = handPart
		handWeld.Part1 = main
		handWeld.Parent = main
		model:SetAttribute("WeaponRevision", (model:GetAttribute("WeaponRevision") or 0) + 1)

		-- hit sounds (CombatService only plays them for arena bots, so the training loop plays them itself)
		local info = WeaponConfig.GetWeaponInfo(weaponName)
		if info then
			local sfxFolder = SoundService:FindFirstChild("SFX")
			local soundTemplate = sfxFolder and info.HitSound and sfxFolder:FindFirstChild(info.HitSound)
			if soundTemplate and soundTemplate:IsA("Sound") then
				local sound = soundTemplate:Clone()
				sound.Name = info.HitSound
				sound.Looped = false
				sound.Parent = main
			end
			local sfxAssets = Assets:FindFirstChild("SFX")
			local effectsLibrary = sfxAssets and sfxAssets:FindFirstChild("WeaponEffects")
			local effectTemplate = effectsLibrary and info.Variant and effectsLibrary:FindFirstChild(info.Variant)
			if effectTemplate and effectTemplate:IsA("Sound") then
				local sound = effectTemplate:Clone()
				sound.Name = "WeaponEffectHit"
				sound.Looped = false
				sound.Parent = main
			end
		end
		return
	end

	-- Use the exact same unequipped offsets that real players use in WeaponService
	local rotation = if baseId == "Slap"
		then CFrame.Angles(math.rad(90), 0, math.rad(90))
		else CFrame.Angles(math.rad(90), math.rad(-45), 0)

	main.CFrame = (torso :: BasePart).CFrame * CFrame.new(-0.5, -0.5, 1.1) * rotation

	local weaponWeld = Instance.new("WeldConstraint")
	weaponWeld.Name = "WeaponWeld"
	weaponWeld.Part0 = torso :: BasePart
	weaponWeld.Part1 = main
	weaponWeld.Parent = main
end


local function createFallbackAppearance(): ArenaAppearance
	local description = Instance.new("HumanoidDescription")
	local skinTone = Color3.fromRGB(
		RandomGenerator:NextInteger(124, 255),
		RandomGenerator:NextInteger(92, 205),
		RandomGenerator:NextInteger(70, 187)
	)
	local shirtColor = Color3.fromRGB(
		RandomGenerator:NextInteger(30, 230),
		RandomGenerator:NextInteger(30, 230),
		RandomGenerator:NextInteger(30, 230)
	)
	local pantsColor = Color3.fromRGB(
		RandomGenerator:NextInteger(30, 230),
		RandomGenerator:NextInteger(30, 230),
		RandomGenerator:NextInteger(30, 230)
	)
	description.HeadColor = skinTone
	description.LeftArmColor = skinTone
	description.RightArmColor = skinTone
	description.TorsoColor = shirtColor
	description.LeftLegColor = pantsColor
	description.RightLegColor = pantsColor

	return {
		Description = description,
		Username = `LobbyGuest{RandomGenerator:NextInteger(10000, 99999)}`,
		Trophies = RandomGenerator:NextInteger(25, 2000),
		GamesPlayed = RandomGenerator:NextInteger(0, 100),
		HasVIP = RandomGenerator:NextNumber() < 0.1,
		UserId = 1
	}
end

-- ==========================================
-- LOBBY TRAINING
-- ==========================================
-- Lobby bots that wait for the next match sometimes walk to the Training Area and practise like real players: they hit the
-- punching bag (tag "TrainingBag") or the Lobby_Trainer / noob NPC (tag "TraningNPC") with their own weapon. The swing goes
-- through the SAME combat pipeline as every M1 and every arena bot (CombatService.BeginNpcAttack / ReleaseNpcAttack), so the
-- hit box, knockback and effects are identical. All settings are in BotConfig (Training*).
local TRAINING_TAGS = { "TrainingBag", "TraningNPC" }
local PATH_AGENT = { AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = false }
local baseWeapons: any = WeaponConfig.BaseWeapons
local trainingTotal = 0
local trainingPerTarget: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

-- true while this entity is still a living lobby bot and nobody (arena / return-to-lobby) took over its wander revision
local function isActive(self: NPCEntity, revision: number): boolean
	return not self.IsDestroyed and not self.IsInArena and self.Model.Parent ~= nil and self.WanderRevision == revision
end

-- "SlapFire" -> "Slap" (the profile may hold a skin name)
local function baseWeaponIdOf(profile: Profile): string
	for _, name in { profile.EquippedWeaponSkin, profile.EquippedWeapon } do
		local info = WeaponConfig.GetWeaponInfo(name)
		local baseId = info and info.BaseName
		if baseId and baseWeapons[baseId] then return baseId end
	end
	return "Slap"
end

local function targetPosition(target: Instance): Vector3?
	local position = RagdollService.GetAuthoritativePosition(target)
	if position then return position end
	if target:IsA("BasePart") then return target.Position end
	if target:IsA("Model") then return target:GetPivot().Position end
	return nil
end

local function targetRadius(target: Instance): number
	if target:IsA("BasePart") then return math.max(target.Size.X, target.Size.Z) * 0.5 end
	return 1.5 -- NPC rig
end

-- Picks a bag / trainer that still has a free training slot (BotConfig.TrainingMaxBots / TrainingMaxPerTarget).
local function claimTarget(): Instance?
	if trainingTotal >= (BotConfig.TrainingMaxBots or 4) then return nil end
	local perTargetLimit = BotConfig.TrainingMaxPerTarget or 2
	local candidates: { Instance } = {}
	for _, tag in TRAINING_TAGS do
		for _, instance in CollectionService:GetTagged(tag) do
			if instance:IsDescendantOf(Workspace) and (trainingPerTarget[instance] or 0) < perTargetLimit
				and targetPosition(instance) ~= nil then
				table.insert(candidates, instance)
			end
		end
	end
	if #candidates == 0 then return nil end
	local target = candidates[RandomGenerator:NextInteger(1, #candidates)]
	trainingTotal += 1
	trainingPerTarget[target] = (trainingPerTarget[target] or 0) + 1
	return target
end

local function releaseTarget(target: Instance)
	trainingTotal = math.max(0, trainingTotal - 1)
	local count = trainingPerTarget[target]
	if count then trainingPerTarget[target] = if count > 1 then count - 1 else nil end
end

-- Real ground below a point (ignores bots / the training dummies, so pathfinding gets a point that is on the floor).
local function groundPoint(position: Vector3, ignore: { Instance }): Vector3
	local exclude: { Instance } = {}
	if LobbyNPCFolder then table.insert(exclude, LobbyNPCFolder) end
	for _, instance in ignore do table.insert(exclude, instance) end
	for _, actor in CollectionService:GetTagged("CombatActor") do table.insert(exclude, actor) end
	local knockback = Workspace:FindFirstChild("KnockbackRuntime")
	if knockback then table.insert(exclude, knockback) end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true
	local result = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), params)
	return if result then result.Position else position
end

-- Walks to a point with PathfindingService (the Training Area is ~100+ studs away, with ledges to jump).
-- Returns true when the bot arrived; false when the path failed, the bot got stuck twice, ran out of time or lost its lobby state.
local function walkTo(self: NPCEntity, revision: number, goal: Vector3, timeout: number): boolean
	local model = self.Model
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then return false end
	local deadline = os.clock() + timeout

	for _ = 1, 2 do -- the second round is a re-plan after the bot got stuck
		if not isActive(self, revision) or os.clock() >= deadline then return false end
		local path = PathfindingService:CreatePath(PATH_AGENT)
		local planned = pcall(function() path:ComputeAsync(root.Position, goal) end)
		if not planned or path.Status ~= Enum.PathStatus.Success then return false end
		local waypoints = path:GetWaypoints()
		local stuck = false
		for index = 2, #waypoints do
			local waypoint = waypoints[index]
			if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
			humanoid:MoveTo(waypoint.Position)
			local lastPosition, lastProgressAt = root.Position, os.clock()
			while true do
				if not isActive(self, revision) or os.clock() >= deadline then return false end
				local flat = Vector3.new(waypoint.Position.X - root.Position.X, 0, waypoint.Position.Z - root.Position.Z).Magnitude
				if flat < 3 then break end
				if (root.Position - lastPosition).Magnitude > 1 then lastPosition, lastProgressAt = root.Position, os.clock() end
				if os.clock() - lastProgressAt > 2 then stuck = true; break end
				task.wait(0.1)
			end
			if stuck then break end
		end
		if not stuck then
			return Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z).Magnitude < 6
		end
	end
	return false
end

local function faceTarget(root: BasePart, position: Vector3)
	local aim = Vector3.new(position.X, root.Position.Y, position.Z)
	if (aim - root.Position).Magnitude > 0.05 then root.CFrame = CFrame.lookAt(root.Position, aim) end
end

local function playHitSound(model: Model, baseId: string)
	local weapon = model:FindFirstChild("EquippedWeapon")
	if not weapon then return end
	local info = baseWeapons[baseId]
	local sound = info and info.HitSound and weapon:FindFirstChild(info.HitSound, true)
	if sound and sound:IsA("Sound") then sound:Play() end
	if (WeaponConfig :: any).WeaponEffectSoundEnabled then
		local effectSound = weapon:FindFirstChild("WeaponEffectHit", true)
		if effectSound and effectSound:IsA("Sound") then effectSound:Play() end
	end
end

-- One training visit: walk next to the target, take the weapon in the hand, charge + release swings until the time is up.
local function trainSession(self: NPCEntity, revision: number, target: Instance, baseId: string)
	local model = self.Model
	local profile = self.Profile
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not profile or not humanoid or not root or not root:IsA("BasePart") then return end

	local info = baseWeapons[baseId]
	local attack = info and info.Attack
	local reach = 6 -- same reach formula as BotService.createState
	if attack and attack.HitboxSize and attack.HitboxOffset then
		reach = math.abs(attack.HitboxOffset.Z) + attack.HitboxSize.Z * 0.5
	end
	local cooldown: number = (info and info.Cooldown) or 1
	local radius = targetRadius(target)
	local standDistance = math.clamp(radius + 2.5, 3.5, reach * 0.85)

	local function flatDistanceTo(position: Vector3): number
		return Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z).Magnitude
	end

	-- a spot beside the target on the side the bot comes from (random angle, so two bots do not stand on top of each other)
	local function chooseStandPoint(): Vector3?
		local position = targetPosition(target)
		if not position then return nil end
		local away = Vector3.new(root.Position.X - position.X, 0, root.Position.Z - position.Z)
		local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.zAxis
		direction = CFrame.Angles(0, math.rad(RandomGenerator:NextNumber(-55, 55)), 0):VectorToWorldSpace(direction)
		local spot = position + direction * standDistance
		return groundPoint(Vector3.new(spot.X, position.Y, spot.Z), { target })
	end

	local standPoint = chooseStandPoint()
	if not standPoint then return end
	if not walkTo(self, revision, standPoint, BotConfig.TrainingWalkTimeout or 25) then return end
	if not isActive(self, revision) then return end

	-- arrived: weapon in the hand, "in training area" state like a real player
	equipLobbyWeapon(model, profile.EquippedWeaponSkin, true)
	model:SetAttribute("EquippedBaseWeapon", baseId)
	model:SetAttribute("IsInTrainingArea", true)

	local endsAt = os.clock() + RandomGenerator:NextNumber(BotConfig.TrainingMin or 8, BotConfig.TrainingMax or 18)
	while isActive(self, revision) and os.clock() < endsAt do
		local position = targetPosition(target)
		if not position or not target:IsDescendantOf(Workspace) then break end
		if flatDistanceTo(position) > standDistance + 2.5 or math.abs(position.Y - root.Position.Y) > 12 then
			-- the target got knocked away: walk after it, or stop when that fails
			local point = chooseStandPoint()
			if not point or not walkTo(self, revision, point, 10) then break end
			continue
		end

		humanoid:MoveTo(root.Position)
		faceTarget(root, position)
		local attackId = CombatService.BeginNpcAttack(model)
		if attackId then
			NpcAttackEvent:FireAllClients(model, baseId, "Charge")
			-- hold the swing for a moment like a player charging M1, and keep facing the target
			local releaseAt = os.clock() + RandomGenerator:NextNumber(BotConfig.ChargeMin or 0.3, BotConfig.ChargeMax or 1.1)
			while os.clock() < releaseAt and isActive(self, revision) do
				task.wait(0.05)
				local current = targetPosition(target)
				if current then faceTarget(root, current) end
			end
			if not isActive(self, revision) then return end -- MoveToArena / Destroy already cancelled the swing
			local released = CombatService.ReleaseNpcAttack(model, attackId)
			NpcAttackEvent:FireAllClients(model, baseId, if released then "Release" else "Cancel")
			if released then
				local current = targetPosition(target)
				if current and flatDistanceTo(current) <= reach + radius then
					task.delay(0.2, playHitSound, model, baseId)
				end
			end
		end
		-- the weapon cooldown always has to pass before the next swing is accepted
		task.wait(cooldown + RandomGenerator:NextNumber(BotConfig.TrainingSwingGapMin or 0.3, BotConfig.TrainingSwingGapMax or 1.2))
	end
end

-- Training visit + clean-up: puts the weapon back on the torso and walks back to the lobby afterwards.
local function runTraining(self: NPCEntity, revision: number)
	local profile = self.Profile
	if not profile or not isActive(self, revision) then return end
	local target = claimTarget()
	if not target then return end
	local baseId = baseWeaponIdOf(profile)

	local ok, err = pcall(trainSession, self, revision, target, baseId)
	releaseTarget(target)
	if not ok then warn(`LobbyNPCService: training failed for {self.Model.Name}: {err}`) end

	-- still ours (not taken to the arena / destroyed): stop any swing, put the weapon away, go back to the lobby
	if not isActive(self, revision) then return end
	local model = self.Model
	CombatService.CancelActor(model)
	NpcAttackEvent:FireAllClients(model, baseId, "Cancel")
	model:SetAttribute("IsInTrainingArea", nil)
	model:SetAttribute("EquippedBaseWeapon", nil)
	pcall(equipLobbyWeapon, model, profile.EquippedWeaponSkin, false)

	local lobbyPoint = chooseLobbyPoint().Position
	if not walkTo(self, revision, groundPoint(lobbyPoint, {}), 30) and isActive(self, revision) then
		model:PivotTo(CFrame.new(lobbyPoint)) -- no way back (blocked path): just put the bot back in the lobby
	end
end

local function startWandering(self: NPCEntity)
	self.WanderRevision += 1
	local revision = self.WanderRevision
	task.spawn(function()
		local root = self.Model:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then return end

		pcall(function() root:SetNetworkOwner(nil) end)
		while not self.IsDestroyed and not self.IsInArena and self.Model.Parent and self.WanderRevision == revision do
			local humanoid = self.Model:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then break end

			-- sometimes go and practise on the dummy bag / trainer NPC instead of wandering around the lobby
			if BotConfig.TrainingEnabled and RandomGenerator:NextNumber() < (BotConfig.TrainingChance or 0.4) then
				runTraining(self, revision)
				if self.IsDestroyed or self.IsInArena or self.WanderRevision ~= revision then break end
			end

			local target = chooseLobbyPoint()
			humanoid:MoveTo(target.Position)
			local deadline = os.clock() + RandomGenerator:NextNumber(3, 6)
			while not self.IsDestroyed and not self.IsInArena and self.WanderRevision == revision and os.clock() < deadline do
				if (root.Position - target.Position).Magnitude < 3 then break end
				task.wait(0.25)
			end

			if self.IsDestroyed or self.IsInArena or self.WanderRevision ~= revision then break end
			if RandomGenerator:NextNumber() < 0.35 then
				task.wait(RandomGenerator:NextNumber(0.5, 2.5))
			end
			if RandomGenerator:NextNumber() < 0.2 and humanoid.FloorMaterial ~= Enum.Material.Air then
				humanoid.Jump = true
			end
		end
	end)
end

-- Server-owned locomotion animation (same BotAnimator the arena bots use). The stock Animate script on the rig starts while
-- ApplyDescriptionAsync is still swapping the avatar and can end up with dead tracks, leaving NPCs as statues while moving.
local ANIMATION_INTERVAL = 0.1

local function stopAnimating(self: NPCEntity)
	self.AnimationRevision += 1
	local animator = self.Animator
	self.Animator = nil
	if animator then
		animator:destroy()
	end
end

local function startAnimating(self: NPCEntity)
	stopAnimating(self)
	local model = self.Model
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then return end

	local animator = BotAnimator.new(model, humanoid, root)
	self.Animator = animator
	local revision = self.AnimationRevision
	task.spawn(function()
		while not self.IsDestroyed and not self.IsInArena and self.AnimationRevision == revision and model.Parent do
			-- RagdollService may hand the stock Animate script back after a reset: keep it off
			local stock = model:FindFirstChild("Animate")
			if stock and stock:IsA("BaseScript") and stock.Enabled then stock.Enabled = false end
			animator:update(os.clock())
			task.wait(ANIMATION_INTERVAL)
		end
	end)
end

local function GetWeaponList()
	local variants = {}	

	for _, rarities in WeaponConfig.RarityVariants do
		for _, variant in rarities do
			table.insert(variants, variant :: string)
		end
	end

	local total: {string} = {}
	for baseId, _ in WeaponConfig.BaseWeapons do
		table.insert(total, baseId)

		for _, variant in variants do
			table.insert(total, baseId..variant)
		end
	end

	return total
end

function NPCEntity.CreateProfile(): Profile
	local appearance: ArenaAppearance?
	if true then
		appearance = NpcService.GetRandomArenaAppearance()
	end
	local ownsAppearance = appearance == nil
	local resolvedAppearance: ArenaAppearance = appearance or createFallbackAppearance()
	local weaponNames = GetWeaponList()

	local abilityNames = table.clone(BotConfig.SupportedAbilities)

	local baseWeapon = chooseRandomName(weaponNames)
	local skinNames = { baseWeapon }
	if WeaponConfig.Icons then
		for fullName in pairs(WeaponConfig.Icons) do
			if string.sub(fullName, 1, #baseWeapon) == baseWeapon and fullName ~= baseWeapon then
				table.insert(skinNames, fullName)
			end
		end
	end
	local weaponSkin = chooseRandomName(skinNames)

	local profile: Profile = {
		Description = resolvedAppearance.Description:Clone() :: HumanoidDescription,
		Username = resolvedAppearance.Username,
		UserId = resolvedAppearance.UserId,
		Trophies = resolvedAppearance.Trophies,
		GamesPlayed = resolvedAppearance.GamesPlayed,
		HasVIP = resolvedAppearance.HasVIP,
		EquippedAbility = chooseRandomName(abilityNames),
		EquippedWeapon = baseWeapon,          
		EquippedWeaponSkin = weaponSkin,      -- ADD THIS
		Aggression = RandomGenerator:NextNumber(0.25, 1),
	}

	if ownsAppearance then
		resolvedAppearance.Description:Destroy()
	end
	return profile
end

function NPCEntity.new(): NPCEntity
	local model = NpcTemplate:Clone()
	model.Name = "LobbyNPC"
	-- never let the stock Animate script run on a lobby NPC: BotAnimator owns locomotion
	local stockAnimate = model:FindFirstChild("Animate")
	if stockAnimate and stockAnimate:IsA("BaseScript") then stockAnimate.Enabled = false end
	local self: NPCEntity = {
		Model = model,
		Profile = nil,
		IsReady = false,
		IsInArena = false,
		IsDestroyed = false,
		WanderRevision = 0,
		AnimationRevision = 0,
		Animator = nil,
		Setup = NPCEntity.Setup,
		Start = NPCEntity.Start,
		MoveToArena = NPCEntity.MoveToArena,
		ReturnToLobby = NPCEntity.ReturnToLobby,
		Destroy = NPCEntity.Destroy,
	}
	return self
end

function NPCEntity.Setup(self: NPCEntity, profile: Profile, spawnCFrame: CFrame)
	self.Profile = profile
	self.Model.Name = profile.Username
	self.Model:PivotTo(spawnCFrame)
	self.Model:SetAttribute("Username", profile.Username)
	self.Model:SetAttribute("UserId", profile.UserId)
	self.Model:SetAttribute("Trophies", profile.Trophies)
	self.Model:SetAttribute("GamesPlayed", profile.GamesPlayed)
	self.Model:SetAttribute("HasVIP", profile.HasVIP)
	self.Model:SetAttribute("EquippedAbility", profile.EquippedAbility)
	self.Model:SetAttribute("EquippedWeapon", profile.EquippedWeapon)
	self.Model:SetAttribute("Aggression", profile.Aggression)
	self.Model:SetAttribute("IsBot", false)
	self.Model:SetAttribute("IsOnArena", false)
	self.Model:SetAttribute("SpawnPosition", spawnCFrame.Position)
	self.Model:SetAttribute("TerritoryRadius", math.max(LobbySpawn.Size.X, LobbySpawn.Size.Z) * 0.5)
end

function NPCEntity.Start(self: NPCEntity)
	local profile = self.Profile
	if not profile then
		error("NPCEntity:Setup must be called before Start")
	end

	task.spawn(function()
		if self.IsDestroyed then return end
		self.Model.Parent = LobbyNPCFolder
		local humanoid = self.Model:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			warn(`LobbyNPCService: NPC {self.Model.Name} has no Humanoid`)
			return
		end

		local description = profile.Description:Clone()
		local success, message = pcall(function()
			humanoid:ApplyDescriptionAsync(description)
		end)
		description:Destroy()
		if not success then
			warn(`LobbyNPCService: failed to apply appearance for {self.Model.Name}: {message}`)
		end

		if self.IsDestroyed or self.IsInArena then return end
		-- In Start():
		equipLobbyWeapon(self.Model, profile.EquippedWeaponSkin)

		CollectionService:AddTag(self.Model, "LobbyNPC")
		self.IsReady = true
		startAnimating(self) -- after the avatar is applied, never during the swap
		startWandering(self)
	end)
end

function NPCEntity.MoveToArena(self: NPCEntity, targetCFrame: CFrame): boolean
	if not self.IsReady or self.IsDestroyed or self.IsInArena then return false end
	local profile = self.Profile
	if not profile then return false end

	self.IsInArena = true
	self.WanderRevision += 1
	-- a bot that was training: stop its swing and drop the training state before it becomes an arena bot
	CombatService.CancelActor(self.Model)
	NpcAttackEvent:FireAllClients(self.Model, "Slap", "Cancel")
	self.Model:SetAttribute("IsInTrainingArea", nil)
	self.Model:SetAttribute("EquippedBaseWeapon", nil)
	stopAnimating(self) -- BotService.AdoptArenaNPC creates its own BotAnimator
	local lobbyWeapon = self.Model:FindFirstChild("EquippedWeapon")
	if lobbyWeapon then lobbyWeapon:Destroy() end
	CollectionService:RemoveTag(self.Model, "LobbyNPC")
	self.Model.Parent = Workspace
	self.Model:PivotTo(targetCFrame)
	self.Model:SetAttribute("IsOnArena", true)
	self.Model:SetAttribute("IsFrozen", true)
	self.Model:SetAttribute("Lives", 3)
	self.Model:SetAttribute("BotWeapon", profile.EquippedWeapon)
	self.Model:SetAttribute("BotVIP", profile.HasVIP)
	return true
end

function NPCEntity.ReturnToLobby(self: NPCEntity)
	if self.IsDestroyed or not self.IsInArena or not self.Model.Parent then return end
	local profile = self.Profile
	if not profile then return end

	local spawnCFrame = chooseLobbyPoint()
	RagdollService.Cancel(self.Model, "LobbyReturn", spawnCFrame)
	CollectionService:RemoveTag(self.Model, "ArenaNPC")
	CollectionService:RemoveTag(self.Model, "BotActor")

	local equippedWeapon = self.Model:FindFirstChild("EquippedWeapon")
	if equippedWeapon then equippedWeapon:Destroy() end
	self.Model:SetAttribute("IsBot", false)
	self.Model:SetAttribute("IsOnArena", false)
	self.Model:SetAttribute("IsFrozen", false)
	self.Model:SetAttribute("IsCharging", false)
	self.Model:SetAttribute("LastHitBy", nil)
	self.Model:SetAttribute("Lives", nil)
	self.Model:SetAttribute("BotWeapon", nil)
	self.Model:SetAttribute("BotWeaponSkin", nil)
	self.Model:SetAttribute("BotVIP", nil)
	self.Model:SetAttribute("EquippedBaseWeapon", nil)
	self.Model:PivotTo(spawnCFrame)
	self.Model.Parent = LobbyNPCFolder
	self.Model.Name = profile.Username

	-- In ReturnToLobby():
	equipLobbyWeapon(self.Model, profile.EquippedWeaponSkin)	
	self.IsInArena = false
	CollectionService:AddTag(self.Model, "LobbyNPC")
	startAnimating(self)
	startWandering(self)
end

function NPCEntity.Destroy(self: NPCEntity)
	if self.IsDestroyed or self.IsInArena then return end
	self.IsDestroyed = true
	self.IsReady = false
	self.WanderRevision += 1
	stopAnimating(self)
	CollectionService:RemoveTag(self.Model, "LobbyNPC")
	self.Model:Destroy()
end

return NPCEntity
