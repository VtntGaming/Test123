-- ShadowCloneService
-- "Shadow Clone" ability (Naruto): spawns [CloneCount] server-driven copies of the caster.
-- Every clone has the caster's look + equipped weapon, chases the nearest enemy and attacks automatically.
-- Attacks go through the SAME pipeline as NPCs (CombatService.BeginNpcAttack / ReleaseNpcAttack), so the
-- swing hitbox, ragdoll and knockback behave exactly like an M1 hit with the caster's weapon.
-- Clones never hurt the caster or the caster's other clones, and hits are credited to the caster.
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local Protection = require(script.Parent:WaitForChild("Protection"))
local CharacterAnimations = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Character")
local SFX = SoundService:WaitForChild("SFX")

local CLONE_TAG = "ShadowClone"
local AI_INTERVAL = 0.1 -- same tick rate as NpcService

local ShadowCloneService = {}
local initialized = false
local deps = nil -- injected by CombatService.Init: { Ragdoll, BeginAttack, ReleaseAttack, CancelActor }
local groups = {} -- [Player] = { player, character, config, clones = { state }, expiresAt }
local runtimeFolder = nil

local function getFolder()
	if runtimeFolder and runtimeFolder.Parent then return runtimeFolder end
	runtimeFolder = Workspace:FindFirstChild("ShadowClones")
	if not runtimeFolder then
		runtimeFolder = Instance.new("Folder")
		runtimeFolder.Name = "ShadowClones"
		runtimeFolder.Parent = Workspace
	end
	return runtimeFolder
end

-- ==========================================
-- VISUALS & SFX
-- ==========================================
local function playSfx(parentPart: BasePart, soundName: string)
	local template = SFX and SFX:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then return end
	local sound = template:Clone()
	sound.RollOffMode = Enum.RollOffMode.Inverse
	sound.RollOffMinDistance = 15
	sound.RollOffMaxDistance = 180
	sound.Volume = 0.85
	sound.Parent = parentPart
	sound:Play()
end

