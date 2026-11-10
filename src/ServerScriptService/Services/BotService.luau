--!nonstrict
-- BotService
-- "Fake players": human-looking bots that fill the arena when only ONE real player plays.
--
-- How it plugs into the existing game:
--  * A bot is a clone of Assets.Npcs.Npc with a custom avatar (HumanoidDescription) and a custom name.
--  * It is tagged "ArenaNPC" (+ "BotActor" for client visuals) and has the attribute IsBot = true, so
--    RagdollService / MatchService (lives, void, KO, placement) / NpcService (rig + weapon setup) treat it like any NPC.
--  * NpcService skips its "chase the nearest enemy" AI for IsBot models; THIS module drives them instead.
--  * Melee goes through CombatService.BeginNpcAttack / ReleaseNpcAttack (same hitbox + knockback as every M1).
--  * Behaviour: wanders to random points (never chases), pauses, jumps, avoids edges, hits whatever is within
--    reach after a human-like reaction delay, and uses its ability (Dash / MegaJump / Push / Pull / Charge / Shield).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")
local AbilityEvent = Events:WaitForChild("ActivateAbilityEvent")
local EffectsEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEffects")
local Shared = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local Assets = ReplicatedStorage:WaitForChild("Assets")
local NpcTemplate = Assets:WaitForChild("Npcs"):WaitForChild("Npc")

local SoundService = game:GetService("SoundService") -- ADD THIS LINE
local WeaponsFolder = Assets:WaitForChild("Weapons")
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Ragdoll = require(script.Parent:WaitForChild("RagdollService"))
local Protection = require(script.Parent:WaitForChild("CombatService"):WaitForChild("Protection"))
local BotConfig = require(script.Parent:WaitForChild("Helper"):WaitForChild("BotConfig"))
local BotAnimator = require(script.Parent:WaitForChild("Helper"):WaitForChild("BotAnimator")) -- server-owned locomotion animation (replicates reliably)

local BotService = {}
local initialized = false
local rng = Random.new()
local bots = {} -- [Model] = state
local spawnToken = 0 -- bumped by ClearBots: bots still being built for an old match are discarded

local AI_INTERVAL = 0.1
local EDGE_OFFSETS = { Vector3.new(6, 0, 0), Vector3.new(-6, 0, 0), Vector3.new(0, 0, 6), Vector3.new(0, 0, -6) }

local SUPPORTED = {}
for _, name in BotConfig.SupportedAbilities do SUPPORTED[name] = true end

-- ==========================================
-- SMALL HELPERS
-- ==========================================
local function flatUnit(vector: Vector3): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

local function baseWalkSpeed(model: Model): number
	return if model:GetAttribute("IsFrozen") then 0 else GameConfig.Movement.WalkSpeed
end

-- raycast filter: everything that is a combat actor is ignored so "ground" means real map geometry
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local lastRayRefresh = 0
local function refreshRay()
	local now = os.clock()
	if now - lastRayRefresh < 1 then return end
	lastRayRefresh = now
	local exclude = {}
	for _, actor in CollectionService:GetTagged("CombatActor") do table.insert(exclude, actor) end
	for _, name in { "KnockbackRuntime", "ShadowClones", "ShieldVisuals", "CombatLocalEffects", "CombatEffects", "ClientEffects" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then table.insert(exclude, folder) end
	end
	rayParams.FilterDescendantsInstances = exclude
end

local function groundAt(position: Vector3): Vector3?
	local result = Workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), rayParams)
	return if result then result.Position else nil
end

local boundsFrame, boundsHalf, boundsAt = nil, nil, 0
local function arenaBounds()
	local now = os.clock()
	if now - boundsAt < 3 then return boundsFrame, boundsHalf end
	boundsAt = now
	boundsFrame, boundsHalf = nil, nil
	local arena = Workspace:FindFirstChild(GameConfig.ArenaName)
	if arena and arena:IsA("Model") and arena:FindFirstChildWhichIsA("BasePart", true) then
		local ok, frame, size = pcall(arena.GetBoundingBox, arena)
		if ok and frame then boundsFrame, boundsHalf = frame, size * 0.5 * 0.85 end
	end
	return boundsFrame, boundsHalf
end

local function playAnim(state, id)
	if not id then return end
	local animationId = if type(id) == "number" then "rbxassetid://" .. id else id
	local animator = state.humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action2
		track:Play(0.1)
		task.delay(2, function() track:Stop(0.1); track:Destroy() end)
	end
end

local function faceDirection(state, direction: Vector3)
	local root = state.root
	if root.Parent then root.CFrame = CFrame.lookAt(root.Position, root.Position + direction) end
end

local function usable(state): boolean
	local model = state.model
	return not state.removed and model.Parent ~= nil and not Ragdoll.IsRagdolled(model)
		and not model:GetAttribute("IsFrozen") and not state.root.Anchored
end

-- Client effects for bots: BotController (client) plays the real player VFX/SFX when it receives these.
local function fireFx(kind: string, ...)
	AbilityEvent:FireAllClients("BotFx", kind, ...)
end

-- Same movement rules as the player (GameplayController): a ground jump, then ONE air jump (double jump).
-- Both send "BotJump" so every client plays JumpEffect + the Jump / DoubleJump sound.
local function botJump(state, now: number, allowAir: boolean?): boolean
	local humanoid, root = state.humanoid, state.root
	if now - state.lastJumpAt < 0.25 then return false end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		humanoid.Jump = true
		state.lastJumpAt, state.canDouble = now, true
		AbilityEvent:FireAllClients("BotJump", state.model, false)
		return true
	elseif allowAir and state.canDouble then
		state.lastJumpAt, state.canDouble = now, false
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.sqrt(2 * Workspace.Gravity * GameConfig.Movement.JumpHeight), velocity.Z)
		AbilityEvent:FireAllClients("BotJump", state.model, true)
		return true
	end
	return false
end

local function isEnemyCharging(enemy: Model): boolean
	local player = Players:GetPlayerFromCharacter(enemy)
	if player then return player:GetAttribute("ChargeAttack") == true end
	return enemy:GetAttribute("IsCharging") == true
end

-- ==========================================
-- TARGET RULES (same rules the other abilities use)
-- ==========================================
local function canHit(state, target: Instance): boolean
	if target == state.model or not target:IsA("Model") then return false end
	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then return false end
	local player = Players:GetPlayerFromCharacter(target)
	if player then
		if player:GetAttribute("IsOnArena") ~= true then return false end
		if player:GetAttribute("IsInvulnerable") or player:GetAttribute("TeleportingActive") then return false end
		if Protection.IsProtected(player, true) then return false end -- peek only: a shield is NOT consumed here
	else
		if target:GetAttribute("IsOnArena") ~= true then return false end
		if (target:GetAttribute("Lives") or 1) <= 0 then return false end
	end
	local root = target:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return false end
	if root.Anchored and not Ragdoll.IsKnockbackAnchored(target) then return false end
	return true
end

