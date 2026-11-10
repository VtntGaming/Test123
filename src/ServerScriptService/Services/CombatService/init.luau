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
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local ShrinkScale = require(Shared.ShrinkScale)
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local JumpAttackCharge = require(Shared:WaitForChild("JumpAttackCharge"))
local CombatConfig = require(Shared:WaitForChild("GameConfig")).Combat
local Ragdoll = require(script.Parent:WaitForChild("RagdollService"))
local Protection = require(script:WaitForChild("Protection"))
local HitboxPrediction = require(script:WaitForChild("HitboxPrediction"))
local DetectionService = require(script.Parent:WaitForChild("DetectionService"))																					
local VisualizeUtils = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("Visualize"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local TimeStopService = require(script:WaitForChild("TimeStopService"))
local ShadowCloneService = require(script:WaitForChild("ShadowCloneService"))
local Clock = require(Shared:WaitForChild("TimeStopClock"))

local MAX_CHARGE, MAX_DISTANCE = CombatConfig.MaxChargeTime, CombatConfig.MaxHitDistance
-- Release timestamps use Workspace:GetServerTimeNow(), not the client's local clock.
local MAX_RELEASE_BACKDATE = 0.25 -- Maximum cooldown compensation in seconds.
local RELEASE_FUTURE_TOLERANCE = 0.05 -- Small clock-sync error; never start cooldown in the future.
local CHARGE_TIME_TOLERANCE = 0.1 -- Maximum difference between reported and server-recorded hold durations.
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
local SMASH_MAX_SNAP = 60      -- max distance of the reported landing from where the smash started / from the server root
local SMASH_DEBUG = true 
local HITBOX_PREVIEW_COLOR = BrickColor.Red().Color

local function canPreviewHitbox(effect)
	if not RunService:IsStudio() then return false end
	if effect then
		local now = os.clock()
		if effect.lastHitboxPreview and now - effect.lastHitboxPreview < 0.1 then return false end
		effect.lastHitboxPreview = now
	end
	return true
end

local function previewHitboxBox(cframe, size, name, effect, lifeTime: number?)
	if canPreviewHitbox(effect) then
		VisualizeUtils.Space(cframe, size, name, HITBOX_PREVIEW_COLOR, lifeTime or 1)
	end
end

local function previewHitboxSphere(position, radius, name, effect, lifeTime: number?)
	if canPreviewHitbox(effect) then
		VisualizeUtils.Sphere(position, radius, name, HITBOX_PREVIEW_COLOR, lifeTime or 1)
	end
end

local function previewHitboxCone(origin, direction, length, angle, name)
	if canPreviewHitbox(nil) then
		VisualizeUtils.Cone(origin, direction, length, angle, name, HITBOX_PREVIEW_COLOR, 1)
	end
end

local function previewHitboxCylinder(position, radius, height, name, lifeTime: number?)
	if canPreviewHitbox(nil) then
		VisualizeUtils.Cylinder(position, radius, height, name, HITBOX_PREVIEW_COLOR, lifeTime or 1)
	end
end

local function initializeAttackTimings()
	local prediction = CombatConfig.HitboxLatencyCompensation
	assert(type(prediction) == "table" and type(prediction.Enable) == "boolean", "Missing hitbox latency settings")
	for _, name in { "MaxPredictionTime", "MaxOffset" } do
		local value = prediction[name]
		assert(type(value) == "number" and value == value and value >= 0 and value < math.huge,
			"Invalid HitboxLatencyCompensation." .. name)
	end
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
	for _, entry in string.split(player:GetAttribute(attribute) or "", ",") do
		if string.match(entry, "^%s*(.-)%s*$") == name then return true end
	end
	return false
end

-- Shadow Clone: a caster and his clones never hurt each other (clones carry the attribute ShadowCloneOwner = UserId).
local function sameOwner(ownerId, target)
	if not ownerId then return false end
	if target:GetAttribute("ShadowCloneOwner") == ownerId then return true end
	local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
	return targetPlayer ~= nil and targetPlayer ~= false and targetPlayer.UserId == ownerId
end
local function isFriendlyFire(player, target)
	return player ~= nil and sameOwner(player.UserId, target)
end

local function dataFor(actor, player)
	if player then
		if not playerData[player] then
			playerData[player] = { nextReady = 0, lastId = 0, abilityLastId = 0, abilityNextReady = {} }
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
	if actor:GetAttribute("IsFrozen") or actor:GetAttribute("MovementLocked") or Ragdoll.IsRagdolled(actor) then return true end
	if player then
		if player.Character ~= actor or player:GetAttribute("DataLoaded") ~= true or player:GetAttribute("IsFrozen")
			or player:GetAttribute("TeleportingActive") then return true end
		if not (player:GetAttribute("IsOnArena") or player:GetAttribute("IsInTrainingArea")) then return true end
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
			player:SetAttribute("ChargeAttack", false)
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
	local data, now = dataFor(actor, player), Workspace:GetServerTimeNow()
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
	local airMotion = JumpAttackCharge.Begin(actor, player == nil)
	if player then
		-- Accept intent immediately; detection observes plausibility without delaying or changing this attack.
		airMotion.airborne = clientAttackType == "JumpAttack"
		DetectionService.TrackAttack(player, actor, id, clientAttackType, clientStartedAt)
	end
	data.charge = {
		id = id, actor = actor, startedAt = now, generation = actualGeneration,
		equipmentRevision = actualRevision, weapon = weapon, weaponId = weaponId,
		-- Player state is observation-only; their owning client handles all charge movement.
		airMotion = airMotion,
		attackType = if airMotion.airborne then "JumpAttack" else "Attack",
	}
	if player then
		player:SetAttribute("ChargeAttack", true)
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
	for _, tag in { "ArenaNPC", "TraningNPC", "LobbyNPC", "TrainingBag", "CombatActor" } do
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
	return math.clamp(weapon:GetScale() / effect.baseScale, 1, 10)
end

local function querySwing(swing)
	local actor, player, root = swing.actor, swing.player, swing.root
	local weaponId, strength = swing.weaponId, swing.strength
	--local boxSize = swing.hitboxSize
	local predictedRoot = HitboxPrediction.GetRootCFrame(root, player, CombatConfig.HitboxLatencyCompensation)
	-- Keep distance/line-of-sight validation anchored to the actual server position.
	local mult = bigWeaponMultiplier(player, swing.weapon)
	local boxSize = swing.hitboxSize * mult
	local origin = root.Position
	local boxCFrame = predictedRoot * CFrame.new(swing.hitboxOffset.Position * mult)
	--local origin, boxCFrame = root.Position, predictedRoot * swing.hitboxOffset -- old
	local overlap = swing.overlap
	local obstruction, seen, hits = wallParams(), swing.seen, {}
	local candidates = {}

	previewHitboxBox(boxCFrame, boxSize, "AttackHitBox", nil)
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
		local weaponHitboxSize = size + Vector3.new(2, 2, 2)
		previewHitboxBox(cf, weaponHitboxSize, "BigWeaponAttackHitBox", nil)
		gather(cf, weaponHitboxSize)
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
		-- a Shadow Clone swinging: never hit the caster or his other clones
		if not player and sameOwner(actor:GetAttribute("ShadowCloneOwner"), target) then continue end
		
		local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
		if targetPlayer then
			if Protection.IsProtected(targetPlayer) then
				seen[target] = true -- this swing was absorbed, never test it again
				continue
			end
			if targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive") then
				continue
			end
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
		local humanoid = target:IsA("Model") and target:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then continue end
		local hitPosition = candidate.position
		local sight = hitPosition - origin
		if sight.Magnitude > 0.01 and Workspace:Raycast(origin, sight, obstruction) then continue end
		local direction = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
		if direction.Magnitude < 0.01 then direction = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
		if direction.Magnitude < 0.01 then direction = Vector3.zAxis end
		
		
		local direction = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
		if direction.Magnitude < 0.01 then direction = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
		if direction.Magnitude < 0.01 then direction = Vector3.zAxis end

		if TimeStopService.InterceptHit(target, direction.Unit, {
			weaponId = weaponId, strength = strength, knockbackMultiplier = swing.knockbackMultiplier,
			}) then
			seen[target] = true
			table.insert(hits, { actor = target, actorId = target:GetAttribute("KnockbackActorId"), position = hitPosition })
			continue
		end
		
		if not Ragdoll.ApplyHit(target, direction.Unit, {
			weaponId = weaponId, strength = strength, knockbackMultiplier = swing.knockbackMultiplier,
		}) then
			continue
		end
		seen[target] = true
		CombatService.CancelActor(target)
		target:SetAttribute("LastHitBy", player and player.Name or actor:GetAttribute("ShadowCloneOwnerName") or actor.Name)
		local creditPlayer = player or Players:GetPlayerByUserId(actor:GetAttribute("ShadowCloneOwner") or 0)
		if creditPlayer and creditPlayer:GetAttribute("IsOnArena") then creditPlayer:SetAttribute("MatchHits", (creditPlayer:GetAttribute("MatchHits") or 0) + 1) end
		EffectsEvent:FireAllClients(weaponId, hitPosition, direction.Unit,
			swing.weapon and swing.weapon:GetAttribute("WeaponName"))
		table.insert(hits, { actor = target, actorId = target:GetAttribute("KnockbackActorId"), position = hitPosition })
		if target:GetAttribute("KnockbackActorKind") == "Bag" or CollectionService:HasTag(target, "TrainingBag") then
			AttackEvent:FireAllClients("BagHit", target, target:GetAttribute("RagdollGeneration"), target:GetAttribute("RagdollRevision"))
		end
	end
	-- bots have no client of their own, but their weapon hit sound must still be heard
	if ((player and player.Parent == Players) or actor:GetAttribute("IsBot") == true) and #hits > 0 then
		if player then AttackEvent:FireClient(player, "Hits", swing.id, actor, swing.generation, weaponId, hits) end
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
	local now = Workspace:GetServerTimeNow()
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

local function cooldownReleaseTime(receivedAt, clientReleasedAt)
	if
		type(clientReleasedAt) ~= "number"
		or clientReleasedAt ~= clientReleasedAt
		or clientReleasedAt < receivedAt - MAX_RELEASE_BACKDATE
		or clientReleasedAt > receivedAt + RELEASE_FUTURE_TOLERANCE
	then
		return receivedAt
	end
	return math.min(clientReleasedAt, receivedAt)
end

local function jumpChargeHeldTime(serverHeldTime, clientHeldTime)
	if type(clientHeldTime) == "number" and clientHeldTime == clientHeldTime
		and clientHeldTime >= 0 and clientHeldTime < math.huge
		and math.abs(clientHeldTime - serverHeldTime) <= CHARGE_TIME_TOLERANCE then
		return clientHeldTime
	end
	return serverHeldTime
end

local function releaseAttack(actor, player, id, generation, equipmentRevision, clientReleasedAt, clientHeldTime)
	local data = dataFor(actor, player)
	local charge = data.charge
	if not charge or charge.id ~= id or charge.actor ~= actor then return false, "Stale" end
	-- Consume release once; wind-up never contributes to charge strength.
	JumpAttackCharge.Stop(charge.airMotion)
	data.charge = nil
	if player then
		player:SetAttribute("ChargeAttack", false)
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
	local now = Workspace:GetServerTimeNow()
	local heldTime = now - charge.startedAt
	local jumpHeldTime = if player then jumpChargeHeldTime(heldTime, clientHeldTime) else heldTime
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
	local releasedAt = player and cooldownReleaseTime(now, clientReleasedAt) or now
	data.nextReady = releasedAt + timing.cooldown * TimeStopService.GetAttackCooldownScale(actor)
	data.swing, activeSwings[actor] = swing, swing

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
	-- the server sees him a bit behind his screen: stretch the box forward (the back edge stays where it is)
	local lead = math.min(speed * (config.LeadTime or 0.1), config.MaxLead or 14)
	local boxCFrame = CFrame.lookAt(root.Position, root.Position + forward) * CFrame.new(offset.X, offset.Y, offset.Z - lead / 2)
	local boxSize = Vector3.new(size.X, size.Y, size.Z + lead)
	previewHitboxBox(boxCFrame, boxSize, "ChargeHitBox", effect)

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
		if targetPlayer then
			if Protection.IsProtected(targetPlayer) then effect.seen[target] = true; continue end
			if targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive") then continue end
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
		if player:GetAttribute("IsOnArena") then
			player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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
	local config, now = AbilityConfig.Abilities[ability], Workspace:GetServerTimeNow()
	local function reject() AbilityEvent:FireClient(player, "Result", id, false, ability, data.abilityNextReady[ability] or now) end
	if (ability ~= "Dash" and ability ~= "Shrink" and ability ~= "Invisible" 
		and ability ~= "MegaJump" and ability ~= "Smash" and ability ~= "Charge" 
		and ability ~= "Throw" and ability ~= "Push" and ability ~= "Pull" 
		and ability ~= "TimeStop" and ability ~= "BigWeapon" and ability ~= "TimeTravel"
		and ability ~= "ShadowClone" and ability ~= "Shield") or not config then reject(); return end

	if typeof(character) ~= "Instance" or not character:IsA("Model") or character ~= player.Character
		or generation ~= character:GetAttribute("RagdollGeneration") or generation == nil
		or player:GetAttribute("EquippedAbility") ~= ability
		or (not owns(player, "OwnedAbilities", ability) and player:GetAttribute("DevAccess") ~= true)
		or isBlocked(character, player) or data.charge
		or now < (data.abilityNextReady[ability] or 0) then reject(); return end
	if data.swing then
		finishSwing(data.swing, false)
	end
	
	if ability == "TimeStop" and not TimeStopService.CanStart(player) then reject(); return end
	if ability == "BigWeapon" and not weaponFor(character, player) then reject(); return end
	-- the clones copy the equipped weapon, so without one there is nothing to summon
	if ability == "ShadowClone" and not weaponFor(character, player) then reject(); return end
	if ability == "TimeTravel" then
		-- two-step ability: the server decides if this press drops the ghost or jumps back to it
		startTimeTravel(player, character, id, config, data, now, reject)
		return
	end
	data.abilityNextReady[ability] = now + config.Cooldown
	clearAbility(player, ability)
	abilityData[player] = abilityData[player] or {}
	local effect = { character = character }
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
		player:SetAttribute("Invisible",true)
		effect.restore = function()
			if player then
				player:SetAttribute("Invisible",false)
			end
		end
	elseif ability == "Dash" then
		AbilityEvent:FireAllClients("Visual", player, "Dash", character)
	elseif ability == "Smash" then
		local startRoot = character:FindFirstChild("HumanoidRootPart")
		effect.id, effect.startedAt, effect.impacted = id, now, false
		effect.startPosition = startRoot and startRoot.Position or nil
		effect.deadline = now + (config.Duration or 1.2) + SMASH_GRACE
		effect.restore = function()
			-- cancelled / timed out before landing: make every client drop the ground circle
			if not effect.impacted then AbilityEvent:FireAllClients("SmashEnd", player) end
		end
		AbilityEvent:FireAllClients("SmashStart", player, character, config.HitRadius)
	
	elseif ability == "Charge" then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local _, equippedId = weaponFor(character, player)
		effect.seen, effect.hits = {}, 0
		effect.profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		effect.overlap = OverlapParams.new()
		effect.overlap.FilterType = Enum.RaycastFilterType.Exclude
		effect.overlap.FilterDescendantsInstances = { character }
		effect.obstruction = wallParams()
		if humanoid then humanoid.WalkSpeed = config.RunSpeed or 100 end
		effect.restore = function()
			-- also runs when the charge is cancelled (ragdolled, frozen, left the arena ...)
			local current = character:FindFirstChildOfClass("Humanoid")
			if current and current.Parent then
				current.WalkSpeed = if character:GetAttribute("IsFrozen") then 0 else GameConfig.Movement.WalkSpeed
			end
			AbilityEvent:FireAllClients("ChargeEnd", player)
		end
		effect.connection = RunService.Heartbeat:Connect(function()
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

		effect.connection = RunService.Heartbeat:Connect(function()
			local nowTime = Workspace:GetServerTimeNow()
			local t = nowTime - path.startTime - Clock.Paused(path.startTime, nowTime)
			if t < 0 or Clock.IsStopped() then return end
			local t = Workspace:GetServerTimeNow() - path.startTime
			if t < 0 then return end

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
			previewHitboxSphere(pos, hitRadius, "ThrowHitBox", effect)

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
				if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable")
					or targetPlayer:GetAttribute("TeleportingActive")) then continue end

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

				if player:GetAttribute("IsOnArena") then
					player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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
			if not effect or effect.character ~= character or isBlocked(character, player) then return end

			local currentRoot = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			if not currentRoot then return end

			local range, angle = config.Range or 28, config.Angle or 55
			local origin = currentRoot.Position
			previewHitboxCone(origin, aim, range, angle, "PushHitBox")
			local right = aim:Cross(Vector3.yAxis)
			right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or target == character then continue end

				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				-- Check angle offset within cone
				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive")) then continue end

				if Ragdoll.ApplyHit(target, toTarget.Unit, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if player:GetAttribute("IsOnArena") then
						player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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

		local _, equippedId = weaponFor(character, player)
		local profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		local strength = math.clamp(config.Strength or 1.4, 1, 1.5)

		-- Aim vector validation
		local rawAim = position
		local aim = (typeof(rawAim) == "Vector3" and rawAim.Magnitude > 0.01) and Vector3.new(rawAim.X, 0, rawAim.Z).Unit or root.CFrame.LookVector

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
			if not effect or effect.character ~= character or isBlocked(character, player) then return end

			local range, angle = config.Range or 28, config.Angle or 55
			local origin = root.Position
			local right = aim:Cross(Vector3.yAxis)
			right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or target == character then continue end

				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				-- Check angle offset within cone
				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive")) then continue end

				if Ragdoll.ApplyHit(target, toTarget.Unit, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if player:GetAttribute("IsOnArena") then
						player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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
			if not effect or effect.character ~= character or isBlocked(character, player) then return end

			local currentRoot = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			if not currentRoot then return end

			local range, angle = config.Range or 40, config.Angle or 30
			local origin = currentRoot.Position

			previewHitboxCone(origin, aim, range, angle, "PullHitBox")
			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or target == character  then continue end

				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive")) then continue end

				-- Pull towards the player
				local pullDir = -toTarget.Unit
				if Ragdoll.ApplyHit(target, pullDir, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if player:GetAttribute("IsOnArena") then
						player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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

		local _, equippedId = weaponFor(character, player)
		local profileId = if (config.KnockbackProfile or "Equipped") == "Equipped" then (equippedId or "Slap") else config.KnockbackProfile
		local strength = math.clamp(config.Strength or 1.25, 1, 1.5)

		local rawAim = position
		local aim = (typeof(rawAim) == "Vector3" and rawAim.Magnitude > 0.01) and Vector3.new(rawAim.X, 0, rawAim.Z).Unit or root.CFrame.LookVector

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
			if not effect or effect.character ~= character or isBlocked(character, player) then return end

			local range, angle = config.Range or 40, config.Angle or 30
			local origin = root.Position

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude
			overlap.FilterDescendantsInstances = { character }

			local hits = 0
			for _, part in Workspace:GetPartBoundsInRadius(origin, range, overlap) do
				if isWeaponOrAccessory(part) then continue end
				local target = Ragdoll.GetActorFromPart(part)
				if not target or target == character then continue end

				local targetPos = Ragdoll.GetAuthoritativePosition(target)
				if not targetPos then continue end

				local toTarget = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
				if toTarget.Magnitude > range or toTarget.Magnitude < 0.1 then continue end
				local dot = aim:Dot(toTarget.Unit)
				if dot < math.cos(math.rad(angle)) then continue end

				local targetPlayer = target:IsA("Model") and Players:GetPlayerFromCharacter(target)
				if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable") or targetPlayer:GetAttribute("TeleportingActive")) then continue end

				-- Pull towards the player (inverted direction)
				local pullDir = -toTarget.Unit
				if Ragdoll.ApplyHit(target, pullDir, { weaponId = profileId, strength = strength }) then
					hits += 1
					CombatService.CancelActor(target)
					target:SetAttribute("LastHitBy", player.Name)
					if player:GetAttribute("IsOnArena") then
						player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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
	elseif ability == "Shield" then
		-- blocks the first hit (see Protection.IsProtected); fades after config.Duration if nobody hits us
		Protection.SetShield(player, character, config.AbsorbWindow)
		effect.restore = function() Protection.ClearShield(player) end
	elseif ability == "BigWeapon" then
		startBigWeapon(player, character, config, effect)
	elseif ability == "ShadowClone" then
		-- clones live in ShadowCloneService (they survive the caster being knocked back, they are cleaned up
		-- when the caster dies / leaves the arena / the duration ends), so no effect.restore is needed here
		ShadowCloneService.Start(player, character, config)

	end


	
	AbilityEvent:FireClient(player, "Result", id, true, ability, data.abilityNextReady[ability])
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
	previewHitboxCylinder(center, radius, reach * 2, "SmashHitBox")

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
		if targetPlayer and (Protection.IsProtected(targetPlayer) or targetPlayer:GetAttribute("IsInvulnerable")
			or targetPlayer:GetAttribute("TeleportingActive")) then
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
		if player:GetAttribute("IsOnArena") then
			player:SetAttribute("MatchHits", (player:GetAttribute("MatchHits") or 0) + 1)
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

	local now = Workspace:GetServerTimeNow()
	if now > effect.deadline then smashLog("rejected: too late") return end
	if now - effect.startedAt < (config.ImpactTime or 0.5) * 0.6 then smashLog("rejected: too early") return end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or root.Anchored or not humanoid or humanoid.Health <= 0 then smashLog("rejected: bad character") return end

	-- NOTE: the dive is fast and the server's copy of the character lags behind the client, so the
	-- landing is validated against the reported position (sane distance + real floor), not the lagging root.
	if typeof(position) ~= "Vector3" or position ~= position then return end
	if (position - root.Position).Magnitude > SMASH_MAX_SNAP
		or (position - (effect.startPosition or root.Position)).Magnitude > SMASH_MAX_SNAP then
		smashLog("rejected: reported position too far")
		return
	end
	local ground = Workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -25, 0), wallParams())
	if not ground then smashLog("rejected: no floor under the reported position") return end
	local center = ground.Position

	effect.impacted = true
	local hits = runSmashHits(player, character, center, config)

	for _, other in Players:GetPlayers() do
		if other ~= player then AbilityEvent:FireClient(other, "SmashImpact", center, config.HitRadius, player) end
	end
	AbilityEvent:FireClient(player, "SmashResult", id, hits)
	clearAbility(player, "Smash")
end

-- ==========================================
-- BIG WEAPON ABILITY
-- The equipped weapon grows [Scale] times, then a big circular hit (same ragdoll/fling system as Smash) lands.
-- ==========================================
-- Scales the weapon model around its Main part (the grip, welded to the hand).
-- WeldConstraints keep the offset they had when they were created, so they are rebuilt after every resize.
local function setWeaponScale(weapon, scale)
	local main = weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then return end
	local hostWeld = main:FindFirstChild("WeaponWeld")
	local hostPart = if hostWeld and hostWeld:IsA("WeldConstraint") then hostWeld.Part0 else nil
	local mainCFrame = main.CFrame
	local assemblyParts = {}
	for _, descendant in weapon:GetDescendants() do
		if descendant:IsA("WeldConstraint") and descendant.Name == "WeaponAssembly" then
			if descendant.Part1 then table.insert(assemblyParts, descendant.Part1) end
			descendant:Destroy()
		end
	end
	if hostWeld then hostWeld:Destroy() end
	weapon:ScaleTo(scale)
	-- keep the grip exactly where it was
	weapon:PivotTo((mainCFrame * main.CFrame:Inverse()) * weapon:GetPivot())
	for _, part in assemblyParts do
		if part.Parent then
			local weld = Instance.new("WeldConstraint")
			weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponAssembly", main, part, part
		end
	end
	if hostPart and hostPart.Parent then
		local weld = Instance.new("WeldConstraint")
		weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponWeld", hostPart, main, main
	end
end

-- One current resize per weapon; newer growth/restoration invalidates older work.
local WeaponScaleJobs: { [Model]: {} } = {}
local function ResizeWeapon(weapon: Model, targetScale: number, duration: number, interval: number, valid: () -> boolean)
	local token = {}
	WeaponScaleJobs[weapon] = token
	if interval == 0 or duration <= 0 or interval >= duration then
		if weapon.Parent and valid() then setWeaponScale(weapon, targetScale) end
		WeaponScaleJobs[weapon] = nil
		return
	end
	local fromScale = weapon:GetScale()
	local startedAt = os.clock()
	task.spawn(function()
		task.wait(interval)
		while WeaponScaleJobs[weapon] == token and weapon.Parent and valid() do
			local elapsed = os.clock() - startedAt
			local progress = math.clamp(elapsed / duration, 0, 1)
			if progress >= 1 then
				setWeaponScale(weapon, targetScale)
				break
			end
			setWeaponScale(weapon, fromScale + (targetScale - fromScale) * progress)
			task.wait(math.min(interval, duration - elapsed))
		end
		if WeaponScaleJobs[weapon] == token then WeaponScaleJobs[weapon] = nil end
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
	local gripHost = if gripWeld and gripWeld:IsA("WeldConstraint") then gripWeld.Part0 else nil
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
	if not root or not root:IsA("BasePart") then reject(); return end
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
		local readyAt = effect.readyAt or (Workspace:GetServerTimeNow() + (config.Cooldown or 10))
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
	ShadowCloneService.Init({
			Ragdoll = Ragdoll,
			BeginAttack = CombatService.BeginNpcAttack,
			ReleaseAttack = CombatService.ReleaseNpcAttack,
			CancelActor = CombatService.CancelActor,
		})
	RunService.Heartbeat:Connect(updateSwings)
	AttackEvent.OnServerEvent:Connect(function(player, action, id, actor, generation, equipmentRevision, clientActionAt, clientChargeData)
		if not allowRequest(player) then return end
		if typeof(actor) ~= "Instance" or not actor:IsA("Model") or actor ~= player.Character then return end
		local data = dataFor(actor, player)
		if action == "Cancel" then
			local pending = data.charge or data.swing
			if
				pending
				and pending.actor == actor
				and pending.id == id
				and pending.generation == generation
				and pending.equipmentRevision == equipmentRevision
			then
				CombatService.CancelActor(actor)
			end
			return
		end
		local accepted, reason
		if action == "Start" then accepted, reason = beginAttack(actor, player, id, generation, equipmentRevision, clientActionAt, clientChargeData)
		elseif action == "Release" then
			accepted, reason = releaseAttack(actor, player, id, generation, equipmentRevision, clientActionAt, clientChargeData)
		else return end
		if not accepted then AttackEvent:FireClient(player, "Rejected", id, reason, data.nextReady) end
	end)
	AbilityEvent.OnServerEvent:Connect(activateAbility)
	local function attachPlayer(player)
		dataFor(player.Character, player)
		local function changed()
			if not player.Character then return end
			if player:GetAttribute("IsFrozen") or player:GetAttribute("TeleportingActive")
				or not (player:GetAttribute("IsOnArena") or player:GetAttribute("IsInTrainingArea")) then
				CombatService.CancelActor(player.Character)
				CombatService.CancelAbilities(player, player.Character)
			end
		end
		player:GetAttributeChangedSignal("IsFrozen"):Connect(changed)
		player:GetAttributeChangedSignal("TeleportingActive"):Connect(changed)
		player:GetAttributeChangedSignal("IsInTrainingArea"):Connect(changed)

		player:GetAttributeChangedSignal("IsOnArena"):Connect(function()
			changed() -- Keep existing cancel logic

			-- Start ability cooldown immediately when entering the arena
			if player:GetAttribute("IsOnArena") then
				local ability = player:GetAttribute("EquippedAbility")
				local config = ability and AbilityConfig.Abilities[ability]
				if config then
					local data = dataFor(player.Character, player)
					data.abilityNextReady[ability] = Workspace:GetServerTimeNow() + config.Cooldown
				end
			end
		end)

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
	--for _, player in Players:GetPlayers() do attachPlayer(player) end
end

return CombatService