-- The classic "poof" of smoke when a clone appears / vanishes (Naruto style).
local function puff(position: Vector3, scale: number?, soundType: ("CloneJustu" | "CloneCancel")?)
	scale = scale or 1
	local part = Instance.new("Part")
	part.Name = "ShadowClonePuff"
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = position
	part.Parent = getFolder()

	-- Template: ReplicatedStorage.Assets.VFX.CloneSmoke
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfx = assets and assets:FindFirstChild("VFX")
	local cloneSmokeTemplate = vfx and vfx:FindFirstChild("CloneSmoke")
	if cloneSmokeTemplate then
		local smokeAttachment = cloneSmokeTemplate:Clone()
		smokeAttachment.Parent = part
		for _, desc in smokeAttachment:GetDescendants() do
			if desc:IsA("Smoke") then
				desc.Enabled = true
				local targetSize = desc.Size * scale
				desc.Size = targetSize
				desc.Opacity = math.max(desc.Opacity, 0.75)
				-- Smoothly tween smoke opacity and size so it billows and vanishes cleanly
				task.delay(0.35, function()
					if desc.Parent then
						local tween = TweenService:Create(desc, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
							Opacity = 0,
							Size = targetSize * 1.6,
						})
						tween:Play()
						tween.Completed:Once(function()
							if desc.Parent then desc.Enabled = false end
						end)
					end
				end)
			elseif desc:IsA("ParticleEmitter") then
				if desc.Enabled and desc.Rate > 0 then
					task.delay(0.5, function()
						if desc.Parent then desc.Enabled = false end
					end)
				else
					desc:Emit(desc:GetAttribute("EmitCount") or 25)
				end
			end
		end
	end

	-- Subtle flash on pop/dispel
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 255, 255)
	light.Range = 12 * scale
	light.Brightness = 2
	light.Parent = part
	TweenService:Create(light, TweenInfo.new(0.25), { Brightness = 0, Range = 0 }):Play()

	-- Layer 1: Dense core Naruto cartoon smoke cloud
	local emitter1 = Instance.new("ParticleEmitter")
	emitter1.Name = "SmokeCloud"
	emitter1.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter1.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(240, 240, 245)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(210, 210, 220)),
	})
	emitter1.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3 * scale),
		NumberSequenceKeypoint.new(0.18, 6.5 * scale),
		NumberSequenceKeypoint.new(0.55, 9.5 * scale),
		NumberSequenceKeypoint.new(1, 12 * scale),
	})
	emitter1.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.4, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter1.Lifetime = NumberRange.new(0.65, 0.95)
	emitter1.Speed = NumberRange.new(10 * scale, 18 * scale)
	emitter1.Drag = 8
	emitter1.SpreadAngle = Vector2.new(180, 180)
	emitter1.Rotation = NumberRange.new(-180, 180)
	emitter1.RotSpeed = NumberRange.new(-60, 60)
	emitter1.Acceleration = Vector3.new(0, 3, 0)
	emitter1.Rate = 0
	emitter1.Parent = part
	emitter1:Emit(math.floor(28 * scale))

	-- Layer 2: Fast outward shock / poof ring
	local emitter2 = Instance.new("ParticleEmitter")
	emitter2.Name = "PoofRing"
	emitter2.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter2.Color = ColorSequence.new(Color3.fromRGB(245, 245, 250), Color3.fromRGB(180, 180, 190))
	emitter2.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2 * scale),
		NumberSequenceKeypoint.new(0.3, 5.5 * scale),
		NumberSequenceKeypoint.new(1, 7.5 * scale),
	})
	emitter2.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.0),
		NumberSequenceKeypoint.new(0.35, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter2.Lifetime = NumberRange.new(0.4, 0.65)
	emitter2.Speed = NumberRange.new(16 * scale, 24 * scale)
	emitter2.Drag = 12
	emitter2.SpreadAngle = Vector2.new(180, 180)
	emitter2.Rotation = NumberRange.new(-180, 180)
	emitter2.RotSpeed = NumberRange.new(-90, 90)
	emitter2.Rate = 0
	emitter2.Parent = part
	emitter2:Emit(math.floor(18 * scale))

	-- Layer 3: Gentle rising smoke wisps
	local emitter3 = Instance.new("ParticleEmitter")
	emitter3.Name = "Wisps"
	emitter3.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter3.Color = ColorSequence.new(Color3.fromRGB(230, 230, 235), Color3.fromRGB(160, 160, 170))
	emitter3.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.5 * scale),
		NumberSequenceKeypoint.new(0.5, 4.5 * scale),
		NumberSequenceKeypoint.new(1, 6 * scale),
	})
	emitter3.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.6, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter3.Lifetime = NumberRange.new(0.8, 1.2)
	emitter3.Speed = NumberRange.new(3 * scale, 7 * scale)
	emitter3.Drag = 4
	emitter3.Acceleration = Vector3.new(0, 4.5, 0)
	emitter3.SpreadAngle = Vector2.new(180, 180)
	emitter3.Rate = 0
	emitter3.Parent = part
	emitter3:Emit(math.floor(12 * scale))

	if soundType then
		playSfx(part, soundType)
	end

	Debris:AddItem(part, 3)
end