-- A bot's Shield blocks the first hit (CombatService.querySwing has the same check for M1 hits).
local function absorbBotShield(target: Model)
	target:SetAttribute("BotShield", false)
	target:SetAttribute("ShieldBreak", (target:GetAttribute("ShieldBreak") or 0) + 1) -- counter first, then the flag
	target:SetAttribute("ShieldActive", false)
end

-- Knockback a target exactly like the other abilities do (ApplyHit + cancel its attack + credit + hit effect).
local function launch(state, target: Model, direction: Vector3, strength: number, hitPosition: Vector3): boolean
	local player = Players:GetPlayerFromCharacter(target)
	if player then
		if Protection.IsProtected(player) then return false end -- consumes the player's shield, blocks this hit
	elseif target:GetAttribute("BotShield") == true then
		absorbBotShield(target)
		return false
	end
	local flat = flatUnit(direction)
	if not flat then return false end
	if not Ragdoll.ApplyHit(target, flat, { weaponId = state.weaponId, strength = math.clamp(strength, 1, 1.5) }) then
		return false
	end
	CombatService.CancelActor(target)
	target:SetAttribute("LastHitBy", state.model.Name)
	EffectsEvent:FireAllClients(state.weaponId, hitPosition, flat, state.weaponName)
	return true
end

local function nearestEnemy(state, origin: Vector3, maxDistance: number)
	local best, bestDistance, bestPosition = nil, maxDistance, nil
	for _, actor in CollectionService:GetTagged("CombatActor") do
		if actor ~= state.model and actor:IsDescendantOf(Workspace) and canHit(state, actor)
			and not Ragdoll.IsRagdolled(actor) then
			local position = Ragdoll.GetAuthoritativePosition(actor)
			if position and math.abs(position.Y - origin.Y) < 10 then
				local distance = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z).Magnitude
				if distance < bestDistance then best, bestDistance, bestPosition = actor, distance, position end
			end
		end
	end
	return best, bestDistance, bestPosition
end

local function forEachInCone(state, origin: Vector3, aim: Vector3, range: number, angle: number, callback)
	local minDot = math.cos(math.rad(angle))
	for _, actor in CollectionService:GetTagged("CombatActor") do
		if actor ~= state.model and actor:IsDescendantOf(Workspace) and canHit(state, actor) then
			local position = Ragdoll.GetAuthoritativePosition(actor)
			if position then
				local flat = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
				if flat.Magnitude <= range and flat.Magnitude > 0.1 and aim:Dot(flat.Unit) >= minDot then
					callback(actor, flat.Unit, position)
				end
			end
		end
	end
end
-- ==========================================
-- WEAPON SKIN EQUIPPING
-- ==========================================
-- ==========================================
-- WEAPON SKIN EQUIPPING
-- ==========================================
local function equipBotWeapon(state)
	local model = state.model
	local hand = model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
	if not hand then return false end

	local template = WeaponsFolder:FindFirstChild(state.weaponName) or WeaponsFolder:FindFirstChild(state.weaponId)
	if not template then return false end

	local old = model:FindFirstChild("EquippedWeapon")
	if old then old:Destroy() end

	local newWeapon = template:Clone() :: Model
	local main = newWeapon:FindFirstChild("Main")
	if not main then newWeapon:Destroy(); return false end

	newWeapon.Name = "EquippedWeapon"
	newWeapon:SetAttribute("WeaponId", state.weaponId)

	-- FIX: Tell CombatService/RagdollService this is just a base weapon so it doesn't crash!
	newWeapon:SetAttribute("WeaponName", state.weaponId) 

	-- We use this custom attribute to track the skin instead
	newWeapon:SetAttribute("BotSkinApplied", state.weaponName) 

	for _, part in newWeapon:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide, part.CanTouch, part.CanQuery, part.Massless, part.Anchored = false, false, false, true, false
			if part ~= main then
				local weld = Instance.new("WeldConstraint")
				weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponAssembly", main, part, part
			end
		end
	end

	newWeapon.Parent = model

	local rotation = state.weaponId == "Slap" and CFrame.Angles(math.rad(90), 0, math.rad(90))
		or CFrame.Angles(math.rad(90), math.rad(-45), 0)
	newWeapon:PivotTo(hand.CFrame)
	-- main.CFrame = hand.CFrame * CFrame.new(-0.5, -0.5, 1.1) * rotation

	local weld = Instance.new("WeldConstraint")
	weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponWeld", hand, main, main

	local info = WeaponConfig.GetWeaponInfo(state.weaponName)
	if info then
		-- Base Hit Sound
		local sfxFolder = SoundService:FindFirstChild("SFX")
		if sfxFolder then
			local soundTemplate = sfxFolder:FindFirstChild(info.HitSound)
			if soundTemplate and soundTemplate:IsA("Sound") then
				local sound = soundTemplate:Clone()
				sound.Name = info.HitSound
				sound.Looped = false
				sound.Parent = main
			end
		end

		-- Weapon Variant Hit Sound (Matches the folder structure from your image)
		local sfxAssets = Assets:FindFirstChild("SFX")
		local effectsLibrary = sfxAssets and sfxAssets:FindFirstChild("WeaponEffects")

		if effectsLibrary then
			local effectTemplate = effectsLibrary:FindFirstChild(info.Variant)
			if effectTemplate and effectTemplate:IsA("Sound") then
				local sound = effectTemplate:Clone()
				sound.Name = "WeaponEffectHit"
				sound.Looped = false
				sound.Parent = main
			end
		end
	end

	return true
end


-- ==========================================
-- ABILITIES (server driven, no Player needed)
-- ==========================================
local Abilities = {}

function Abilities.Dash(state, config, direction)
	local root, humanoid = state.root, state.humanoid
	faceDirection(state, direction)
	humanoid:MoveTo(root.Position)
	AbilityEvent:FireAllClients("Visual", false, "Dash", state.model) -- client draws the dash hologram trail
	local untilTime = os.clock() + (config.Duration or 0.2)
	state.busyUntil = untilTime + 0.1
	task.spawn(function()
		while os.clock() < untilTime and usable(state) do
			local velocity = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(direction.X * config.Velocity, velocity.Y, direction.Z * config.Velocity)
			task.wait()
		end
	end)
end

function Abilities.MegaJump(state, config)
	local root = state.root
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, config.Force or 120, velocity.Z)
	state.busyUntil = os.clock() + 0.4
	AbilityEvent:FireAllClients("BotJump", state.model, true)
end

local function castCone(state, config, direction, pull: boolean)
	local root, humanoid = state.root, state.humanoid
	faceDirection(state, direction)
	humanoid:MoveTo(root.Position)
	playAnim(state, config.Animation)
	state.busyUntil = os.clock() + (config.Duration or 0.5)
	fireFx(if pull then "PullStart" else "PushStart", state.model, {
		aim = direction, range = config.Range, angle = config.Angle,
		releaseTime = config.ReleaseTime or 0.35, startTime = Workspace:GetServerTimeNow(),
	})
	task.delay(config.ReleaseTime or 0.35, function()
		if not usable(state) then return end
		local origin = root.Position
		forEachInCone(state, origin, direction, config.Range or 28, config.Angle or 55, function(actor, flatDirection, position)
			local pushDirection = if pull then -flatDirection else flatDirection
			if launch(state, actor, pushDirection, config.Strength or 1.2, position) then
				if pull then fireFx("PullHook", state.model, actor, origin + direction * 3)
				else fireFx("PushImpact", state.model, position) end
			end
		end)
	end)
