-- Clients send charge intent; the server owns timing, hit detection and profiles.
local CombatService = {}
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Events = ReplicatedStorage:WaitForChild("Events")
local AttackEvent = Events:WaitForChild("CombatAttack")
local AbilityEvent = Events:WaitForChild("ActivateAbilityEvent")
local EffectsEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEffects")
local Shared = ReplicatedStorage:WaitForChild("SharedModules")
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local ShrinkScale = require(Shared.ShrinkScale)
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local JumpAttackCharge = require(Shared:WaitForChild("JumpAttackCharge"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local CombatConfig = GameConfig.Combat
local Simulation = require(ReplicatedStorage.Simulation)
local SimulationState = require(ReplicatedStorage.Simulation.State)
local ActorTimelines = require(ReplicatedStorage.Simulation.ActorTimelines)
local SimulationCombat = require(ReplicatedStorage.Simulation.Combat)
local Ragdoll = require(script.Parent:WaitForChild("RagdollService"))
local Protection = require(script:WaitForChild("Protection"))
local DetectionService = require(script.Parent:WaitForChild("DetectionService"))
local VisualizeUtils = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("Visualize"))
local TimeStopService = require(script:WaitForChild("TimeStopService"))
local Clock = require(Shared:WaitForChild("TimeStopClock"))

local MAX_CHARGE, MAX_DISTANCE = CombatConfig.MaxChargeTime, CombatConfig.MaxHitDistance
-- Release timestamps use time(), not the client's local clock.
local initialized = false
local playerData, abilityData = {}, {}
local npcData = setmetatable({}, { __mode = "k" })
local actorConnections = setmetatable({}, { __mode = "k" })
local activeSwings = {} -- Actor -> released attack; owns one deduplication set for the entire window.
local attackTimings = {} -- Validated base-weapon timings captured at startup.	

local ThrowPath = require(game.ReplicatedStorage:WaitForChild("SharedModules").Throw:WaitForChild("ThrowPath"))
-- ============================================================
local SMASH_GRACE = 2          -- extra seconds the server keeps a smash open after config.Duration
local SMASH_MIN_AIRTIME = 0.2  -- an Impact cannot arrive earlier than this after the Request
local SMASH_DEBUG = true
local function initializeAttackTimings()
	for weaponId, info in WeaponConfig.BaseWeapons do
		local attack, jump = info.Attack, info.JumpAttack
		assert(type(attack) == "table" and type(jump) == "table", "Missing attack settings for " .. weaponId)
		assert(type(info.Cooldown) == "number" and info.Cooldown == info.Cooldown
			and info.Cooldown >= 0 and info.Cooldown < math.huge, "Invalid weapon cooldown for " .. weaponId)
		local function validate(slot, settings)
			local multiplier = settings.KnockbackMultiplier
			assert(type(multiplier) == "number" and multiplier == multiplier and multiplier > 0
				and multiplier < math.huge, "Invalid knockback multiplier for " .. weaponId .. "." .. slot)
			for _, name in { "Windup", "TrackLength", "TrackChargeThreshold", "HitboxDuration" } do
				local value = settings[name]
				assert(type(value) == "number" and value == value and value >= 0 and value < math.huge
					and (name ~= "TrackChargeThreshold" or value <= 1),
					"WeaponConfig.BaseWeapons." .. weaponId .. "." .. slot .. "." .. name .. " is invalid")
			end
			for _, name in { "HitboxSize", "HitboxOffset" } do
				local vector = settings[name]
				assert(typeof(vector) == "Vector3", "Invalid " .. weaponId .. "." .. slot .. "." .. name)
				for _, component in { vector.X, vector.Y, vector.Z } do
					assert(component == component and math.abs(component) < math.huge
						and (name ~= "HitboxSize" or component > 0),
						"Invalid " .. weaponId .. "." .. slot .. "." .. name .. " component")
				end
			end
		end
		validate("Attack", attack)
		validate("JumpAttack", jump)
		attackTimings[weaponId] = {
			cooldown = info.Cooldown,
			knockbackMultiplier = attack.KnockbackMultiplier,
			jumpKnockbackMultiplier = jump.KnockbackMultiplier,
			windup = attack.Windup,
			trackLength = attack.TrackLength,
			trackChargeThreshold = attack.TrackChargeThreshold,
			duration = attack.HitboxDuration,
			boxSize = attack.HitboxSize,
			boxOffset = CFrame.new(attack.HitboxOffset),
			jumpWindup = jump.Windup,
			jumpTrackLength = jump.TrackLength,
			jumpTrackChargeThreshold = jump.TrackChargeThreshold,
			jumpDuration = jump.HitboxDuration,
			jumpBoxSize = jump.HitboxSize,
			jumpBoxOffset = CFrame.new(jump.HitboxOffset),
		}
	end
end

local function owns(player, attribute, name)
	for _, entry in string.split((PlayerData.Get(player, attribute) :: string?) or "", ",") do
		if string.match(entry, "^%s*(.-)%s*$") == name then return true end
	end
	return false
end

local function dataFor(actor, player)
	if player then
		if not playerData[player] or (actor and playerData[player].actor ~= actor) then
			playerData[player] = { actor = actor, nextReady = 0, lastId = 0, abilityLastId = 0, abilityNextReady = {} }
		end
		return playerData[player]
	end
	if not npcData[actor] then npcData[actor] = { nextReady = 0, lastId = 0 } end
	return npcData[actor]
end

local function allowRequest(player)
	local data, now = dataFor(player.Character, player), os.clock()
	data.tokens = math.min(24, (data.tokens or 24) + math.max(0, now - (data.tokenTime or now)) * 12)
	data.tokenTime = now
	if data.tokens < 1 then return false end
	data.tokens -= 1
	return true
end

local function isBlocked(actor, player)
	local humanoid = actor and actor:FindFirstChildOfClass("Humanoid")
	if not actor or not actor:IsDescendantOf(Workspace) or not humanoid or humanoid.Health <= 0 then return true end
	if
		actor:GetAttribute("IsFrozen")
		or actor:GetAttribute("MovementLocked")
		or Ragdoll.IsRagdolled(actor)
		or TimeStopService.IsFrozenTarget(actor)
	then
		return true
	end
	if player then
		if
			player.Character ~= actor
			or PlayerData.Get(player, "DataLoaded") ~= true
			or PlayerData.Get(player, "IsFrozen")
			or PlayerData.Get(player, "TeleportingActive")
		then
			return true
		end
		if not (PlayerData.Get(player, "IsOnArena") or PlayerData.Get(player, "IsInTrainingArea")) then
			return true
		end
	end
	local root = actor:FindFirstChild("HumanoidRootPart")
	return not root or not root:IsA("BasePart") or root.Anchored
end

local function weaponFor(actor, player)
	local weapon = actor:FindFirstChild("EquippedWeapon")
	if not weapon or not weapon:IsA("Model") then return nil end
	local weaponId, fullName = weapon:GetAttribute("WeaponId"), weapon:GetAttribute("WeaponName")
	if type(weaponId) ~= "string" or not WeaponConfig.BaseWeapons[weaponId] then return nil end
	if player and (type(fullName) ~= "string" or not owns(player, "OwnedWeapons", fullName)) then return nil end
	return weapon, weaponId
end

local function hitEffectWeaponName(actor, weaponId)
	local weapon = actor:FindFirstChild("EquippedWeapon")
	if weapon and weapon:GetAttribute("WeaponId") == weaponId then
		local fullName = weapon:GetAttribute("WeaponName")
		if type(fullName) == "string" and fullName ~= "" then return fullName end
	end
	return weaponId
end

local function finishSwing(swing, cancelled)
	if activeSwings[swing.actor] ~= swing then
		return
	end
	activeSwings[swing.actor] = nil
	if swing.data.swing == swing then
		swing.data.swing = nil
	end
	local player = swing.player
	if cancelled and player and player.Parent == Players then
		AttackEvent:FireClient(player, "Rejected", swing.id, "Cancelled", swing.data.nextReady)
	end
end

function CombatService.CancelActor(actor)
	local player = actor:IsA("Model") and Players:GetPlayerFromCharacter(actor)
	local data = player and playerData[player] or npcData[actor]
	if data and data.charge and data.charge.actor == actor then
		local id = data.charge.id
		JumpAttackCharge.Stop(data.charge.airMotion)
		data.charge = nil
		if player then
			PlayerData.Set(player, "ChargeAttack", false)
		end
		if player and player.Parent then
			AttackEvent:FireClient(player, "Rejected", id, "Cancelled", data.nextReady)
		end
	end
	local swing = activeSwings[actor]
	if swing then
		finishSwing(swing, true)
	end
end

local function watchActor(actor)
	if actorConnections[actor] then return end
	local connections = {}
	actorConnections[actor] = connections
	local function changed()
		if
			actor:GetAttribute("IsRagdolled")
			or actor:GetAttribute("IsFrozen")
			or actor:GetAttribute("MovementLocked")
		then
			CombatService.CancelActor(actor)
			local player = actor:IsA("Model") and Players:GetPlayerFromCharacter(actor)
			if player then CombatService.CancelAbilities(player, actor) end
		end
	end
	table.insert(connections, actor:GetAttributeChangedSignal("IsRagdolled"):Connect(changed))
	table.insert(connections, actor:GetAttributeChangedSignal("IsFrozen"):Connect(changed))
	table.insert(connections, actor:GetAttributeChangedSignal("MovementLocked"):Connect(changed))
	table.insert(connections, actor:GetAttributeChangedSignal("RagdollGeneration"):Connect(function()
		CombatService.CancelActor(actor)
	end))
	local humanoid = actor:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(connections, humanoid.Died:Connect(function()
			CombatService.CancelActor(actor)
		end))
	end
	table.insert(connections, actor:GetAttributeChangedSignal("WeaponRevision"):Connect(function() CombatService.CancelActor(actor) end))
	table.insert(connections, actor.ChildRemoved:Connect(function(child)
		if child.Name == "EquippedWeapon" then CombatService.CancelActor(actor) end
	end))
	table.insert(connections, actor.AncestryChanged:Connect(function()
		if actor:IsDescendantOf(Workspace) then
			return
		end
		CombatService.CancelActor(actor)
		for _, connection in connections do connection:Disconnect() end
		actorConnections[actor], npcData[actor] = nil, nil
	end))
end

local function validId(id)
	return type(id) == "number" and id == id and id % 1 == 0 and id >= 1 and id <= 2147483647
end

local function beginAttack(actor, player, id, generation, equipmentRevision, clientStartedAt, clientAttackType)
	if isBlocked(actor, player) then return false, "Blocked" end
	if player and clientAttackType ~= "Attack" and clientAttackType ~= "JumpAttack" then return false, "AttackType" end
	local weapon, weaponId = weaponFor(actor, player)
	if not weapon then return false, "Equipment" end
	local data, now = dataFor(actor, player), clientStartedAt or time()
	if not validId(id) or id <= data.lastId then return false, "AttackId" end
	data.lastId = id
	if data.charge or now < data.nextReady then
		return false, "Cooldown"
	end
	local actualGeneration = actor:GetAttribute("RagdollGeneration")
	local actualRevision = actor:GetAttribute("WeaponRevision") or 0
	if player and (generation ~= actualGeneration or equipmentRevision ~= actualRevision or actualGeneration == nil) then return false, "Stale" end
	watchActor(actor)
	if data.swing then
		-- A long configured hit window must not extend the attack cooldown.
		finishSwing(data.swing, false)
	end
	local airMotion = JumpAttackCharge.Begin(actor, false)
	if player then
		airMotion.airborne = clientAttackType == "JumpAttack"
	end
	data.charge = {
		id = id, actor = actor, startedAt = now, generation = actualGeneration,
		equipmentRevision = actualRevision, weapon = weapon, weaponId = weaponId,
		-- Shared simulation owns charge movement; the server adapter observes the confirmed attack.
		airMotion = airMotion,
		attackType = if player then clientAttackType else if airMotion.airborne then "JumpAttack" else "Attack",
	}
	if not player then
		local humanoid = actor:FindFirstChildOfClass("Humanoid")
		local startedAt, attackType = now, data.charge.attackType
		SimulationState.Queue(actor, function()
			if humanoid then
				Attributes.Set(humanoid, "SAAttackId", id)
				Attributes.Set(humanoid, "SAChargeStarted", startedAt)
				Attributes.Set(humanoid, "SAAttackType", attackType)
				Attributes.Set(humanoid, "SAAttackWeapon", weaponId)
				Attributes.Set(humanoid, "SAReleasedAt", nil)
				Attributes.Set(humanoid, "SACharging", true)
			end
		end)
	end
    if player then
		PlayerData.Set(player, "ChargeAttack", true)
	end
	return true
end

local function isWeaponOrAccessory(part)
	local ancestor = part.Parent
	while ancestor and ancestor ~= Workspace do
		if ancestor:IsA("Accessory") or ancestor:IsA("Tool") or ancestor.Name == "EquippedWeapon" then return true end
		ancestor = ancestor.Parent
	end
	return false
end

local function wallParams()
	local exclude = {}
	for _, player in Players:GetPlayers() do if player.Character then table.insert(exclude, player.Character) end end
	for _, tag in { "ArenaNPC", "LobbyNPC", "TrainingBag", "CombatActor" } do
		for _, actor in CollectionService:GetTagged(tag) do table.insert(exclude, actor) end
	end
	for _, name in { "KnockbackRuntime", "CombatLocalEffects", "CombatEffects", "ClientEffects" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then table.insert(exclude, folder) end
	end
	local params = RaycastParams.new()
	params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, exclude
	params.RespectCanCollide = true
	return params
end

local function contactPoint(part, from)
	local point
	local ok = pcall(function() point = part:GetClosestPointOnSurface(from) end)
	return if ok and point then point else part.Position
end
local function bigWeaponMultiplier(player, weapon)
	local effect = player and abilityData[player] and abilityData[player].BigWeapon
	if not effect or effect.weapon ~= weapon or not weapon or not weapon.Parent or not effect.baseScale then return 1 end
	return math.clamp(
		(
			(
				weapon.Parent
				and weapon.Parent:FindFirstChild("HumanoidRootPart")
				and Attributes.Get(weapon.Parent.HumanoidRootPart, "SAWeaponScale")
			) or 1
		),
		1,
		10
	)
end

local function querySwing(swing)
	local actor, player, root = swing.actor, swing.player, swing.root
	local weaponId, strength = swing.weaponId, swing.strength
	--local boxSize = swing.hitboxSize
	local predictedRoot = root.CFrame
	-- Keep distance/line-of-sight validation anchored to the actual server position.
	local mult = bigWeaponMultiplier(player, swing.weapon)
	local boxSize = swing.hitboxSize * mult
	local origin = root.Position
	local boxCFrame = predictedRoot * CFrame.new(swing.hitboxOffset.Position * mult)
	--local origin, boxCFrame = root.Position, predictedRoot * swing.hitboxOffset -- old
	local overlap = swing.overlap
	local obstruction, seen, hits = wallParams(), swing.seen, {}
	local candidates = {}

	if RunService:IsStudio() then
		VisualizeUtils.Space(boxCFrame, boxSize, "AttackHitBox", BrickColor.Red().Color, 0.25)
	end
	local function gather(cf, size)
		for _, part in Workspace:GetPartBoundsInBox(cf, size, overlap) do
			if isWeaponOrAccessory(part) then continue end
			local target = Ragdoll.GetActorFromPart(part)
			if target and target ~= actor then
				table.insert(candidates, { actor = target, position = contactPoint(part, cf.Position) })
			end
		end
		for _, candidate in Ragdoll.GetActiveTargetsInBox(cf, size, actor) do
			table.insert(candidates, candidate)
		end
	end

	gather(boxCFrame, boxSize)
	if mult > 1 and swing.weapon and swing.weapon.Parent then
		-- the big weapon itself: whatever it visually touches gets hit
		local cf, size = swing.weapon:GetBoundingBox()
		gather(cf, size + Vector3.new(2, 2, 2))
	end
	
	
	for _, part in Workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlap) do
		if isWeaponOrAccessory(part) then
			continue
		end
		local target = Ragdoll.GetActorFromPart(part)	
		if target and target ~= actor then
			table.insert(candidates, { actor = target, position = contactPoint(part, boxCFrame.Position) })
		end
	end
	for _, candidate in Ragdoll.GetActiveTargetsInBox(boxCFrame, boxSize, actor) do
		table.insert(candidates, candidate)
	end
	for _, candidate in candidates do
		if activeSwings[actor] ~= swing then
			break
		end
		local target = candidate.actor
		if seen[target] then
			continue
		end
		local position = Ragdoll.GetAuthoritativePosition(target)
		if not position or (position - origin).Magnitude > MAX_DISTANCE then continue end
		local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
		if
			targetPlayer
			and (
				Protection.IsProtected(targetPlayer)
				or PlayerData.Get(targetPlayer, "IsInvulnerable")
				or PlayerData.Get(targetPlayer, "TeleportingActive")
			)
		then
			continue
		end
		local targetRoot = target:IsA("BasePart") and target or target:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") then continue end
		local humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then continue end
		local hitPosition = candidate.position
		local sight = hitPosition - origin
		if sight.Magnitude > 0.01 and Workspace:Raycast(origin, sight, obstruction) then continue end
		local direction = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
		if direction.Magnitude < 0.01 then direction = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
		if direction.Magnitude < 0.01 then direction = Vector3.zAxis end

		-- TIME STOP first: frozen targets are anchored, so this must run BEFORE the anchored check
		if TimeStopService.IsFrozenTarget(target) then
			if TimeStopService.InterceptHit(target, direction.Unit, {
				attacker = actor, weaponId = weaponId, strength = strength,
				knockbackMultiplier = swing.knockbackMultiplier, position = hitPosition,
				}) then
				seen[target] = true
				table.insert(hits, { actor = target, actorId = target:GetAttribute("KnockbackActorId"), position = hitPosition })
			end
			continue
		end

		if targetRoot.Anchored and not Ragdoll.IsKnockbackAnchored(target) then continue end
		if not Ragdoll.ApplyHit(target, direction.Unit, {
			weaponId = weaponId, strength = strength, knockbackMultiplier = swing.knockbackMultiplier,
		}) then
			continue
		end
		seen[target] = true
		CombatService.CancelActor(target)
		target:SetAttribute("LastHitBy", player and player.Name or actor.Name)
		if player and PlayerData.Get(player, "IsOnArena") then
			PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
		end
		EffectsEvent:FireAllClients(weaponId, hitPosition, direction.Unit,
			swing.weapon and swing.weapon:GetAttribute("WeaponName"))
		table.insert(hits, { actor = target, actorId = target:GetAttribute("KnockbackActorId"), position = hitPosition })
		if target:GetAttribute("KnockbackActorKind") == "Bag" or CollectionService:HasTag(target, "TrainingBag") then
			AttackEvent:FireAllClients(
				"BagHit",
				target,
				target:GetAttribute("RagdollGeneration"),
				ReplicatedValues.GetNumber(target, "RagdollRevision")
			)
		end
	end
	if player and player.Parent == Players and #hits > 0 then
		AttackEvent:FireClient(player, "Hits", swing.id, actor, swing.generation, weaponId, hits)
		local info = WeaponConfig.BaseWeapons[weaponId]
		local weapon = swing.weapon
		local sound = info and info.HitSound and weapon and weapon.Parent
			and weapon:FindFirstChild(info.HitSound, true) -- recursive: works for any part name
		if sound and sound:IsA("Sound") then sound:Play() end
		if WeaponConfig.WeaponEffectSoundEnabled then
			local effectSound = weapon and weapon.Parent and weapon:FindFirstChild("WeaponEffectHit", true)
			if effectSound and effectSound:IsA("Sound") then effectSound:Play() end
		end
	end
end

local function swingValid(swing)
	if swing.data.swing ~= swing or isBlocked(swing.actor, swing.player) then
		return false
	end
	local actor = swing.actor
	if
		actor:GetAttribute("RagdollGeneration") ~= swing.generation
		or (actor:GetAttribute("WeaponRevision") or 0) ~= swing.equipmentRevision
		or actor:FindFirstChild("HumanoidRootPart") ~= swing.root
	then
		return false
	end
	local weapon, weaponId = weaponFor(actor, swing.player)
	return weapon == swing.weapon and weaponId == swing.weaponId
end


local function updateSwings()
	local now = time()
	local function updateCharge(data, player)
		local current = data.charge
		if current then
			if isBlocked(current.actor, player) then
				CombatService.CancelActor(current.actor)
			elseif not player then
				JumpAttackCharge.Update(current.airMotion, now - current.startedAt)
			end
		end
	end
	for player, data in playerData do
		updateCharge(data, player)
	end
	for _, data in npcData do updateCharge(data, nil) end
	for _, swing in activeSwings do
		if not swingValid(swing) then
			finishSwing(swing, true)
			continue
		end
		if now < swing.opensAt then
			continue
		end
		-- Start the window at its first actual sample. No catch-up queries at stale positions.
		if not swing.expiresAt then
			swing.expiresAt = now + swing.duration
		elseif now >= swing.expiresAt then
			finishSwing(swing, false)
			continue
		end
		querySwing(swing)
		if swing.duration == 0 then
			finishSwing(swing, false)
		end
	end
end

local function releaseAttack(actor, player, id, generation, equipmentRevision, clientReleasedAt, clientHeldTime)
	local data = dataFor(actor, player)
	local charge = data.charge
	if not charge or charge.id ~= id or charge.actor ~= actor then return false, "Stale" end
	-- Consume release once; wind-up never contributes to charge strength.
	JumpAttackCharge.Stop(charge.airMotion)
	data.charge = nil
	if player then
		PlayerData.Set(player, "ChargeAttack", false)
	end
	if isBlocked(actor, player) then return false, "Blocked" end
	local weapon, weaponId = weaponFor(actor, player)
	if weapon ~= charge.weapon or weaponId ~= charge.weaponId
		or actor:GetAttribute("RagdollGeneration") ~= charge.generation
		or (actor:GetAttribute("WeaponRevision") or 0) ~= charge.equipmentRevision then return false, "Stale" end
	if player and (generation ~= charge.generation or equipmentRevision ~= charge.equipmentRevision) then return false, "Stale" end
	local root = actor:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return false, "Removed" end
	local timing = attackTimings[weaponId]
	if not timing then
		return false, "Equipment"
	end
	local now = clientReleasedAt or time()
	local heldTime = now - charge.startedAt
	local jumpHeldTime = heldTime
	local strengthAlpha = math.clamp((now - charge.startedAt) / MAX_CHARGE, 0, 1)
	if charge.attackType == "JumpAttack" and not WeaponConfig.ChargedJumpAttack.Enable then
		strengthAlpha = 0 -- Disabled jump charging cannot gain normal charge power by delaying Release.
	end
	local strength = CombatConfig.MinChargeMultiplier + (CombatConfig.MaxChargeMultiplier - CombatConfig.MinChargeMultiplier)
		* strengthAlpha
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { actor }
	
	local airborne = charge.attackType == "JumpAttack" -- Locked at Start; landing must not change any release settings.
	local baseWindup = if airborne then timing.jumpWindup else timing.windup
	local hitboxDuration = if airborne then timing.jumpDuration else timing.duration
	local trackLength = if airborne then timing.jumpTrackLength else timing.trackLength
	local chargeThreshold = if airborne then timing.jumpTrackChargeThreshold else timing.trackChargeThreshold
	local chargePosetime = chargeThreshold*trackLength
	local windupTime =  math.max(0, baseWindup - strengthAlpha*chargePosetime)
	
	--warn(strengthAlpha)
	--warn(windupTime)
	local swing = {
		id = id,
		actor = actor,
		player = player,
		root = root,
		data = data,
		generation = charge.generation,
		equipmentRevision = charge.equipmentRevision,
		weapon = weapon,
		weaponId = weaponId,
		strength = strength,
		attackType = charge.attackType,
		knockbackMultiplier = if airborne then timing.jumpKnockbackMultiplier else timing.knockbackMultiplier,
		chargedJumpAttack = JumpAttackCharge.IsCharged(charge.airMotion, jumpHeldTime),
		opensAt = now + windupTime,
		duration = hitboxDuration,
		hitboxSize = if airborne then timing.jumpBoxSize else timing.boxSize,
		hitboxOffset = if airborne then timing.jumpBoxOffset else timing.boxOffset,
		expiresAt = nil,
		seen = {},
		overlap = overlap,
	}
	-- Normal strength and hit scheduling use receipt time; jump qualification allows bounded hold-time jitter.
	local releasedAt = now
	local humanoid = actor:FindFirstChildOfClass("Humanoid")
	data.nextReady = if player and humanoid
		then Attributes.Get(humanoid, "SAAttackReadyAt") or releasedAt + timing.cooldown
		else releasedAt + timing.cooldown * TimeStopService.GetAttackCooldownScale(actor)
	data.swing, activeSwings[actor] = swing, swing
	if not player then
		SimulationState.Queue(actor, function()
			if humanoid then
				Attributes.Set(humanoid, "SACharging", false)
				Attributes.Set(humanoid, "SAReleasedAt", now)
			end
		end)
	end

	return true
end

function CombatService.BeginNpcAttack(actor)
	local data = dataFor(actor, nil)
	local id = data.lastId + 1
	local accepted = beginAttack(actor, nil, id)
	return accepted and id or nil
end

function CombatService.ReleaseNpcAttack(actor, attackId)
	return releaseAttack(actor, nil, attackId)
end

local function clearAbility(player, ability)
	local effects = abilityData[player]
	local effect = effects and effects[ability]
	if not effect then return end
	effects[ability] = nil
	effect.cancelled = true
	if effect.connection then effect.connection:Disconnect() end
	if effect.restore then effect.restore() end
	Protection.Clear(player, ability)
end

function CombatService.CancelAbilities(player, character)
	local effects = abilityData[player]
	if effects then
		local remove = {}
		for ability, effect in pairs(effects) do
			if not character or effect.character == character then table.insert(remove, ability) end
		end
		for _, ability in remove do clearAbility(player, ability) end
	end
	local data = playerData[player]
	if player.Parent then AbilityEvent:FireClient(player, "Cancel", character, data and data.abilityLastId or 0) end
end
local function flatten(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

local function runChargeHits(player, character, effect, config)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return end

	-- the box faces the way he really runs
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local forward = (if speed > 8 then flatten(velocity) else nil) or flatten(root.CFrame.LookVector) or Vector3.zAxis

	local size = config.HitboxSize or Vector3.new(8, 6, 9)
	local offset = config.HitboxOffset or Vector3.new(0, 0, -3)
	-- Contacts use the simulated server transform without ownership lead compensation.
	local lead = 0
	local boxCFrame = CFrame.lookAt(root.Position, root.Position + forward) * CFrame.new(offset.X, offset.Y, offset.Z - lead / 2)
	local boxSize = Vector3.new(size.X, size.Y, size.Z + lead)

	local candidates = {}
	for _, part in Workspace:GetPartBoundsInBox(boxCFrame, boxSize, effect.overlap) do
		if not isWeaponOrAccessory(part) then
			local target = Ragdoll.GetActorFromPart(part)
			if target and target ~= character then
				table.insert(candidates, { actor = target, position = contactPoint(part, boxCFrame.Position) })
			end
		end
	end
	for _, candidate in Ragdoll.GetActiveTargetsInBox(boxCFrame, boxSize, character) do
		table.insert(candidates, candidate)
	end

	local origin = root.Position
	for _, candidate in candidates do
		local target = candidate.actor
		if effect.seen[target] then continue end -- everybody is hit once per charge
		local position = Ragdoll.GetAuthoritativePosition(target)
		if not position or (position - origin).Magnitude > (config.MaxHitDistance or 16) then continue end
		local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
		if
			targetPlayer
			and (
				Protection.IsProtected(targetPlayer)
				or PlayerData.Get(targetPlayer, "IsInvulnerable")
				or PlayerData.Get(targetPlayer, "TeleportingActive")
			)
		then
			continue
		end
		local targetRoot = target:IsA("BasePart") and target or target:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") then continue end
		if targetRoot.Anchored and not Ragdoll.IsKnockbackAnchored(target) then continue end
		local humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then continue end
		local hitPosition = candidate.position
		local sight = hitPosition - origin
		if sight.Magnitude > 0.01 and Workspace:Raycast(origin, sight, effect.obstruction) then continue end

		-- thrown ahead, and to the side he was standing on (plowed aside, not just pushed back)
		local right = forward:Cross(Vector3.yAxis)
		local flatOffset = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
		local side = math.clamp(flatOffset:Dot(right) / 4, -1, 1)
		local direction = flatten(forward + right * side * (config.SideKnock or 0.6)) or forward
		local strength = math.clamp(config.Strength or 1.35, 1, 1.5) -- ApplyHit only accepts 1 .. 1.5

		if not Ragdoll.ApplyHit(target, direction, { weaponId = effect.profileId, strength = strength }) then continue end
		effect.seen[target] = true
		effect.hits += 1
		CombatService.CancelActor(target) -- exactly like an M1 hit: the target's own attack is cancelled
		target:SetAttribute("LastHitBy", player.Name)
		if PlayerData.Get(player, "IsOnArena") then
			PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
		end
		EffectsEvent:FireAllClients(effect.profileId, hitPosition, direction,
			hitEffectWeaponName(character, effect.profileId))
		AbilityEvent:FireAllClients("ChargeImpact", player, hitPosition)
		AbilityEvent:FireClient(player, "ChargeHit", effect.hits)
		if targetPlayer then AbilityEvent:FireClient(targetPlayer, "ChargeVictim") end
	end
end

-- BigWeapon / TimeTravel are defined further down (they reuse the Smash helpers)
local startBigWeapon, startTimeTravel

local function EffectCurrent(player, ability, effect)
	return not effect.cancelled
		and abilityData[player]
		and abilityData[player][ability] == effect
		and player.Character == effect.character
		and effect.character.Parent ~= nil
		and effect.character:GetAttribute("RagdollGeneration") == effect.generation
		and (effect.character:GetAttribute("WeaponRevision") or 0) == effect.equipmentRevision
		and not isBlocked(effect.character, player)
end

local function activateAbility(player, action, id, ability, character, generation, position)
	if not allowRequest(player) then return end
	if action == "Impact" then
		CombatService.smashImpact(player, id, ability, character, generation, position)
		return
	end
	if action ~= "Request" or not validId(id) or type(ability) ~= "string" or #ability > 64 then return end
	local data = dataFor(character, player)
	if id <= data.abilityLastId then return end
	data.abilityLastId = id
	local config, now = AbilityConfig.Abilities[ability], time()
	local function reject()
		local readyAt = data.abilityNextReady[ability] or now
		AbilityEvent:FireClient(player, "Result", id, false, ability, readyAt)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		SimulationState.Queue(character, function()
			if humanoid and Attributes.Get(humanoid, "SAAbilityId") == id then
				Attributes.Set(humanoid, "SAActiveAbility", "")
				Attributes.Set(humanoid, "SAAbilityAnimation", "")
				Attributes.Set(humanoid, "SAAbilityReadyAt", readyAt)
				if config then
					Attributes.Set(humanoid, "SACD" .. ability, readyAt)
				end
			end
		end)
	end
	if (ability ~= "Dash" and ability ~= "Shrink" and ability ~= "Invisible" 
		and ability ~= "MegaJump" and ability ~= "Smash" and ability ~= "Charge" 
		and ability ~= "Throw" and ability ~= "Push" and ability ~= "Pull" 
		and ability ~= "TimeStop" and ability ~= "BigWeapon" and ability ~= "TimeTravel") or not config then 				reject()
		return
end

	if typeof(character) ~= "Instance" or not character:IsA("Model") or character ~= player.Character
		or generation ~= character:GetAttribute("RagdollGeneration") or generation == nil
		or PlayerData.Get(player, "EquippedAbility") ~= ability
		or (not owns(player, "OwnedAbilities", ability) and PlayerData.Get(player, "DevAccess") ~= true)
		or isBlocked(character, player) or data.charge
		or now < (data.abilityNextReady[ability] or 0) then 				reject()
		return
end
	if data.swing then
		finishSwing(data.swing, false)
	end

	if ability == "TimeStop" and not TimeStopService.CanStart(player) then
		reject()
		return
	end
	if ability == "BigWeapon" and not weaponFor(character, player) then
		reject()
		return
	end
	if ability == "TimeTravel" then
		-- two-step ability: the server decides if this press drops the ghost or jumps back to it
		startTimeTravel(player, character, id, config, data, now, reject)
		return
	end
	data.abilityNextReady[ability] = now + config.Cooldown
	clearAbility(player, ability)
	abilityData[player] = abilityData[player] or {}
	local effect = {
		character = character,
		generation = generation,
		equipmentRevision = character:GetAttribute("WeaponRevision") or 0,
	}
	abilityData[player][ability] = effect
	if ability == "Shrink" then
		local humanoid = character:FindFirstChildWhichIsA("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then return end
		local original = {
			Scale = character:GetScale(),
			RootSize = root.Size,
			Physics = {} :: {[BasePart]: { Custom: PhysicalProperties?, Current: PhysicalProperties }},
		}
		local scaleWeapon = config.ScaleWeapon
		local weapon = character:FindFirstChild("EquippedWeapon")
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") and (scaleWeapon or not weapon or not descendant:IsDescendantOf(weapon)) then
				original.Physics[descendant] = {
					Custom = descendant.CustomPhysicalProperties,
					Current = descendant.CurrentPhysicalProperties,
				}
			end
		end
		-- Publish the baseline before the final geometry and activation reach clients.
		character:SetAttribute("ShrinkOriginalScale", original.Scale)
		character:SetAttribute("ShrinkOriginalRootSize", original.RootSize)
		ShrinkScale.Apply(character, humanoid, root, original.Scale * config.Scale, scaleWeapon)
		for part, saved in original.Physics do
			local properties = saved.Current
			part.CustomPhysicalProperties = PhysicalProperties.new(
				math.clamp(properties.Density / (config.Scale ^ 3), 0.01, 100),
				properties.Friction, properties.Elasticity,
				properties.FrictionWeight, properties.ElasticityWeight
			)
		end
		effect.restore = function()
			if character.Parent and player.Character == character
				and humanoid:IsDescendantOf(character) and root:IsDescendantOf(character) then
				ShrinkScale.Apply(character, humanoid, root, original.Scale, scaleWeapon)
			end
			for part, saved in original.Physics do
				if part:IsDescendantOf(character) then
					if saved.Custom then
						part.CustomPhysicalProperties = saved.Custom
					else
						part:ResetPropertyToDefault("CustomPhysicalProperties")
					end
				end
			end
			character:SetAttribute("shrink", false)
			table.clear(original.Physics)
		end
		character:SetAttribute("shrink", true)
		Protection.Set(player, ability, nil, character)
	elseif ability == "Invisible" then
		Protection.Set(player, ability, nil, character, config.Transparency)
		PlayerData.Set(player, "Invisible", true)
		effect.restore = function()
			if player then
				PlayerData.Set(player, "Invisible", false)
			end
		end
	elseif ability == "Dash" then
		AbilityEvent:FireAllClients("Visual", player, "Dash", character)
	elseif ability == "Smash" then
		local startRoot = character:FindFirstChild("HumanoidRootPart")
		effect.id, effect.startedAt, effect.impacted = id, now, false
		effect.startPosition = startRoot and startRoot.Position or nil
		effect.deadline = now + config.Duration + SMASH_GRACE
		effect.restore = function()
			-- cancelled / timed out before landing: make every client drop the ground circle
			if not effect.impacted then AbilityEvent:FireAllClients("SmashEnd", player) end
		end
		AbilityEvent:FireAllClients("SmashStart", player, character, config.HitRadius)
	
	elseif ability == "Charge" then
		local _, equippedId = weaponFor(character, player)
		effect.seen, effect.hits = {}, 0
		effect.profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		effect.overlap = OverlapParams.new()
		effect.overlap.FilterType = Enum.RaycastFilterType.Exclude
		effect.overlap.FilterDescendantsInstances = { character }
		effect.obstruction = wallParams()
		-- Shared movement applies RunSpeed from the accepted ability state.
		effect.restore = function()
			-- also runs when the charge is cancelled (ragdolled, frozen, left the arena ...)

			AbilityEvent:FireAllClients("ChargeEnd", player)
		end
		effect.connection = RunService.PostSimulation:Connect(function()
			if not EffectCurrent(player, ability, effect) then
				clearAbility(player, ability)
				return
			end
			runChargeHits(player, character, effect, config)
		end)
		AbilityEvent:FireAllClients("ChargeStart", player, character, config.Duration)
	elseif ability == "Throw" then
		local _, equippedId = weaponFor(character, player)
		local profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" 
			then (equippedId or "Slap") 
			else config.KnockbackProfile
		local strength = math.clamp(config.Strength or 1.35, 1, 1.5)

		effect.seen, effect.hits = {}, 0
		effect.obstruction = wallParams()

		-- 1. Ensure `aim` is a valid 3D Unit Vector with horizontal direction
		local rawAim = position -- 6th argument passed from client Request
		local aim = Vector3.zAxis
		if typeof(rawAim) == "Vector3" and rawAim.Magnitude > 0.01 then
			aim = Vector3.new(rawAim.X, 0, rawAim.Z).Unit
		else
			local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			if rootPart then
				local flatLook = rootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
				if flatLook.Magnitude > 0.01 then
					aim = flatLook.Unit
				end
			end
		end

		local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
		local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
		local origin = if hand and hand:IsA("BasePart") then hand.Position else (rootPart and rootPart.Position + Vector3.new(0, 1, 0) or Vector3.zero)

		-- 2. Check walls to clamp flight range
		local range = config.Range or 55
		local hit = Workspace:Raycast(origin, aim * range, effect.obstruction)
		if hit then range = math.max(6, hit.Distance - 2) end

		local releaseDelay = config.ReleaseTime or 0.3
		local path = ThrowPath.new({
			scope = if PlayerData.Get(player, "IsOnArena") then "Arena" else "Training",
			origin = origin,
			forward = aim,
			range = range,
			curve = math.min(config.Curve or 12, range * 0.3),
			outTime = config.OutTime or 0.55,
			hoverTime = config.HoverTime or 0.3,
			returnTime = config.ReturnTime or 0.7,
			startTime = now + releaseDelay,
			weaponName = equippedId,
		})

		-- 3. Broadcast start to other clients
		for _, other in Players:GetPlayers() do
			if other ~= player then
				AbilityEvent:FireClient(other, "ThrowStart", player, character, path:Params(path.startTime, equippedId))
			end
		end

		-- 4. Server Hit Detection Loop
		local hitRadius = config.HitRadius or 6
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Exclude
		overlap.FilterDescendantsInstances = { character }

		effect.connection = RunService.PostSimulation:Connect(function()
			if not EffectCurrent(player, ability, effect) then
				clearAbility(player, ability)
				return
			end
			local nowTime = time()
			local t = ThrowPath.Elapsed(path.startTime, nowTime, path.scope)
			if t < 0 or Clock.IsStopped(path.scope) then
				return
			end

			local currentRoot = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			local currentHand = currentRoot and (currentRoot.Position + Vector3.new(0, 1, 0)) or origin
			local pos, phase = path:At(t, currentHand)

			if phase == "Wait" then return end
			if phase == "Done" then 
				clearAbility(player, "Throw")
				return 
			end

			-- Safety check for NaN values
			if pos.X ~= pos.X or pos.Y ~= pos.Y or pos.Z ~= pos.Z then return end

			-- Query candidates (Parts & Active Ragdoll Targets)
			local candidates = {}
			for _, part in Workspace:GetPartBoundsInRadius(pos, hitRadius, overlap) do
				if not isWeaponOrAccessory(part) then
					local target = Ragdoll.GetActorFromPart(part)
					if target and target ~= character then
						table.insert(candidates, { actor = target, position = contactPoint(part, pos) })
					end
				end
			end
			for _, candidate in Ragdoll.GetActiveTargetsInBox(CFrame.new(pos), Vector3.one * (hitRadius * 2), character) do
				table.insert(candidates, candidate)
			end

			for _, candidate in candidates do
				local target = candidate.actor
				if effect.seen[target] then continue end

				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if
					targetPlayer
					and (
						Protection.IsProtected(targetPlayer)
						or PlayerData.Get(targetPlayer, "IsInvulnerable")
						or PlayerData.Get(targetPlayer, "TeleportingActive")
					)
				then
					continue
				end

				local targetRoot = target:IsA("BasePart") and target or target:FindFirstChild("HumanoidRootPart")
				if not targetRoot or not targetRoot:IsA("BasePart") then continue end

				local humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health <= 0 then continue end

				-- Compute horizontal knockback direction
				local flingDir = Vector3.new(targetPos.X - pos.X, 0, targetPos.Z - pos.Z)
				if flingDir.Magnitude < 0.01 then flingDir = aim end
				flingDir = flingDir.Unit

				-- Apply ragdoll hit
				if not Ragdoll.ApplyHit(target, flingDir, { weaponId = profileId, strength = strength }) then
					continue
				end

				effect.seen[target] = true
				effect.hits += 1
				CombatService.CancelActor(target)
				target:SetAttribute("LastHitBy", player.Name)

				if PlayerData.Get(player, "IsOnArena") then
					PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
				end

				EffectsEvent:FireAllClients(effect.profileId, candidate.position, flingDir,
					hitEffectWeaponName(character, profileId))
				AbilityEvent:FireAllClients("ThrowImpact", player, candidate.position)
				AbilityEvent:FireClient(player, "ThrowHit", effect.hits)
				if targetPlayer then AbilityEvent:FireClient(targetPlayer, "ThrowVictim") end
			end
		end)
	
	elseif ability == "Push" then
		local _, equippedId = weaponFor(character, player)
		local profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		local strength = math.clamp(config.Strength or 1.4, 1, 1.5)
		local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart

		-- Aim vector validation
		local rawAim = position
		local aim = (typeof(rawAim) == "Vector3" and rawAim.Magnitude > 0.01) and Vector3.new(rawAim.X, 0, rawAim.Z).Unit or (root and root.CFrame.LookVector or Vector3.zAxis)

		-- Replicate start visual to other players
		for _, other in Players:GetPlayers() do
			if other ~= player then
				AbilityEvent:FireClient(other, "PushStart", player, character, {
					aim = aim, range = config.Range, angle = config.Angle,
					releaseTime = config.ReleaseTime, startTime = now,
				})
			end
		end

		local releaseTime = config.ReleaseTime or 0.35
		task.delay(releaseTime, function()
			if not EffectCurrent(player, ability, effect) then
				return
			end

			local currentRoot = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			if not currentRoot then return end

			local range, angle = config.Range or 28, config.Angle or 55
			local origin = currentRoot.Position
			local right = aim:Cross(Vector3.yAxis)
			right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			local seen = {}
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or seen[target] or target == character then
					continue
				end

				seen[target] = true
				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				-- Check angle offset within cone
				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if
					targetPlayer
					and (
						Protection.IsProtected(targetPlayer)
						or PlayerData.Get(targetPlayer, "IsInvulnerable")
						or PlayerData.Get(targetPlayer, "TeleportingActive")
					)
				then
					continue
				end

				if Ragdoll.ApplyHit(target, toTarget.Unit, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if PlayerData.Get(player, "IsOnArena") then
						PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
					end

					EffectsEvent:FireAllClients(profileId, targetPos, toTarget.Unit,
						hitEffectWeaponName(character, profileId))
					AbilityEvent:FireAllClients("PushImpact", player, targetPos)
					if targetPlayer then AbilityEvent:FireClient(targetPlayer, "PushVictim") end
				end
			end

			if hits > 0 then
				AbilityEvent:FireClient(player, "PushHit", hits)
			end
		end)

	elseif ability == "Pull" then
		local _, equippedId = weaponFor(character, player)
		local profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		local strength = math.clamp(config.Strength or 1.25, 1, 1.5)
		local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart

		local rawAim = position
		local aim = (typeof(rawAim) == "Vector3" and rawAim.Magnitude > 0.01) and Vector3.new(rawAim.X, 0, rawAim.Z).Unit or (root and root.CFrame.LookVector or Vector3.zAxis)

		for _, other in Players:GetPlayers() do
			if other ~= player then
				AbilityEvent:FireClient(other, "PullStart", player, character, {
					aim = aim, range = config.Range, angle = config.Angle,
					releaseTime = config.ReleaseTime, startTime = now,
				})
			end
		end

		local releaseTime = config.ReleaseTime or 0.35
		task.delay(releaseTime, function()
			if not EffectCurrent(player, ability, effect) then
				return
			end

			local currentRoot = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			if not currentRoot then return end

			local range, angle = config.Range or 40, config.Angle or 30
			local origin = currentRoot.Position

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			local seen = {}
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or seen[target] or target == character then
					continue
				end

				seen[target] = true
				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if
					targetPlayer
					and (
						Protection.IsProtected(targetPlayer)
						or PlayerData.Get(targetPlayer, "IsInvulnerable")
						or PlayerData.Get(targetPlayer, "TeleportingActive")
					)
				then
					continue
				end

				-- Pull towards the player
				local pullDir = -toTarget.Unit
				if Ragdoll.ApplyHit(target, pullDir, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if PlayerData.Get(player, "IsOnArena") then
						PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
					end

					local stopPoint = origin + aim * 3
					AbilityEvent:FireAllClients("PullHook", player, target, stopPoint)
					if targetPlayer then AbilityEvent:FireClient(targetPlayer, "PullVictim") end
				end
			end

			if hits > 0 then
				AbilityEvent:FireClient(player, "PullHit", hits)
			end
		end)

	elseif ability == "TimeStop" then
		TimeStopService.Start(player, character, config, effect)
	elseif ability == "BigWeapon" then
		startBigWeapon(player, character, config, effect)

	end


	
	AbilityEvent:FireClient(player, "Result", id, true, ability, data.abilityNextReady[ability])
	-- Throw completes on its shared paused path, so a wall-clock timer must not
	-- remove it while TimeStop is holding that path in place.
	if ability == "Throw" then
		return
	end
	local life = config.Duration or 0.25
	if ability == "Smash" then life += SMASH_GRACE end
	task.delay(life, function()
		if abilityData[player] and abilityData[player][ability] == effect then clearAbility(player, ability) end
	end)
end




-- ==========================================
-- SMASH ABILITY
-- ==========================================
local function collectSmashTargets(character, center, radius, reach)
	local found, list = {}, {}
	local function add(actor)
		if actor and actor ~= character and not found[actor] then
			found[actor] = true
			table.insert(list, actor)
		end
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local boxCFrame = CFrame.new(center + Vector3.new(0, reach * 0.5, 0))
	local boxSize = Vector3.new(radius * 2, reach + 4, radius * 2)

	-- 1) physical parts in the area (what M1 does)
	for _, part in Workspace:GetPartBoundsInBox(boxCFrame, boxSize, params) do
		if not isWeaponOrAccessory(part) then add(Ragdoll.GetActorFromPart(part)) end
	end
	-- 2) targets that are already flying / ragdolled (virtual hit bounds)
	for _, candidate in Ragdoll.GetActiveTargetsInBox(boxCFrame, boxSize, character) do add(candidate.actor) end
	-- 3) every registered combat actor
	for _, actor in CollectionService:GetTagged("CombatActor") do add(actor) end
	return list
end

local function smashLog(...)
	if SMASH_DEBUG then warn("[Smash]", ...) end
end

local function runSmashHits(player, character, center, config)
	local radius = config.HitRadius or 15
	local reach = config.VerticalReach or radius
	local minStrength, maxStrength = config.MinStrength or 1, config.MaxStrength or 1.5

	-- same fling as M1: by default the smasher's EQUIPPED weapon decides the profile
	local profileId = config.KnockbackProfile or "Equipped"
	if profileId == "Equipped" then
		local _, equippedId = weaponFor(character, player)
		profileId = equippedId or "Slap"
	end
	local effectId = config.HitEffectWeapon or "Equipped"
	if effectId == "Equipped" then effectId = profileId end

	local root = character:FindFirstChild("HumanoidRootPart")
	local fallbackLook = root and root.CFrame.LookVector or Vector3.zAxis
	local hits = 0

	local candidates = collectSmashTargets(character, center, radius, reach)
	smashLog("candidates found:", #candidates, "- centre:", center)

	for _, target in candidates do
		if not target:IsDescendantOf(Workspace) then continue end
		local position = Ragdoll.GetAuthoritativePosition(target)
		if not position then smashLog("skip (no position):", target:GetFullName()) continue end

		local offset = position - center
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > radius or math.abs(offset.Y) > reach then
			smashLog("skip (out of range):", target.Name, "flat =", math.floor(flat.Magnitude), "dy =", math.floor(offset.Y))
			continue
		end

		local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
		if targetPlayer and (Protection.IsProtected(targetPlayer) or PlayerData.Get(targetPlayer, "IsInvulnerable")
			or PlayerData.Get(targetPlayer, "TeleportingActive")) then
			smashLog("skip (protected):", target.Name)
			continue
		end
		local targetRoot = target:IsA("BasePart") and target or target:FindFirstChild("HumanoidRootPart")
		if not targetRoot or not targetRoot:IsA("BasePart") then continue end
		if targetRoot.Anchored and not Ragdoll.IsKnockbackAnchored(target) then
			smashLog("skip (anchored):", target:GetFullName())
			continue
		end
		local humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then continue end

		local direction = flat
		if direction.Magnitude < 0.05 then direction = Vector3.new(fallbackLook.X, 0, fallbackLook.Z) end
		if direction.Magnitude < 0.05 then direction = Vector3.zAxis end
		direction = direction.Unit

		local falloff = 1 - math.clamp(flat.Magnitude / radius, 0, 1) -- closer = stronger
		local strength = math.clamp(minStrength + (maxStrength - minStrength) * falloff, 1, 1.5) -- ApplyHit only accepts 1 .. 1.5

		if not Ragdoll.ApplyHit(target, direction, { weaponId = profileId, strength = strength }) then
			smashLog("ApplyHit REFUSED for", target:GetFullName(), "profile =", profileId, "strength =", strength)
			continue
		end
		CombatService.CancelActor(target) -- exactly like an M1 hit: the target's own attack is cancelled
		target:SetAttribute("LastHitBy", player.Name)
		if PlayerData.Get(player, "IsOnArena") then
			PlayerData.Set(player, "MatchHits", ((PlayerData.Get(player, "MatchHits") :: number?) or 0) + 1)
		end
		EffectsEvent:FireAllClients(effectId, position, direction, hitEffectWeaponName(character, effectId))
		hits += 1
	end
	smashLog("DONE - launched:", hits, "- profile:", profileId)
	return hits
end

 function CombatService.smashImpact(player, id, ability, character, generation, position)
	if ability ~= "Smash" or not validId(id) then return end
	local config = AbilityConfig.Abilities.Smash
	local effects = abilityData[player]
	local effect = effects and effects.Smash
	if not config then return end
	if not effect then smashLog("rejected: no active smash (cancelled / timed out / ragdolled)") return end
	if effect.id ~= id or effect.impacted or effect.character ~= character then smashLog("rejected: id/character mismatch") return end
	if character ~= player.Character or generation ~= character:GetAttribute("RagdollGeneration") then smashLog("rejected: stale character") return end

	local now = time()
	if now > effect.deadline then smashLog("rejected: too late") return end
	if now - effect.startedAt < (config.ImpactTime or 0.5) * 0.6 then smashLog("rejected: too early") return end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or root.Anchored or not humanoid or humanoid.Health <= 0 then smashLog("rejected: bad character") return end

	-- The landing point comes from shared movement state, never a client report.
	position = Attributes.Get(humanoid, "SASmashPosition")
	if typeof(position) ~= "Vector3" then
		return
	end
	local center = position

	effect.impacted = true
	local hits = runSmashHits(player, character, center, config)

	for _, other in Players:GetPlayers() do
		AbilityEvent:FireClient(other, "SmashImpact", center, config.HitRadius, player)
	end
	AbilityEvent:FireClient(player, "SmashResult", id, hits)
	clearAbility(player, "Smash")
end

-- ==========================================
-- BIG WEAPON ABILITY
-- The equipped weapon grows [Scale] times, then a big circular hit (same ragdoll/fling system as Smash) lands.
-- ==========================================
-- Scale dimensions in the shared callback; joint offsets project the same tracked scale.
local function ResizeWeapon(weapon: Model, targetScale: number, duration: number, interval: number, valid: () -> boolean)
	if not valid() then
		return
	end
	local actor = weapon.Parent
	local record = actor and SimulationState.Records[actor]
	if not actor or not actor:IsA("Model") or not record then
		return
	end
	local base = weapon:GetAttribute("SABaseScale") or weapon:GetScale()
	weapon:SetAttribute("SABaseScale", base)
	SimulationState.Queue(actor, function()
		if record.Weapon ~= weapon then
			return
		end
		local now = time()
		local from = ActorTimelines.Scale(weapon, now, false, (Attributes.Get(record.Root, "SAWeaponScale") :: number?) or 1)
		weapon:SetAttribute("SAScaleFrom", from)
		weapon:SetAttribute("SAScaleTo", targetScale / base)
		weapon:SetAttribute("SAScaleAt", now)
		weapon:SetAttribute("SAScaleDuration", duration)
	end)
end

startBigWeapon = function(player, character, config, effect)
	local weapon = weaponFor(character, player)
	if not weapon then return end
	local main = weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then return end
	local baseScale = weapon:GetScale()
	local baseSize = main.Size
	local gripWeld = main:FindFirstChild("WeaponWeld")
	local gripHost = if gripWeld and gripWeld:IsA("JointInstance") then gripWeld.Part0 else nil
	if not gripHost or not gripHost:IsDescendantOf(character) then return end
	local gripOffset = gripHost.CFrame:ToObjectSpace(main.CFrame)
	-- Snapshot before resizing: client replication may already contain enlarged geometry.
	local baseParts = {}
	for _, part in weapon:GetDescendants() do
		if part:IsA("BasePart") then
			table.insert(baseParts, { part = part, frame = main.CFrame:ToObjectSpace(part.CFrame) })
		end
	end
	local interval = config.ServerScaleInterval or 0
	assert(type(interval) == "number" and interval == interval and interval >= 0 and interval < math.huge,
		"BigWeapon.ServerScaleInterval must be finite and nonnegative")
	local targetScale = baseScale * math.clamp(config.Scale or 3, 0.1, 10)
	effect.weapon, effect.baseScale = weapon, baseScale -- bigWeaponMultiplier (hộp M1) cần 2 giá trị này
	effect.releaseAt = time() + (config.ReleaseTime or 0.45)
	effect.impacted = false
	effect.restore = function()
		local held = effect.weapon
		if held and held.Parent then
			ResizeWeapon(held, baseScale, config.ShrinkTime or 0.25, interval, function()
				return held.Parent == character
			end)
		end
		AbilityEvent:FireAllClients("BigWeaponEnd", player)
	end

	-- Clients reconcile explicit physical dimensions independently of the server's update interval.
	ResizeWeapon(weapon, targetScale, config.GrowTime or 0.3, interval, function()
		return abilityData[player] ~= nil and abilityData[player].BigWeapon == effect and weapon.Parent == character
	end)
	AbilityEvent:FireAllClients("BigWeaponStart", player, character, {
		radius = config.HitRadius, scale = config.Scale, releaseTime = config.ReleaseTime or 0.45,
		weapon = weapon, baseScale = baseScale, baseSize = baseSize, targetScale = targetScale,
		gripHost = gripHost, gripOffset = gripOffset,
		baseParts = baseParts,
	})
end

-- ==========================================
-- TIME TRAVEL ABILITY
-- 1st press: the server remembers where you stand (the ghost). 2nd press: you are moved back to it.
-- If the 2nd press never comes the ghost expires after config.Duration. The cooldown starts when the ability ENDS.
-- ==========================================
startTimeTravel = function(player, character, id, config, data, now, reject)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		reject()
		return
	end
	local effects = abilityData[player]
	local active = effects and effects.TimeTravel

	if active and active.character == character and not active.returned then
		-- 2nd press: back to the ghost
		local from, to = root.CFrame, active.cframe
		active.returned = true
		active.readyAt = now + (config.Cooldown or 10)
		local velocity = root.AssemblyLinearVelocity
		character:PivotTo(to)
		root.AssemblyLinearVelocity = if config.KeepVelocity then velocity else Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		AbilityEvent:FireAllClients("TimeTravelReturn", player, character, { from = from, to = to })
		clearAbility(player, "TimeTravel") -- runs effect.restore: sets the cooldown and tells the clients
		AbilityEvent:FireClient(player, "Result", id, true, "TimeTravel", active.readyAt)
		return
	end

	-- 1st press: leave the ghost
	local duration = config.Duration or 6
	local effect = { character = character, cframe = root.CFrame, expiresAt = now + duration }
	effect.restore = function()
		local readyAt = effect.readyAt or (time() + (config.Cooldown or 10))
		data.abilityNextReady.TimeTravel = readyAt
		AbilityEvent:FireAllClients("TimeTravelEnd", player, effect.returned == true)
		if player.Parent == Players then AbilityEvent:FireClient(player, "TimeTravelCooldown", readyAt) end
	end
	abilityData[player] = abilityData[player] or {}
	abilityData[player].TimeTravel = effect
	AbilityEvent:FireAllClients("TimeTravelSet", player, character, {
		cframe = effect.cframe, expiresAt = effect.expiresAt, duration = duration,
	})
	AbilityEvent:FireClient(player, "Result", id, true, "TimeTravel", data.abilityNextReady.TimeTravel or 0)
	task.delay(duration, function()
		if abilityData[player] and abilityData[player].TimeTravel == effect then clearAbility(player, "TimeTravel") end
	end)
end

function CombatService.Init()
		if initialized then return end
		initializeAttackTimings()
		DetectionService.Init()
		initialized = true
		Ragdoll.Init()

		TimeStopService.Init({
			Ragdoll = Ragdoll,
			AbilityEvent = AbilityEvent,
			EffectsEvent = EffectsEvent,
			onFreeze = function(victimChar)
				CombatService.CancelActor(victimChar)
				local p = Players:GetPlayerFromCharacter(victimChar)
				if p then CombatService.CancelAbilities(p, victimChar) end
			end,
		})
	Simulation.AfterStep(function(dt: number, now: number)
		for _, event in SimulationCombat.Drain() do
			local record = event.Record
			local actor, player = record.Actor, record.Owner
			if
				not player
				or player.Character ~= actor
				or actor:GetAttribute("RagdollGeneration") ~= record.Generation
			then
				continue
			end
			local generation = record.Generation
			local equipment = actor:GetAttribute("WeaponRevision") or 0
			local accepted, reason = true, nil
			if event.Kind == "Start" then
				accepted, reason =
					beginAttack(actor, player, event.Id, generation, equipment, event.At, event.AttackType)
			elseif event.Kind == "Release" then
				accepted, reason = releaseAttack(actor, player, event.Id, generation, equipment, event.At, event.Held)
			elseif event.Kind == "Cancel" then
				CombatService.CancelActor(actor)
			elseif event.Kind == "Ability" then
				activateAbility(player, "Request", event.Id, event.Ability, actor, generation, event.Aim)
			elseif event.Kind == "SmashImpact" then
				local humanoid = record.Humanoid
				CombatService.smashImpact(
					player,
					event.Id,
					"Smash",
					actor,
					generation,
					humanoid and Attributes.Get(humanoid, "SASmashPosition")
				)
			end
			if not accepted then
				local data = dataFor(actor, player)
				AttackEvent:FireClient(player, "Rejected", event.Id, reason, data.nextReady)
				SimulationState.Queue(actor, function()
					if record.Humanoid then
						Attributes.Set(record.Humanoid, "SACharging", false)
						Attributes.Set(record.Humanoid, "SAAttackReadyAt", data.nextReady)
					end
				end)
			end
		end
		for player, effects in abilityData do
			local effect = effects.BigWeapon
			if not effect or effect.impacted or not effect.releaseAt then
				continue
			end
			if
				not EffectCurrent(player, "BigWeapon", effect)
				or not effect.weapon
				or effect.weapon.Parent ~= effect.character
			then
				clearAbility(player, "BigWeapon")
				continue
			end
			if now < effect.releaseAt then
				continue
			end
			-- Commit once on the server, never from a client impact report or replay.
			effect.impacted = true
			local center = Ragdoll.GetAuthoritativePosition(effect.character)
			if center then
				local config = AbilityConfig.Abilities.BigWeapon
				local hits = runSmashHits(player, effect.character, center, config)
				AbilityEvent:FireAllClients("BigWeaponImpact", player, center, config.HitRadius)
				AbilityEvent:FireClient(player, "BigWeaponResult", hits)
			end
		end
		updateSwings()
	end, 30)
	local function attachPlayer(player)
		dataFor(player.Character, player)
		local function changed()
			if not player.Character then return end
			if PlayerData.Get(player, "IsFrozen") or PlayerData.Get(player, "TeleportingActive")
				or not (PlayerData.Get(player, "IsOnArena") or PlayerData.Get(player, "IsInTrainingArea")) then
				CombatService.CancelActor(player.Character)
				CombatService.CancelAbilities(player, player.Character)
			end
		end
		PlayerData.Observe(player, "IsFrozen", changed)
		PlayerData.Observe(player, "TeleportingActive", changed)
		PlayerData.Observe(player, "IsOnArena", changed)
		PlayerData.Observe(player, "IsInTrainingArea", changed)
		player.CharacterAdded:Connect(watchActor)
		player.CharacterRemoving:Connect(function(character)
			CombatService.CancelActor(character)
			CombatService.CancelAbilities(player, character)
			Protection.ClearAll(player)
		end)
		if player.Character then watchActor(player.Character) end
	end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(function(player)
		if player.Character then
			CombatService.CancelActor(player.Character)
		end
		CombatService.CancelAbilities(player)
		Protection.ClearAll(player)
		abilityData[player], playerData[player] = nil, nil
	end)
	for _, player in Players:GetPlayers() do
		attachPlayer(player)
	end
end

return CombatService