-- Idle / run animations are played server side (the player's Animate script is a LocalScript and is removed).
local function setupLocomotion(state)
	local humanoid = state.humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local function load(name: string, priority: Enum.AnimationPriority)
		local source = CharacterAnimations:FindFirstChild(name)
		if not source then return nil end
		local animation = Instance.new("Animation")
		animation.AnimationId = source.AnimationId
		local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
		animation:Destroy()
		if not ok or not track then return nil end
		track.Priority, track.Looped = priority, true
		return track
	end
	state.idleTrack = load("Idle", Enum.AnimationPriority.Idle)
	state.runTrack = load("Running", Enum.AnimationPriority.Movement)
	if state.idleTrack then state.idleTrack:Play(0.1) end
end

local function updateLocomotion(state, stopAll: boolean?)
	local idle, run = state.idleTrack, state.runTrack
	if stopAll then
		if idle and idle.IsPlaying then idle:Stop(0.05) end
		if run and run.IsPlaying then run:Stop(0.05) end
		return
	end
	local velocity = state.root.AssemblyLinearVelocity
	local moving = Vector3.new(velocity.X, 0, velocity.Z).Magnitude > 2
	if moving then
		if idle and idle.IsPlaying then idle:Stop(0.15) end
		if run and not run.IsPlaying then run:Play(0.15) end
	else
		if run and run.IsPlaying then run:Stop(0.15) end
		if idle and not idle.IsPlaying then idle:Play(0.15) end
	end
end

-- ==========================================
-- CLONE LIFECYCLE
-- ==========================================
local function cancelAttack(state)
	local clone = state.clone
	if state.attackId or clone:GetAttribute("IsCharging") then
		deps.CancelActor(clone)
		state.attackId = nil
		clone:SetAttribute("IsCharging", false)
		NpcAttackEvent:FireAllClients(clone, state.weaponId, "Cancel")
	end
end

local function despawn(state, withPuff: boolean)
	if state.removed then return end
	state.removed = true
	local clone = state.clone
	for _, connection in state.connections do connection:Disconnect() end
	table.clear(state.connections)

	-- The exact position where the clone disappears (live flight position from RagdollService if ragdolled)
	local pos = (clone.Parent and deps.Ragdoll and deps.Ragdoll.GetAuthoritativePosition(clone))
		or state.lastPosition
		or (state.root and state.root.Parent and state.root.Position)

	if clone.Parent then
		pcall(cancelAttack, state)
		pcall(deps.Ragdoll.Cancel, clone, "Dispelled")
		-- Fast fade out of parts so it seamlessly vanishes into the smoke
		for _, desc in clone:GetDescendants() do
			if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
				TweenService:Create(desc, TweenInfo.new(0.12), { Transparency = 1 }):Play()
			elseif desc:IsA("Decal") then
				TweenService:Create(desc, TweenInfo.new(0.12), { Transparency = 1 }):Play()
			end
		end
		task.delay(0.12, function()
			clone:Destroy()
		end)
	end
	if withPuff and pos then
		puff(pos, 1, "CloneCancel")
	end
end

local function removeClone(group, state)
	local index = table.find(group.clones, state)
	if index then table.remove(group.clones, index) end
	despawn(state, true)
end

function ShadowCloneService.Clear(owner: Player, silent: boolean?)
	local group = groups[owner]
	if not group then return end
	groups[owner] = nil
	for _, state in group.clones do despawn(state, not silent) end
	table.clear(group.clones)
end

local function stripClone(clone: Model)
	-- tags / attributes of the caster's character must not leak to the copy
	for _, tag in CollectionService:GetTags(clone) do CollectionService:RemoveTag(clone, tag) end
	for name in clone:GetAttributes() do clone:SetAttribute(name, nil) end
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("BillboardGui")
			or descendant:IsA("ForceField") or descendant:IsA("Highlight") then
			descendant:Destroy()
		end
	end
end

local function spawnPosition(group, index: number, total: number): CFrame
	local config, character = group.config, group.character
	local ownerRoot = character:FindFirstChild("HumanoidRootPart")
	local look = ownerRoot.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.01 then look = -Vector3.zAxis end
	local angle = ((index - 1) / total) * math.pi * 2 + math.pi / 2
	local radius = config.SpawnRadius or 5
	local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	local from = ownerRoot.Position + offset

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, getFolder() }
	params.RespectCanCollide = true
	-- only spawn where there is floor (never over the void); otherwise stack on the caster
	local position = ownerRoot.Position
	if Workspace:Raycast(from + Vector3.yAxis * 3, Vector3.new(0, -12, 0), params) then
		position = Vector3.new(from.X, ownerRoot.Position.Y, from.Z)
	end
	return CFrame.lookAt(position, position + look.Unit)