end

function Abilities.Push(state, config, direction) castCone(state, config, direction, false) end
function Abilities.Pull(state, config, direction) castCone(state, config, direction, true) end

function Abilities.Charge(state, config, direction)
	local root, humanoid, model = state.root, state.humanoid, state.model
	local size = config.HitboxSize or Vector3.new(8, 6, 9)
	local right = direction:Cross(Vector3.yAxis)
	local seen = {}
	local duration = config.Duration or 2
	local startedAt = os.clock()
	state.busyUntil = startedAt + duration + 0.2
	humanoid.WalkSpeed = config.RunSpeed or 40
	fireFx("ChargeStart", model, duration)
	faceDirection(state, direction)
	task.spawn(function()
		while os.clock() - startedAt < duration and usable(state) do
			refreshRay()
			if not groundAt(root.Position + direction * 10) then break end -- never run off the edge
			humanoid:MoveTo(root.Position + direction * 30)
			for _, actor in CollectionService:GetTagged("CombatActor") do
				if actor ~= model and not seen[actor] and actor:IsDescendantOf(Workspace) and canHit(state, actor) then
					local position = Ragdoll.GetAuthoritativePosition(actor)
					if position then
						local offset = position - root.Position
						local forward, side = offset:Dot(direction), offset:Dot(right)
						if forward > -1 and forward < size.Z + 1 and math.abs(side) < size.X * 0.5 + 1 and math.abs(offset.Y) < size.Y then
							local knock = flatUnit(direction + right * math.clamp(side / 4, -1, 1) * (config.SideKnock or 0.6)) or direction
							if launch(state, actor, knock, config.Strength or 1.35, position) then
								seen[actor] = true
								fireFx("ChargeImpact", model, position)
							end
						end
					end
				end
			end
			task.wait(0.05)
		end
		if model.Parent then
			humanoid.WalkSpeed = baseWalkSpeed(model)
			humanoid:MoveTo(root.Position)
		end
		state.busyUntil = 0
		fireFx("ChargeEnd", model)
	end)
end

function Abilities.Shield(state, config)
	local model = state.model
	state.shieldToken = (state.shieldToken or 0) + 1
	local token = state.shieldToken
	model:SetAttribute("BotShield", true)
	model:SetAttribute("ShieldActive", true)
	task.delay(config.Duration or 12, function()
		if state.shieldToken == token and model.Parent and model:GetAttribute("BotShield") == true then
			model:SetAttribute("BotShield", false)
			model:SetAttribute("ShieldActive", false) -- expired quietly (no ShieldBreak bump)
		end
	end)
end

-- abilities are a spice, M1 is the bread and butter: longer, randomised cooldowns
local function abilityCooldown(config): number
	return math.max(config.Cooldown or 0, BotConfig.MinAbilityCooldown or 8) * 1.25 + rng:NextNumber(2, 6)
end

local function dashSafe(origin: Vector3, direction: Vector3, config): boolean
	local distance = (config.Velocity or 75) * (config.Duration or 0.2) + 6
	return groundAt(origin + direction * distance) ~= nil
end

-- Decides whether the bot casts its ability right now. Returns true when it did.
-- ctx (optional): { enemyOnEdge = bool, threatened = bool } -> the situation decides WHICH skill makes sense
local function tryAbility(state, now: number, origin: Vector3, enemy, distance: number?, enemyPosition: Vector3?, ctx: { [string]: any }?): boolean
	local name = state.abilityName
	ctx = ctx or {}
	-- under attack only the defensive skills make sense (Shield / Dash away / Push the attacker back)
	if ctx.threatened and name ~= "Shield" and name ~= "Dash" and name ~= "Push" then return false end
	if not name or now < state.abilityReadyAt then return false end
	local config = AbilityConfig.Abilities[name]
	if not config then return false end

	local toEnemy = if enemyPosition then flatUnit(enemyPosition - origin) else nil
	local cast, direction = false, toEnemy

	if name == "Push" then
		cast = enemy ~= nil and distance <= 12 and (ctx.enemyOnEdge or ctx.threatened or rng:NextNumber() < 0.55)
	elseif name == "Pull" then
		-- pulling someone who stands on the edge would drag him back to safety: don't
		cast = enemy ~= nil and distance >= 10 and distance <= (config.Range or 40) - 8 and not ctx.enemyOnEdge and rng:NextNumber() < 0.4
	elseif name == "Charge" then
		cast = enemy ~= nil and distance >= 12 and distance <= 38 and toEnemy ~= nil
			and groundAt(origin + toEnemy * 10) ~= nil and (ctx.enemyOnEdge or rng:NextNumber() < 0.35)
	elseif name == "Shield" then
		cast = ctx.threatened == true or (enemy ~= nil and distance <= 14 and rng:NextNumber() < 0.1)
	elseif name == "Dash" then
		if enemy and toEnemy and (ctx.threatened or (distance <= 14 and isEnemyCharging(enemy) and rng:NextNumber() < 0.6)) then
			-- dodge: dash sideways away from an incoming swing
			local side = toEnemy:Cross(Vector3.yAxis) * (if rng:NextNumber() < 0.5 then 1 else -1)
			direction = side
			cast = dashSafe(origin, side, config)
		elseif not enemy and rng:NextNumber() < 0.04 then
			-- just moving around: dash towards where it is walking
			direction = if state.wanderTarget then flatUnit(state.wanderTarget - origin) else nil
			cast = direction ~= nil and dashSafe(origin, direction, config)
		end
	elseif name == "MegaJump" then
		cast = rng:NextNumber() < (if enemy then 0.08 else 0.03)
	end

	if not cast then return false end
	if name ~= "Shield" and name ~= "MegaJump" and not direction then return false end

	state.abilityReadyAt = now + abilityCooldown(config)
	Abilities[name](state, config, direction)
	return true
end

-- ==========================================
-- MELEE (same pipeline as NpcService)
-- ==========================================
local function resetAttack(state)
	local model = state.model
	if state.attackId or model:GetAttribute("IsCharging") then
		CombatService.CancelActor(model)
		state.attackId = nil
		model:SetAttribute("IsCharging", false)
		NpcAttackEvent:FireAllClients(model, state.weaponId, "Cancel")
	end
end

local function beginAttack(state, target, now: number)
	local model = state.model
	local attackId = CombatService.BeginNpcAttack(model)
	if not attackId then return end
	-- a target standing on the edge is worth a full-power swing
	local duration = if state.targetOnEdge then rng:NextNumber((BotConfig.ChargeMin + BotConfig.ChargeMax) * 0.5, BotConfig.ChargeMax)
		else rng:NextNumber(BotConfig.ChargeMin, BotConfig.ChargeMax)
	state.attackId, state.releaseAt, state.attackTarget = attackId, now + duration, target
	model:SetAttribute("IsCharging", true)
	model:SetAttribute("ChargeStartTime", now)
	model:SetAttribute("ChargeDuration", duration)
	NpcAttackEvent:FireAllClients(model, state.weaponId, "Charge")
end

local function releaseAttack(state, now: number)
	local model, attackId = state.model, state.attackId
	state.attackId, state.attackTarget = nil, nil
	model:SetAttribute("IsCharging", false)
	model:SetAttribute("LastAttackTime", now)
	state.lastAttack = now
	if CombatService.ReleaseNpcAttack(model, attackId) then
		NpcAttackEvent:FireAllClients(model, state.weaponId, "Release")
	else
		NpcAttackEvent:FireAllClients(model, state.weaponId, "Cancel")
	end
end

-- ==========================================
-- WANDERING (random, never chases)
-- ==========================================
local function pickWanderPoint(origin: Vector3): Vector3?
	refreshRay()
	local frame, half = arenaBounds()
	for _ = 1, 14 do
		local candidate
		if frame and rng:NextNumber() < 0.25 then
			candidate = frame:PointToWorldSpace(Vector3.new(rng:NextNumber(-1, 1) * half.X, 0, rng:NextNumber(-1, 1) * half.Z))
		else
			local angle, radius = rng:NextNumber(0, math.pi * 2), rng:NextNumber(12, 45)
			candidate = origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		end
		local ground = groundAt(Vector3.new(candidate.X, origin.Y, candidate.Z))
		if ground and math.abs(ground.Y - origin.Y) <= 10 then
			local safe = true
			for _, offset in EDGE_OFFSETS do
				if not groundAt(Vector3.new(ground.X + offset.X, origin.Y, ground.Z + offset.Z)) then safe = false; break end
			end
			if safe then return ground end
		end
	end
	return nil
end

local function wander(state, now: number, origin: Vector3)
	local humanoid, root = state.humanoid, state.root
	if state.pauseUntil > now then
		humanoid:MoveTo(root.Position)
		return
	end

	local target = state.wanderTarget
	local arrived = target ~= nil and Vector3.new(target.X - origin.X, 0, target.Z - origin.Z).Magnitude < 3
	if not target or arrived or now >= state.wanderExpire then
		if arrived and rng:NextNumber() < BotConfig.PauseChance then
			state.pauseUntil = now + rng:NextNumber(BotConfig.PauseMin, BotConfig.PauseMax)
			state.wanderTarget = nil
			humanoid:MoveTo(root.Position)
			return
		end
		target = pickWanderPoint(origin)
		state.wanderTarget = target
		state.wanderExpire = now + rng:NextNumber(4, 9)
		state.lastCheckPos, state.lastCheckAt = origin, now
	end
	if not target then
		humanoid:MoveTo(root.Position)
		return
	end

	-- edge guard: never walk towards the void
	local direction = flatUnit(target - origin)
	if direction and not groundAt(origin + direction * 7) then
		state.wanderTarget = nil
		state.pauseUntil = now + 0.3
		humanoid:MoveTo(root.Position)
		return
	end
	humanoid:MoveTo(target)

	-- stuck on an obstacle: jump and pick another point
	if now - state.lastCheckAt >= 1 then
		if state.lastCheckPos and (origin - state.lastCheckPos).Magnitude < 2 then
			botJump(state, now, true)
			state.wanderTarget = nil
		end
		state.lastCheckPos, state.lastCheckAt = origin, now
	end

	-- the odd random hop, like a real player
	if now >= state.nextJumpAt then
		botJump(state, now)
		state.nextJumpAt = now + rng:NextNumber(3, 10)
		if rng:NextNumber() < (BotConfig.DoubleJumpChance or 0.5) then state.doubleJumpAt = now + rng:NextNumber(0.25, 0.5) end
	end
end

-- ==========================================
-- BRAIN
-- ==========================================
-- ==========================================
-- SMART BEHAVIOUR (threats, target choice, intent)
-- ==========================================
-- is any part of the ring around us missing ground? (smaller than the wander check: only real edges count)
local function nearEdge(origin: Vector3): boolean
	for _, offset in EDGE_OFFSETS do
		if not groundAt(Vector3.new(origin.X + offset.X * 0.65, origin.Y, origin.Z + offset.Z * 0.65)) then return true end
	end
	return false
end

local function arenaCenter(origin: Vector3): Vector3?
	local frame = arenaBounds()
	if frame then
		local ground = groundAt(Vector3.new(frame.Position.X, origin.Y, frame.Position.Z))
		if ground then return ground end
	end
	return pickWanderPoint(origin)
end

-- Something that is about to hit us: a facing enemy winding up a swing, or one rushing at us (Dash / Charge).
local function scanThreat(state, origin: Vector3)
	local best, bestDistance, bestPosition = nil, math.huge, nil
	for _, actor in CollectionService:GetTagged("CombatActor") do
		if actor ~= state.model and actor:IsDescendantOf(Workspace) and not Ragdoll.IsRagdolled(actor) then
			local root = actor:FindFirstChild("HumanoidRootPart")
			local position = Ragdoll.GetAuthoritativePosition(actor)
			if root and position and math.abs(position.Y - origin.Y) < 8 then
				local toBot = Vector3.new(origin.X - position.X, 0, origin.Z - position.Z)
				local distance = toBot.Magnitude
				if distance > 0.5 and distance < bestDistance then
					local unit = toBot.Unit
					local look = flatUnit(root.CFrame.LookVector)
					local velocity = root.AssemblyLinearVelocity
					local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
					local swinging = isEnemyCharging(actor) and distance <= 15 and look ~= nil and look:Dot(unit) > 0.5
					local rushing = flatVelocity.Magnitude > 45 and distance <= 38 and flatVelocity.Unit:Dot(unit) > 0.7
					if swinging or rushing then best, bestDistance, bestPosition = actor, distance, position end
				end
			end
		end
	end
	return best, bestDistance, bestPosition
end

-- React to a threat: Shield / Dash / Push if the skill fits, otherwise side-step (+ jump, sometimes a double jump).
local function dodge(state, now: number, origin: Vector3, threatActor, threatPosition: Vector3)
	local toThreat = flatUnit(threatPosition - origin)
	if tryAbility(state, now, origin, threatActor, (threatPosition - origin).Magnitude, threatPosition, { threatened = true }) then return end
	if not toThreat then return end
	refreshRay()
	local side = toThreat:Cross(Vector3.yAxis) * (if rng:NextNumber() < 0.5 then 1 else -1)
	if not groundAt(origin + side * 8) then side = -side end
	if not groundAt(origin + side * 8) then side = -toThreat end -- cornered: back off
	state.dodgeDir = side
	state.dodgeUntil = now + rng:NextNumber(0.35, 0.55)
	state.wanderTarget = nil
	if botJump(state, now) and rng:NextNumber() < (BotConfig.DoubleJumpChance or 0.5) then
		state.doubleJumpAt = now + rng:NextNumber(0.2, 0.35)
	end
end