end

local function createClone(group, index: number, total: number)
	local player, character, config = group.player, group.character, group.config

	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(function() return character:Clone() end)
	character.Archivable = wasArchivable
	if not ok or not clone then return nil end

	stripClone(clone)
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	local root = clone:FindFirstChild("HumanoidRootPart")
	local weapon = clone:FindFirstChild("EquippedWeapon")
	local weaponId = weapon and weapon:GetAttribute("WeaponId")
	if not humanoid or not root or not root:IsA("BasePart") or type(weaponId) ~= "string" then
		clone:Destroy()
		return nil
	end

	clone.Name = "ShadowClone_" .. player.Name .. "_" .. index

	-- same humanoid setup as NpcService.initializeNpc: unkillable, no fall-down / ragdoll states
	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = GameConfig.Movement.JumpHeight
	humanoid.WalkSpeed = GameConfig.Movement.WalkSpeed * (config.SpeedMultiplier or 1)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	if (config.Transparency or 0) > 0 then
		for _, part in clone:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				part.Transparency = math.max(part.Transparency, config.Transparency)
			end
		end
	end

	clone:SetAttribute("ShadowCloneOwner", player.UserId)
	clone:SetAttribute("ShadowCloneOwnerName", player.Name)
	clone:SetAttribute("EquippedBaseWeapon", weaponId)
	clone:SetAttribute("WeaponRevision", 1)
	clone:SetAttribute("LastAttackTime", 0)
	clone:SetAttribute("IsCharging", false)
	clone:SetAttribute("ChargeDuration", 1)

	clone:PivotTo(spawnPosition(group, index, total))
	clone.Parent = getFolder()
	pcall(function() root:SetNetworkOwner(nil) end) -- the server drives the clone, never a nearby client

	CollectionService:AddTag(clone, CLONE_TAG)
	deps.Ragdoll.RegisterActor(clone, "NPC") -- hittable + knockback-able like any NPC

	local info = WeaponConfig.BaseWeapons[weaponId]
	local attack = info and info.Attack
	local reach = 4.5
	if attack and attack.HitboxSize and attack.HitboxOffset then
		reach = math.abs(attack.HitboxOffset.Z) + attack.HitboxSize.Z * 0.5
	end

	local state = {
		clone = clone, humanoid = humanoid, root = root, weaponId = weaponId,
		attackId = nil, releaseAt = 0, lastAttack = 0,
		attackRange = math.clamp(reach * 0.85, 3, 14),
		cooldown = info and info.Cooldown or 1,
		hitsTaken = 0, connections = {}, removed = false,
		lastPosition = root.Position,
	}
	setupLocomotion(state)

	-- like a real shadow clone: it pops after taking [HitsToDispel] hits
	table.insert(state.connections, clone:GetAttributeChangedSignal("IsRagdolled"):Connect(function()
		if clone:GetAttribute("IsRagdolled") ~= true or state.dispelling then return end
		state.hitsTaken += 1
		if state.hitsTaken >= (config.HitsToDispel or 1) then
			state.dispelling = true
			-- Allow the clone to fly through the air ("flight abit") from RagdollService knockback before poofing
			local flightDuration = math.clamp(config.DispelDelay or 0.75, 0.65, 1.2)
			local dispelDone = false
			local phaseConn = nil
			local function triggerDispel()
				if dispelDone or state.removed then return end
				dispelDone = true
				if phaseConn then phaseConn:Disconnect(); phaseConn = nil end
				removeClone(group, state)
			end

			-- Dispel when it touches ground / finishes flight arc (Bounce, Roll, Rest)
			phaseConn = clone:GetAttributeChangedSignal("RagdollPhase"):Connect(function()
				local phase = clone:GetAttribute("RagdollPhase")
				if phase == "Bounce" or phase == "Rest" or phase == "Roll" then
					triggerDispel()
				end
			end)

			-- Fallback: dispel in mid-air after a nice flight even if it never hits the ground
			task.delay(flightDuration, triggerDispel)
		end
	end))

	-- pop when taking lethal damage or humanoid dies
	table.insert(state.connections, humanoid.Died:Connect(function()
		if state.dispelling then return end
		state.dispelling = true
		removeClone(group, state)
	end))
	table.insert(state.connections, humanoid.HealthChanged:Connect(function(health)
		if health <= 0 and not state.dispelling then
			state.dispelling = true
			removeClone(group, state)
		end
	end))

	-- pop if clone model is removed externally (e.g. void / match clear)
	table.insert(state.connections, clone.AncestryChanged:Connect(function(_, parent)
		if not parent and not state.removed and not state.dispelling then
			state.dispelling = true
			removeClone(group, state)
		end
	end))

	if config.SpawnPuff ~= false then puff(root.Position, 1) end
	return state