-- Who to fight: the nearest enemy, but one standing on the edge of the map is a juicy target (knock-off = a life).
local function pickTarget(state, origin: Vector3, maxDistance: number)
	local best, bestScore, bestDistance, bestPosition, bestEdge = nil, math.huge, 0, nil, false
	for _, actor in CollectionService:GetTagged("CombatActor") do
		if actor ~= state.model and actor:IsDescendantOf(Workspace) and canHit(state, actor) and not Ragdoll.IsRagdolled(actor) then
			local position = Ragdoll.GetAuthoritativePosition(actor)
			if position and math.abs(position.Y - origin.Y) < 10 then
				local flat = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
				local distance = flat.Magnitude
				if distance < maxDistance then
					local direction = flatUnit(flat)
					local onEdge = direction ~= nil and groundAt(position + direction * 7) == nil
					local score = distance - (if onEdge then 12 else 0)
					if score < bestScore then best, bestScore, bestDistance, bestPosition, bestEdge = actor, score, distance, position, onEdge end
				end
			end
		end
	end
	state.targetOnEdge = bestEdge
	return best, bestDistance, bestPosition
end

-- Decides (rarely) to walk up to an enemy or back away from one. The result lives in approachUntil / retreatUntil.
-- Combat rhythm: mostly FIGHT (close in + M1), with short KITE windows (back off) every now and then.
local function updatePhase(state, now: number, enemy)
	if not enemy then state.phase, state.phaseUntil = "fight", 0; return end
	if now < state.phaseUntil then return end
	if state.phase == "fight" then
		local lives = state.model:GetAttribute("Lives") or 3
		local kiteChance = if lives <= (BotConfig.RetreatWhenLives or 1) then 0.4 else 0.18
		if rng:NextNumber() < kiteChance then
			state.phase, state.phaseUntil = "kite", now + rng:NextNumber(1, 2.2)
			state.approachUntil = 0
		else
			state.phaseUntil = now + rng:NextNumber(3, 6)
		end
	else
		state.phase, state.phaseUntil = "fight", now + rng:NextNumber(4, 8)
		state.retreatUntil = 0
	end
end

local function planIntent(state, now: number, enemy, distance: number?, enemyPosition: Vector3?)
	if not enemy or not distance then state.approachUntil, state.retreatUntil = 0, 0; return end
	updatePhase(state, now, enemy)
	if state.phase == "kite" then
		if distance < 16 and not (state.retreatUntil > now) then state.retreatUntil = state.phaseUntil end
		return
	end
	if state.approachUntil > now then return end
	if distance <= math.max(BotConfig.ApproachRange or 24, 32) and distance > state.attackRange * 0.8
		and rng:NextNumber() < math.clamp(state.aggression + 0.3, 0.5, 1) then
		state.approachUntil = now + rng:NextNumber(1.5, 3)
	end
end

-- Purposeful movement. Returns true when it moved the bot (so the random wander is skipped).
local function intentStep(state, now: number, origin: Vector3): boolean
	local humanoid = state.humanoid
	refreshRay()
	-- 1. evade: never hang around the edge, walk back towards the middle of the map
	if nearEdge(origin) then
		local target = arenaCenter(origin)
		if target then
			humanoid:MoveTo(target)
			state.wanderTarget = nil
			return true
		end
		return false
	end
	local enemy = state.enemy
	if not (enemy and enemy.Parent and state.enemyPos and now - state.enemyAt < 0.7) then return false end
	-- 2. retreat
	local away = flatUnit(origin - state.enemyPos)
	if state.retreatUntil > now and away and groundAt(origin + away * 9) then
		humanoid:MoveTo(origin + away * 10)
		state.wanderTarget = nil
		return true
	end
	-- 3. approach (stops at striking distance; the attack code takes over from there)
	if state.approachUntil > now then
		local toward = flatUnit(state.enemyPos - origin)
		if toward and state.enemyDist > state.attackRange * 0.8 and groundAt(origin + toward * 6) then
			humanoid:MoveTo(state.enemyPos)
			state.wanderTarget = nil
			if now >= state.nextJumpAt then -- bunny hop while closing in
				botJump(state, now)
				state.nextJumpAt = now + rng:NextNumber(1.5, 4)
				if rng:NextNumber() < (BotConfig.DoubleJumpChance or 0.5) then state.doubleJumpAt = now + rng:NextNumber(0.25, 0.45) end
			end
			return true
		end
	end
	return false
end

local function removeBot(state)
	if state.removed then return end
	state.removed = true
	if state.idleTrack then -- Stop the animation to prevent memory leaks
		pcall(function() state.idleTrack:Stop(); state.idleTrack:Destroy() end)
		state.idleTrack = nil
	end
	if state.animator then state.animator:destroy(); state.animator = nil end
	bots[state.model] = nil
	for _, connection in state.connections do connection:Disconnect() end
	table.clear(state.connections)
end
local function ensureIdleAnimation(state)
	
	if state.idleTrack then
		if not state.idleTrack.IsPlaying then
			state.idleTrack:Play()
		end
		return
	end

	local info = WeaponConfig.GetWeaponInfo(state.weaponId)
	if not info or not info.Idle then return end

	local animator = state.humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	local anim = Instance.new("Animation")
	anim.AnimationId = info.Idle
	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play()
	state.idleTrack = track
	anim:Destroy()
end


-- Weapon hold pose. It uses Action priority, so it would override the run clip: only play it while standing still.
local function ensureWeaponHold(state)
	local locomotion = state.animator
	local animator = locomotion and locomotion.animator
	if not animator then return end
	local want = locomotion.current == "Idle" and not state.model:GetAttribute("IsRagdolled")
	local track = state.idleTrack
	-- AnimationTrack.Parent is always nil, so remember which Animator the track was loaded on instead
	if track and state.idleAnimator ~= animator then -- Animator was replaced: reload
		pcall(function() track:Stop(0); track:Destroy() end)
		track, state.idleTrack, state.idleAnimator = nil, nil, nil
	end
	if not track then
		if not want then return end
		local info = WeaponConfig.GetWeaponInfo(state.weaponId)
		if not info or not info.Idle then return end
		local anim = Instance.new("Animation")
		anim.AnimationId = info.Idle
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		anim:Destroy()
		if not ok or not loaded then return end
		loaded.Priority, loaded.Looped = Enum.AnimationPriority.Action, true
		state.idleTrack, track = loaded, loaded
		state.idleAnimator = animator
	end
	if want then
		if not track.IsPlaying then track:Play(0.15) end
	elseif track.IsPlaying then
		track:Stop(0.15)
	end
end

-- ==========================================
-- ARENA RESPAWN WATCHDOG
-- ==========================================
-- Safety net: MatchService normally puts a knocked-off bot back on the arena. If a bot is still below the void line
-- after a short grace time (MatchService missed it), it is brought back here. Lives are NOT touched (MatchService owns them).
local function arenaSpawnPoint(): CFrame?
	local area = Workspace:FindFirstChild(GameConfig.ArenaName)
	local spawnPart = area and area:FindFirstChild("Spawn")
	if not spawnPart or not spawnPart:IsA("BasePart") then return nil end
	return spawnPart.CFrame * CFrame.new(rng:NextInteger(-4, 4), 5, rng:NextInteger(-4, 4))
end

-- ==========================================
-- ELIMINATED BOTS APPEAR IN THE LOBBY (like eliminated players)
-- ==========================================
-- MatchService destroys a bot right after its last life is lost. We copy it into the lobby first.
-- Copies are inert (no tags, no weapon, no attributes) and are removed by ClearBots when the match is cleaned up.
local lobbyBots = {}

local function spawnLobbyCopy(model: Model)
	local area = Workspace:FindFirstChild(GameConfig.LobbyName)
	local spawnPart = area and area:FindFirstChild("Spawn")
	if not spawnPart or not spawnPart:IsA("BasePart") then return end
	model.Archivable = true
	local copy = model:Clone()
	if not copy then return end
	for _, tag in CollectionService:GetTags(copy) do CollectionService:RemoveTag(copy, tag) end
	for name in copy:GetAttributes() do copy:SetAttribute(name, nil) end
	for _, child in copy:GetDescendants() do
		if child.Name == "EquippedWeapon" and child:IsA("Model") then child:Destroy() end
	end
	local humanoid = copy:FindFirstChildOfClass("Humanoid")
	local root = copy:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then copy:Destroy(); return end
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = 0
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	local stock = copy:FindFirstChild("Animate")
	if stock and stock:IsA("BaseScript") then stock.Enabled = true end
	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = rng:NextNumber(6, 18)
	local destination = spawnPart.CFrame * CFrame.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
	copy:PivotTo(destination * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
	copy.Parent = Workspace
	pcall(function() root:SetNetworkOwner(nil) end)
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	table.insert(lobbyBots, copy)
end

local function clearLobbyBots()
	for _, copy in lobbyBots do
		if copy.Parent then copy:Destroy() end
	end
	table.clear(lobbyBots)
end

local function respawnInArena(state): boolean
	local model, root, humanoid = state.model, state.root, state.humanoid
	local destination = arenaSpawnPoint()
	if not destination then return false end
	resetAttack(state)
	pcall(Ragdoll.Cancel, model, "BotRespawn", destination)
	model:PivotTo(destination)
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	if humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then humanoid.Health = humanoid.MaxHealth end
	model:SetAttribute("LastHitBy", nil)
	state.wanderTarget, state.pauseUntil, state.busyUntil = nil, os.clock() + 0.5, 0
	state.dodgeUntil, state.approachUntil, state.retreatUntil = 0, 0, 0
	return true
end

local function watchFall(state, now: number)
	local model = state.model
	if model:GetAttribute("IsOnArena") ~= true or (model:GetAttribute("Lives") or 0) <= 0 then state.fallenSince = nil; return end
	local position = Ragdoll.GetAuthoritativePosition(model) or state.root.Position
	if math.isfinite(position.Y) and position.Y >= GameConfig.VoidHeight then state.fallenSince = nil; return end
	state.fallenSince = state.fallenSince or now
	if now - state.fallenSince >= (BotConfig.RespawnGrace or 1.2) then
		state.fallenSince = nil
		respawnInArena(state)
	end
end

local function stepBot(state, now: number)
	local model, root, humanoid = state.model, state.root, state.humanoid
	if state.removed or not model.Parent or not root.Parent then removeBot(state); return end
	watchFall(state, now) -- runs even while ragdolled / falling, before any early return below

	-- locomotion animation first (never gated by weapon/AI state); NpcService may re-enable the stock Animate script: keep it off
	if state.animator then
		local stock = model:FindFirstChild("Animate")
		if stock and stock:IsA("BaseScript") and stock.Enabled then stock.Enabled = false end
		-- arena drop landing (same clip + hold MatchController plays for players after dropIn)
		if state.dropUntil then
			if now > state.dropUntil then
				state.dropUntil = nil
			elseif humanoid.FloorMaterial == Enum.Material.Air then
				state.dropAir = true
			elseif state.dropAir then
				state.dropUntil, state.dropAir = nil, nil
				state.animator:land(now)
			end
		end
		state.animator:update(now)
	end

	local equipped = model:FindFirstChild("EquippedWeapon")
	if not equipped then return end 

	-- FIX: Check our new custom attribute so the loop works perfectly
	if equipped:GetAttribute("BotSkinApplied") ~= state.weaponName then
		equipBotWeapon(state) 
		return 
	end

	ensureWeaponHold(state) -- weapon hold pose (standing still only)


	local origin = Ragdoll.GetAuthoritativePosition(model) or root.Position
	if Ragdoll.IsRagdolled(model) or model:GetAttribute("IsFrozen") or root.Anchored then
		resetAttack(state)
		state.wanderTarget = nil
		humanoid:Move(Vector3.zero)
		return
	end
	if state.busyUntil > now then return end -- an ability is moving the bot

	-- landing refills the air jump; a queued double jump fires while still in the air (the player rules)
	if humanoid.FloorMaterial ~= Enum.Material.Air then state.canDouble = true end
	if state.doubleJumpAt and now >= state.doubleJumpAt then
		state.doubleJumpAt = nil
		if humanoid.FloorMaterial == Enum.Material.Air then botJump(state, now, true) end
	end

	-- threat awareness: sees a swing / rush coming, reacts after a human delay, and sometimes simply misses it
	local threatActor, _, threatPosition = scanThreat(state, origin)
	if threatActor then
		if state.threatActor ~= threatActor then
			state.threatActor = threatActor
			state.threatReactAt = now + rng:NextNumber(BotConfig.DodgeReactMin or 0.12, BotConfig.DodgeReactMax or 0.32)
			-- dodge less often than before: bots should trade blows, not run from every swing
			state.threatRoll = rng:NextNumber() < (BotConfig.DodgeSkill or 0.65) * (if state.phase == "kite" then 0.9 else 0.5)
		end
		local finishingSwing = state.attackId ~= nil and state.releaseAt - now < 0.3 -- about to land our own hit: commit
		if state.threatRoll and not finishingSwing and now >= state.threatReactAt and now >= state.dodgeReadyAt then
			state.dodgeReadyAt = now + 2
			resetAttack(state) -- cancel our own swing to get out of the way
			dodge(state, now, origin, threatActor, threatPosition)
			return
		end
	else
		state.threatActor = nil
	end
	if state.dodgeUntil > now then
		humanoid:MoveTo(root.Position + state.dodgeDir * 10)
		return
	end

	-- swing in progress: hold position, face the target, release after the charge time
	if state.attackId then
		local target = state.attackTarget
		local targetPosition = target and target.Parent and Ragdoll.GetAuthoritativePosition(target)
		if targetPosition then
			local direction = flatUnit(targetPosition - root.Position)
			if direction then faceDirection(state, direction) end
		end
		humanoid:MoveTo(root.Position)
		if now >= state.releaseAt then releaseAttack(state, now) end
		return
	end

	if now >= state.nextDecision then
		state.nextDecision = now + rng:NextNumber(0.15, 0.4)
		refreshRay()

		local enemy, distance, enemyPosition = pickTarget(state, origin, 40)
		state.enemy, state.enemyDist, state.enemyPos, state.enemyAt = enemy, distance, enemyPosition, now

		-- forget old "noticed" entries
		for other, note in state.noticed do
			if not other.Parent or now > note.expires + 3 then state.noticed[other] = nil end
		end

		planIntent(state, now, enemy, distance, enemyPosition)

		-- M1 comes first: an ability is only tried when a swing is not available (or to finish an edge target)
		local m1Ready = enemy ~= nil and distance <= state.attackRange and now - state.lastAttack >= state.cooldown
			and (state.phase == "fight" or state.targetOnEdge)
		if (not m1Ready or state.targetOnEdge) and now >= state.nextAbilityTry then
			state.nextAbilityTry = now + rng:NextNumber(0.6, 1.4)
			if tryAbility(state, now, origin, enemy, distance, enemyPosition, { enemyOnEdge = state.targetOnEdge }) then return end
		end

		if enemy and distance <= state.attackRange then
			local note = state.noticed[enemy]
			if not note or now > note.expires then
				-- first time we see it (or the old decision timed out): human reaction time + "do I feel like hitting?"
				note = {
					since = now,
					react = rng:NextNumber(BotConfig.ReactionMin, BotConfig.ReactionMax) * 0.7,
					attack = state.targetOnEdge or rng:NextNumber() < math.clamp(state.aggression + 0.35, 0.6, 1),
					expires = now + rng:NextNumber(2, 5),
				}
				state.noticed[enemy] = note
			end
			if note.attack and (state.phase == "fight" or state.targetOnEdge) and now - note.since >= note.react
				and now - state.lastAttack >= state.cooldown then
				local direction = flatUnit(enemyPosition - root.Position)
				if direction then faceDirection(state, direction) end
				humanoid:MoveTo(root.Position)
				beginAttack(state, enemy, now)
				return
			end
		end
	end

	if not intentStep(state, now, origin) then wander(state, now, origin) end
end

-- ==========================================
-- SPAWNING
-- ==========================================
local SKIN_TONES = {
	Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146), Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(165, 112, 80), Color3.fromRGB(124, 92, 70), Color3.fromRGB(245, 205, 187),
}
local OUTFIT_COLORS = {
	Color3.fromRGB(196, 40, 28), Color3.fromRGB(13, 105, 172), Color3.fromRGB(75, 151, 75),
	Color3.fromRGB(245, 205, 48), Color3.fromRGB(105, 64, 40), Color3.fromRGB(17, 17, 17),
	Color3.fromRGB(218, 133, 65), Color3.fromRGB(107, 50, 124), Color3.fromRGB(160, 165, 169),
}