end

-- ==========================================
-- AI (mirrors NpcService.updateNPCsAI)
-- ==========================================
local function findTarget(group, origin: Vector3)
	local owner, config = group.player, group.config
	local ownerOnArena = owner:GetAttribute("IsOnArena") == true
	local best, bestPosition, bestDistance = nil, nil, config.ChaseRange or 90

	local function consider(actor)
		local humanoid = actor:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end
		local position = deps.Ragdoll.GetAuthoritativePosition(actor)
		if not position then return end
		if position.Y < origin.Y - 5 then return end -- fell off the edge
		local distance = (position - origin).Magnitude
		if distance < bestDistance then best, bestPosition, bestDistance = actor, position, distance end
	end

	for _, other in Players:GetPlayers() do
		if other ~= owner and other.Character then
			local sameZone = if ownerOnArena then other:GetAttribute("IsOnArena") == true
				else other:GetAttribute("IsInTrainingArea") == true
			if sameZone and not Protection.IsProtected(other, true) and not other:GetAttribute("IsInvulnerable")
				and not other:GetAttribute("TeleportingActive") then
				consider(other.Character)
			end
		end
	end
	if config.TargetNpcs ~= false then
		for _, npc in CollectionService:GetTagged(if ownerOnArena then "ArenaNPC" else "TraningNPC") do
			if npc:IsDescendantOf(Workspace) and (npc:GetAttribute("Lives") or 1) > 0 then consider(npc) end
		end
	end
	return best, bestPosition, bestDistance
end