local function buildDescription(profile): HumanoidDescription
	local description
	if profile.UserId then
		local ok, result = pcall(Players:GetHumanoidDescriptionFromUserIdAsync(profile.UserId))
		if ok and result then description = result end
	end
	local randomLook = description == nil and (profile.Look == nil or next(profile.Look) == nil)
	description = description or Instance.new("HumanoidDescription")

	-- keep the NPC rig's own body parts (RagdollService / hitboxes depend on them): only colors, clothes, accessories, face
	for _, part in { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" } do description[part] = 0 end

	if randomLook then
		local skin = SKIN_TONES[rng:NextInteger(1, #SKIN_TONES)]
		local shirt = OUTFIT_COLORS[rng:NextInteger(1, #OUTFIT_COLORS)]
		local pants = OUTFIT_COLORS[rng:NextInteger(1, #OUTFIT_COLORS)]
		description.HeadColor, description.LeftArmColor, description.RightArmColor = skin, skin, skin
		description.TorsoColor, description.LeftLegColor, description.RightLegColor = shirt, pants, pants
	end
	if profile.Look then
		for key, value in profile.Look do
			local ok = pcall(function() description[key] = value end)
			if not ok then warn("[BotService] invalid Look property:", key) end
		end
	end
	return description
end

local function createState(model: Model, profile)
	local root = model:FindFirstChild("HumanoidRootPart")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return nil end

	-- FIX: Safely extract the base weapon ("Hammer") and skin ("HammerMagical")
	local rawWeapon = model:GetAttribute("BotWeaponSkin") or model:GetAttribute("BotWeapon") or "Slap"
	local weaponData = WeaponConfig.GetWeaponInfo(rawWeapon)
	local weaponId = weaponData and weaponData.BaseName or "Slap"
	local weaponName = rawWeapon

	local info = WeaponConfig.BaseWeapons[weaponId]
	local attack = info and info.Attack
	local reach = 6
	if attack and attack.HitboxSize and attack.HitboxOffset then
		reach = math.abs(attack.HitboxOffset.Z) + attack.HitboxSize.Z * 0.5
	end

	local now = os.clock()

	-- Get the actual cooldown of the bot's ability
	local abilityConfig = profile.Ability and AbilityConfig.Abilities[profile.Ability]
	local initialAbilityCooldown = abilityConfig and abilityConfig.Cooldown or 5

	local state = {
		model = model, root = root, humanoid = humanoid,
		weaponId = weaponId, 
		weaponName = weaponName,
		attackRange = math.clamp(reach * 0.85, 3, 14),
		cooldown = info and info.Cooldown or 1,
		aggression = profile.Aggression or BotConfig.DefaultAggression,
		abilityName = profile.Ability, abilityReadyAt = now + initialAbilityCooldown,
		attackId = nil, releaseAt = 0, attackTarget = nil, lastAttack = 0,
		busyUntil = 0, nextDecision = now + rng:NextNumber(0.5, 1.5),
		wanderTarget = nil, wanderExpire = 0, pauseUntil = now + rng:NextNumber(0, 1.5),
		lastCheckPos = nil, lastCheckAt = now, nextJumpAt = now + rng:NextNumber(2, 6),
		noticed = {}, connections = {}, removed = false,
		lastJumpAt = 0, canDouble = true, doubleJumpAt = nil,
		dodgeUntil = 0, dodgeDir = Vector3.zero, dodgeReadyAt = 0,
		threatActor = nil, threatReactAt = 0, threatRoll = false,
		retreatUntil = 0, approachUntil = 0, phase = "fight", phaseUntil = 0, nextAbilityTry = 0,
		enemy = nil, enemyDist = 0, enemyPos = nil, enemyAt = 0, targetOnEdge = false,
	}
	state.animator = BotAnimator.new(model, humanoid, root)
	bots[model] = state
	table.insert(state.connections, model:GetAttributeChangedSignal("Lives"):Connect(function()
		if model:GetAttribute("Lives") == 0 and model:GetAttribute("IsOnArena") == true and not state.lobbyCopied then
			state.lobbyCopied = true
			local ok, err = pcall(spawnLobbyCopy, model)
			if not ok then warn("[BotService] lobby copy failed:", err) end
		end
	end))
	table.insert(state.connections, model.AncestryChanged:Connect(function(_, parent)
		if not parent then removeBot(state) end
	end))
	return state
end


local function spawnBot(profile, spawnCFrame: CFrame, token: number, list)
	local weaponId = if WeaponConfig.BaseWeapons[profile.Weapon] then profile.Weapon else "Slap"
	local weaponsFolder = Assets:WaitForChild("Weapons")
	local skin = if profile.WeaponSkin and weaponsFolder:FindFirstChild(profile.WeaponSkin) then profile.WeaponSkin else nil
	if not skin then
		local matching = {}
		for _, child in weaponsFolder:GetChildren() do
			if child:IsA("Model") and string.sub(child.Name, 1, #weaponId) == weaponId and child.Name ~= weaponId then
				table.insert(matching, child.Name)
			end
		end
		if #matching > 0 then
			skin = matching[rng:NextInteger(1, #matching)]
		end
	end

	local model = NpcTemplate:Clone()
	model.Name = profile.Name
	model:SetAttribute("IsBot", true)
	model:SetAttribute("BotWeapon", weaponId)
	model:SetAttribute("BotWeaponSkin", skin)
	model:SetAttribute("BotVIP", if type(profile.VIP) == "boolean" then profile.VIP else rng:NextNumber() < (BotConfig.VIPChance or 0))
	model:PivotTo(spawnCFrame)

	local root = model:FindFirstChild("HumanoidRootPart")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then model:Destroy(); return end
	root.Anchored = true -- held in place while the avatar loads
	model.Parent = Workspace

	local ok, err = pcall(function() humanoid:ApplyDescription(buildDescription(profile)) end)
	if not ok then warn("[BotService] avatar failed for", profile.Name, err) end

	if token ~= spawnToken or not model.Parent then model:Destroy(); return end

	-- same attributes MatchService.spawnArenaNPCs gives a normal arena NPC
	local frozen = ReplicatedStorage:GetAttribute("MatchState") ~= "Playing"
	model:SetAttribute("IsOnArena", true)
	model:SetAttribute("IsFrozen", frozen)
	model:SetAttribute("Lives", 3)
	root.Anchored = false
	CollectionService:AddTag(model, "BotActor")
	CollectionService:AddTag(model, "ArenaNPC") -- NpcService + RagdollService pick it up from here
	table.insert(list, model)
	pcall(function() root:SetNetworkOwner(nil) end) -- the server drives the bot, never a nearby client

	local state = createState(model, { Aggression = profile.Aggression, Ability = profile.Ability })
	if state then state.dropUntil = os.clock() + 6 end -- arena drop: stepBot plays the landing clip on touchdown
end

local function pickProfiles(count: number)
	local pool = table.clone(BotConfig.Profiles)
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local picked, used = {}, {}
	for i = 1, count do
		local base = pool[((i - 1) % math.max(#pool, 1)) + 1] or { Name = "Player", Weapon = "Slap" }
		local profile = table.clone(base)
		local name = profile.Name
		while used[name] or Players:FindFirstChild(name) do name = profile.Name .. rng:NextInteger(10, 99) end
		used[name] = true
		profile.Name = name
		if not (profile.Ability and SUPPORTED[profile.Ability]) then
			profile.Ability = BotConfig.SupportedAbilities[rng:NextInteger(1, #BotConfig.SupportedAbilities)]
		end
		table.insert(picked, profile)
	end
	return picked
end

-- ==========================================
-- PUBLIC API
-- ==========================================
-- Called by MatchService.spawnArenaNPCs (only runs when a single real player is in the match).
-- Async: bots appear a moment later (avatar loading). They are added to `list` so MatchService cleans them up.
-- Random bot amount per round: BotConfig.BotsMin..BotsMax (capped by maxCount), never the same number twice in a row.
local lastBotCount: number? = nil
local function rollBotCount(maxCount: number?): number
	local fallback = BotConfig.BotsWhenSolo or 0
	local low = math.max(0, BotConfig.BotsMin or fallback)
	local high = math.max(low, BotConfig.BotsMax or fallback)
	high = math.min(high, maxCount or high)
	low = math.min(low, high)
	local count = rng:NextInteger(low, high)
	if high > low and count == lastBotCount then
		count = low + (count - low + rng:NextInteger(1, high - low)) % (high - low + 1)
	end
	lastBotCount = count
	return count
end

function BotService.SpawnArenaBots(spawnPart: BasePart, list, maxCount: number?)
	if not BotConfig.Enabled then return end
	local count = rollBotCount(maxCount)
	if count <= 0 then return end
	local token = spawnToken
	local profiles = pickProfiles(count)
	local baseAngle = rng:NextNumber(0, math.pi * 2)
	for index, profile in profiles do
		local angle = baseAngle + (index / #profiles) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local radius = (GameConfig.ArenaSpawnRadius or 15) * rng:NextNumber(0.6, 1.2)
		local cframe = spawnPart.CFrame * CFrame.new(math.cos(angle) * radius, 15, math.sin(angle) * radius)
		task.spawn(function()
			local ok, err = pcall(spawnBot, profile, cframe, token, list)
			if not ok then warn("[BotService] spawn failed:", err) end
		end)
	end
end

-- Removes every bot (also cancels bots that are still loading their avatar).
function BotService.ClearBots()
	spawnToken += 1
	clearLobbyBots()
	for model, state in bots do
		removeBot(state)
		if model.Parent then model:Destroy() end
	end
end

function BotService.AdoptArenaNPC(model: Model, profile, list): boolean
	if bots[model] then return false end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not model:FindFirstChildOfClass("Humanoid") then return false end

	model:SetAttribute("IsBot", true)
	model:SetAttribute("BotWeapon", profile.Weapon)
	model:SetAttribute("BotWeaponSkin", profile.WeaponSkin or profile.Weapon)
	model:SetAttribute("BotVIP", profile.VIP)
	CollectionService:AddTag(model, "BotActor")
	CollectionService:AddTag(model, "ArenaNPC")

	local state = createState(model, {
		Aggression = profile.Aggression,
		Ability = profile.Ability,
	})
	if not state then
		CollectionService:RemoveTag(model, "BotActor")
		CollectionService:RemoveTag(model, "ArenaNPC")
		model:SetAttribute("IsBot", false)
		return false
	end
	state.lobbyCopied = true -- adopted lobby bots are refilled into the lobby by LobbyNPCService, no clone needed

	table.insert(list, model)
	pcall(function() root:SetNetworkOwner(nil) end)
	return true
end

function BotService.IsDropping(model: Model): boolean
	local state = bots[model]
	return state ~= nil and state.dropUntil ~= nil -- spawnBot bots already fall from the sky on their own
end

-- Landing clip after MatchService drops a bot in (same clip players get from MatchController)
function BotService.PlayLanding(model: Model)
	local state = bots[model]
	if state and state.animator then state.animator:land(os.clock()) end
end

function BotService.ReleaseArenaNPC(model: Model)
	local state = bots[model]
	if state then
		resetAttack(state)
		removeBot(state)
	end
	CollectionService:RemoveTag(model, "BotActor")
end

function BotService.IsBot(model: Instance): boolean
	return bots[model] ~= nil
end


function BotService.Init()
	if initialized then return end
	initialized = true
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < AI_INTERVAL then return end
		accumulator = 0
		local now = os.clock()
		for _, state in bots do
			local ok, err = pcall(stepBot, state, now)
			if not ok then warn("[BotService]", err) end
		end
	end)
end

return BotService