local function updateClone(group, state, now: number)
	local clone, root, humanoid = state.clone, state.root, state.humanoid

	-- Always track live authoritative position (including during knockback flight and dispelling!)
	local origin = (clone.Parent and deps.Ragdoll and deps.Ragdoll.GetAuthoritativePosition(clone)) or root.Position
	state.lastPosition = origin

	if origin.Y < (GameConfig.VoidHeight or -50) and not state.dispelling then
		state.dispelling = true
		removeClone(group, state)
		return
	end

	if state.dispelling or deps.Ragdoll.IsRagdolled(clone) or clone:GetAttribute("IsFrozen") or root.Anchored then
		cancelAttack(state)
		humanoid:Move(Vector3.zero)
		updateLocomotion(state, true)
		return
	end
	updateLocomotion(state)

	local target, targetPosition, distance = findTarget(group, origin)

	local function faceTarget()
		if not targetPosition then return end
		local aim = Vector3.new(targetPosition.X, root.Position.Y, targetPosition.Z)
		if (aim - root.Position).Magnitude > 0.001 then root.CFrame = CFrame.lookAt(root.Position, aim) end
	end

	if state.attackId then
		faceTarget()
		if now >= state.releaseAt then
			local attackId = state.attackId
			state.attackId = nil
			clone:SetAttribute("IsCharging", false)
			clone:SetAttribute("LastAttackTime", now)
			state.lastAttack = now
			if deps.ReleaseAttack(clone, attackId) then
				NpcAttackEvent:FireAllClients(clone, state.weaponId, "Release")
			else
				NpcAttackEvent:FireAllClients(clone, state.weaponId, "Cancel")
			end
		end
	elseif target then
		if distance > state.attackRange then
			humanoid:MoveTo(targetPosition)
		else
			humanoid:MoveTo(root.Position)
			faceTarget()
			if now - state.lastAttack >= state.cooldown then
				local attackId = deps.BeginAttack(clone)
				if attackId then
					local config = group.config
					local minCharge, maxCharge = config.AttackChargeMin or 0.4, config.AttackChargeMax or 0.8
					local duration = math.random(math.floor(minCharge * 100), math.floor(maxCharge * 100)) / 100
					state.attackId, state.releaseAt = attackId, now + duration
					clone:SetAttribute("IsCharging", true)
					clone:SetAttribute("ChargeStartTime", now)
					clone:SetAttribute("ChargeDuration", duration)
					NpcAttackEvent:FireAllClients(clone, state.weaponId, "Charge")
				end
			end
		end
	else
		-- nobody to fight: stay close to the caster
		local ownerRoot = group.character:FindFirstChild("HumanoidRootPart")
		if ownerRoot and (ownerRoot.Position - root.Position).Magnitude > 9 then
			humanoid:MoveTo(ownerRoot.Position)
		else
			humanoid:MoveTo(root.Position)
		end
	end
end

local function groupValid(group): boolean
	local owner, character = group.player, group.character
	if owner.Parent ~= Players or owner.Character ~= character or not character:IsDescendantOf(Workspace) then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	if owner:GetAttribute("TeleportingActive") then return false end
	-- the match ended / caster left the fighting zone: the clones disappear
	return owner:GetAttribute("IsOnArena") == true or owner:GetAttribute("IsInTrainingArea") == true
end

local function step()
	local now = os.clock()
	for owner, group in groups do
		if now >= group.expiresAt or not groupValid(group) then
			ShadowCloneService.Clear(owner, false)
			continue
		end
		for index = #group.clones, 1, -1 do
			local state = group.clones[index]
			if state.removed or not state.clone.Parent or not state.root.Parent then
				table.remove(group.clones, index)
				despawn(state, true)
			else
				local ok, err = pcall(updateClone, group, state, now)
				if not ok then warn("[ShadowClone]", err) end
			end
		end
		if #group.clones == 0 then groups[owner] = nil end
	end
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function ShadowCloneService.Start(player: Player, character: Model, config)
	if not initialized then return end
	ShadowCloneService.Clear(player, false) -- casting again dispels old clones with smoke puff & sfx
	local ownerRoot = character:FindFirstChild("HumanoidRootPart")
	if not ownerRoot then return end

	-- Smoke puff and Jutsu SFX at caster's position (Naruto hand-sign burst!)
	puff(ownerRoot.Position, 1.2, "CloneJustu")

	local group = {
		player = player, character = character, config = config,
		clones = {}, expiresAt = os.clock() + (config.Duration or 12),
	}
	groups[player] = group
	local total = math.clamp(config.CloneCount or 3, 1, 8)
	for index = 1, total do
		local state = createClone(group, index, total)
		if state then table.insert(group.clones, state) end
	end
	if #group.clones == 0 then groups[player] = nil end
end

function ShadowCloneService.Init(dependencies)
	if initialized then return end
	initialized = true
	deps = dependencies

	Players.PlayerRemoving:Connect(function(player) ShadowCloneService.Clear(player, true) end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < AI_INTERVAL then return end
		accumulator = 0
		step()
	end)
end

return ShadowCloneService
