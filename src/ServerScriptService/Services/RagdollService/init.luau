--!strict
-- Cartoon actor lifecycle. One solver/scheduler serves players, NPCs and training bags.
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local SharedConfig = require(ReplicatedStorage:WaitForChild("Config"))
local Knockback = require(ReplicatedStorage:WaitForChild("Knockback"))
local Combat = require(ReplicatedStorage:WaitForChild("Combat"))
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local Motion = require(script:WaitForChild("CartoonMotion"))
local Streaming = require(script:WaitForChild("CartoonStreaming"))
local HitQuery = require(script:WaitForChild("HitQuery"))
local Codec, Diagnostics = Knockback.Codec, Knockback.Diagnostics
local Network = SharedConfig.Network
local profiles = Motion.ValidateProfiles(SharedConfig.Weapon)
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local motionRemote = remotes:WaitForChild("KnockbackMotion") :: RemoteEvent
local snapshotRemote = remotes:WaitForChild("KnockbackSnapshots") :: UnreliableRemoteEvent
local reactionRemote = remotes:WaitForChild("KnockbackReaction") :: RemoteEvent
local initialState = remotes:WaitForChild("GetKnockbackState") :: RemoteFunction
local recoveryRequest = remotes:WaitForChild("RequestFlyRecovery") :: RemoteEvent
local stats = Diagnostics.New(Network.Diagnostics)

-- Supported target: character Model or original training-bag BasePart.
export type Actor = Model | BasePart
-- Server-validated weapon identity and charge strength for one accepted hit.
export type HitContext = {
	weaponId: string, -- Base weapon family used to choose the Cartoon motion profile.
	strength: number, -- Validated charge multiplier applied to a fresh per-hit profile.
	knockbackMultiplier: number?, -- Server-selected attack power; omitted for abilities using their own profile strength.
}
-- Active actor intersecting a server attack box, with an authoritative effect point.
export type HitCandidate = {
	actor: Actor, -- Registered character or bag whose virtual hit bounds overlap.
	position: Vector3, -- Closest point on its hit shape to the attack-box center.
}
-- Original character-part properties restored after knockback.
type SavedPart = {
	CanCollide: boolean, -- Whether this part originally collided with other geometry.
	CanQuery: boolean, -- Whether spatial queries originally included this part.
	CanTouch: boolean, -- Whether this part originally generated touch events.
	Massless: boolean, -- Original contribution-to-assembly-mass setting.
	RootPriority: number, -- Original assembly-root selection priority.
	CollisionGroup: string, -- Original physics collision group name.
}
-- Server registration, active hit, and cleanup state for one combat actor.
type Rig = {
	actor: Actor, -- Original character Model or bag mesh used by the host game's APIs.
	kind: string, -- Player, NPC, or Bag; selects lifecycle and recovery behavior.
	id: number, -- Unique server-assigned combat actor ID.
	owner: Player?, -- Owning Player for player characters; nil for NPCs and bags.
	model: Model, -- Character Model, or the bag's streaming container Model.
	root: BasePart, -- HumanoidRootPart for characters, or the bag mesh itself.
	humanoid: Humanoid?, -- Character Humanoid; nil for training bags.
	generation: string, -- Unique identifier for this registered actor lifetime.
	revision: number, -- Hit/session revision incremented whenever a new motion session opens.
	spawnFrame: CFrame, -- Registration-time root transform used for bag resets.
	originalSize: Vector3, -- Registration-time root size; preserves bag dimensions despite squash effects.
	bagYaw: CFrame, -- Original horizontal bag rotation retained during motion.
	parts: { [BasePart]: SavedPart }, -- Saved part properties to restore when knockback ends.
	connections: { RBXScriptConnection }, -- Actor lifecycle listeners disconnected during unregister.
	active: boolean, -- Whether this rig currently participates in the motion scheduler.
	destroyed: boolean, -- Whether this registration has been disposed.
	anchoredByService: boolean, -- Whether this service owns the root's anchor, allowing valid repeat hits.
	collider: Motion.Collider?, -- Initial sphere dimensions stored as data, never replicated.
	motion: Motion.State?, -- Current scripted motion state; nil outside an active session.
	session: number, -- Unique network motion session ID for the current hit.
	sequence: number, -- Increasing movement sample number within the current session.
	controlVersion: number, -- Increasing reliable phase/contact message version.
	reactionVersion: number, -- Increasing version of accepted owner reaction selections/completions.
	endsAt: number, -- Server timeout timestamp; infinity while a bag remains settled.
	launchedAt: number, -- Server timestamp when Stun ends and flight can begin.
	voidPending: boolean, -- Prevents processing the same void crossing more than once.
	settled: boolean, -- Whether a bag has finished resting but still needs support tracking.
	nextSupportCheck: number, -- Server timestamp for the next settled-bag collision check.
	before: { -- Original root/Humanoid settings saved once for the active knockback.
		anchored: boolean, -- Root's original Anchored value, restored on recovery.
		autoRotate: boolean, -- Humanoid's original AutoRotate value.
		frame: CFrame, -- Original root transform, restored if the hit is rejected.
		velocity: Vector3, -- Original linear velocity, restored if the hit is rejected.
		angularVelocity: Vector3, -- Original angular velocity, restored if the hit is rejected.
	}?,
	ownership: { -- Original network ownership policy saved before anchoring.
		automatic: boolean, -- Whether Roblox originally chose the root's network owner automatically.
		owner: Player? -- Original explicit network owner; nil means server ownership.
	}?,
	animate: BaseScript?, -- NPC's server Animate script temporarily disabled during knockback.
	animateEnabled: boolean?, -- Previous Enabled value of the saved NPC Animate script.
	streaming: Streaming.State?, -- Original streaming mode and player replication focus to restore.
	lastSentFrame: CFrame?, -- Last transmitted root transform, used to suppress unchanged snapshots.
	lastSentPhase: string?, -- Last transmitted phase, so phase changes still produce snapshots.
}
local Service = {}
local GROUP = "CombatRagdoll"
local SETTLED_BAG_CHECK_INTERVAL = 0.5 -- Seconds between full checks on unchanged ground.
local rigs: { [Instance]: Rig } = {}
local actorsById: { [number]: Rig } = {}
local active: { [Instance]: Rig } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local nextActor, nextSession = 0, 0
local initialized, filterDirty = false, true
local voidHandler: ((Actor, Vector3) -> ())? = nil
local runtime: Folder? = nil
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.RespectCanCollide = true
worldParams.IgnoreWater = true
local unknownProfiles: { [string]: boolean } = {}

local function finite(n: number): boolean
	return n == n and math.abs(n) < math.huge
end
local function alive(rig: Rig): boolean
	return not rig.destroyed
		and rig.actor:IsDescendantOf(Workspace)
		and rig.root.Parent ~= nil
		and (not rig.humanoid or rig.humanoid.Health > 0)
		and (not rig.owner or rig.owner.Character == rig.model)
end
local function disconnect(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end
local function updateFilter()
	if not filterDirty then
		return
	end
	filterDirty = false
	local excluded: { Instance } = {}
	for _, rig in rigs do
		if not rig.destroyed then
			table.insert(excluded, rig.model)
		end
	end
	for _, name in { "CombatLocalEffects", "ClientEffects", "CombatEffects" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(excluded, folder)
		end
	end
	worldParams.FilterDescendantsInstances = excluded
	Motion.SetFilter(excluded)
end
local function send(events: { any })
	if #events == 0 then
		return
	end
	Diagnostics.Add(stats, "ReliableMessages")
	Diagnostics.Add(stats, "ReliableRecords", #events)
	motionRemote:FireAllClients("Control", events)
end
local function checkpoint(rig: Rig, state: any?, timestamp: number?): Knockback.Sample
	local motion = assert(rig.motion)
	local value = state or motion
	rig.sequence += 1
	return {
		session = rig.session,
		sequence = rig.sequence,
		control = rig.controlVersion,
		time = timestamp or Workspace:GetServerTimeNow(),
		position = value.position,
		velocity = value.velocity,
		phase = value.phase,
	}
end
local function descriptor(rig: Rig, kind: string, now: number): any
	local motion = assert(rig.motion)
	local latest = motion.impacts[#motion.impacts]
	return {
		kind = kind,
		actorId = rig.id,
		actorKind = rig.kind,
		userId = if rig.owner then rig.owner.UserId else 0,
		session = rig.session,
		generation = rig.generation,
		revision = rig.revision,
		version = rig.controlVersion,
		weaponId = motion.weaponId,
		checkpoint = checkpoint(rig, nil, now),
		flyOffset = motion.heading * CFrame.new(-motion.rootToTorso + motion.profile.FlyVisualOffset),
		restOffset = motion.heading * CFrame.new(-motion.rootToTorso + motion.profile.RestVisualOffset),
		stunOffset = motion.stunOffset,
		reaction = if latest then table.clone(latest) else nil,
		reactionVersion = rig.reactionVersion,
	}
end
local function publish(rig: Rig)
	local actor, state = rig.actor, rig.motion
	if not state then
		return
	end
	actor:SetAttribute("RagdollMode", "Cartoon")
	actor:SetAttribute("RagdollWeaponId", state.weaponId)
	actor:SetAttribute("RagdollGeneration", rig.generation)
	actor:SetAttribute("RagdollRevision", rig.revision)
	actor:SetAttribute("RagdollLaunchedAt", rig.launchedAt)
	actor:SetAttribute("RagdollEndsAt", if finite(rig.endsAt) then rig.endsAt else 0)
	actor:SetAttribute("RagdollPhase", state.phase)
	actor:SetAttribute("IsRagdolled", true)
end
local function rememberPart(rig: Rig, part: BasePart)
	if rig.parts[part] then
		return
	end
	rig.parts[part] = {
		CanCollide = part.CanCollide,
		CanQuery = part.CanQuery,
		CanTouch = part.CanTouch,
		Massless = part.Massless,
		RootPriority = part.RootPriority,
		CollisionGroup = part.CollisionGroup,
	}
	part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
	part.Massless = part ~= rig.root
	part.CollisionGroup = GROUP
	if part == rig.root then
		part.RootPriority = 127
	end
end
local function restoreParts(rig: Rig)
	for part, saved in rig.parts do
		if part.Parent then
			part.CanCollide = false
			part.CanQuery, part.CanTouch, part.Massless = saved.CanQuery, saved.CanTouch, saved.Massless
			part.RootPriority = saved.RootPriority
			part.CollisionGroup = if PhysicsService:IsCollisionGroupRegistered(saved.CollisionGroup)
				then saved.CollisionGroup
				else "Default"
			part.CanCollide = saved.CanCollide
		end
	end
	table.clear(rig.parts)
end
local function stopNpcAnimate(rig: Rig)
	if rig.kind ~= "NPC" or not rig.humanoid then
		return
	end
	local animate = rig.model:FindFirstChild("Animate")
	-- bots use BotAnimator (server tracks): never toggle the stock Animate script (a double knockback left it disabled)
	if animate and animate:IsA("BaseScript") and rig.model:GetAttribute("BotAnimated") ~= true then
		rig.animate, rig.animateEnabled = animate, animate.Enabled
		animate.Enabled = false
	end
	-- Server NPC tracks belong to its normal Animate/AI; knockback tracks are client-local.
	local animator = rig.humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0.05)
		end
	end
end
local function restoreNpcAnimate(rig: Rig)
	local animate = rig.animate
	if animate and animate.Parent and rig.animateEnabled ~= nil then
		animate.Enabled = rig.animateEnabled
	end
	rig.animate, rig.animateEnabled = nil, nil
end
local function ensureCollider(rig: Rig): boolean
	if rig.collider then
		return true
	end
	local core = if rig.kind == "Bag"
		then rig.root
		else rig.model:FindFirstChild("UpperTorso") or rig.model:FindFirstChild("Torso")
	if not core or not core:IsA("BasePart") then
		return false
	end
	local size = if rig.kind == "Bag" then rig.originalSize else core.Size
	local diameter = math.clamp(math.max(size.X, size.Z), 0.5, 12)
	local frame = if rig.kind == "Bag"
		then rig.root.CFrame * CFrame.new(0, -(size.Y - diameter) / 2, 0)
		else core.CFrame
	rig.collider = { position = frame.Position, radius = diameter * 0.5 }
	return true
end
local function begin(rig: Rig): boolean
	if rig.active then
		return true
	end
	if not ensureCollider(rig) then
		return false
	end
	rig.before = {
		anchored = rig.root.Anchored,
		autoRotate = if rig.humanoid then rig.humanoid.AutoRotate else false,
		frame = rig.root.CFrame,
		velocity = rig.root.AssemblyLinearVelocity,
		angularVelocity = rig.root.AssemblyAngularVelocity,
	}
	if not rig.root.Anchored then
		pcall(function()
			rig.ownership =
				{ automatic = rig.root:GetNetworkOwnershipAuto(), owner = rig.root:GetNetworkOwner() }
		end)
	end
	rememberPart(rig, rig.root)
	for _, instance in rig.model:GetDescendants() do
		if instance:IsA("BasePart") then
			rememberPart(rig, instance)
		end
	end
	rig.root.AssemblyLinearVelocity, rig.root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	rig.root.Anchored, rig.anchoredByService = true, true
	if rig.humanoid then
		rig.humanoid.AutoRotate = false
	end
	stopNpcAnimate(rig)
	rig.streaming = Streaming.Enter(
		rig.model,
		rig.owner,
		assert(rig.collider).position,
		assert(runtime)
	)
	rig.active = true
	active[rig.actor] = rig
	rig.actor:SetAttribute("RagdollStartedAt", Workspace:GetServerTimeNow())
	return true
end
local function rootFrame(rig: Rig, frame: CFrame)
	if rig.kind == "Bag" then
		rig.root.CFrame = frame
	else
		rig.model:PivotTo(frame * rig.root.CFrame:Inverse() * rig.model:GetPivot())
	end
end
local function upright(rig: Rig, frame: CFrame): CFrame
	local humanoid = rig.humanoid
	if not humanoid then
		return frame
	end
	local position = frame.Position
	local look = frame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.01 then
		look = -Vector3.zAxis
	end
	local height = humanoid.HipHeight + rig.root.Size.Y * 0.5
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local leg = rig.model:FindFirstChild("Left Leg")
		if leg and leg:IsA("BasePart") then
			height += leg.Size.Y
		end
	end
	updateFilter()
	local hit = Workspace:Raycast(position + Vector3.yAxis * 2, -Vector3.yAxis * (height + 3), worldParams)
	if hit and hit.Normal.Y >= 0.35 then
		local lift = math.max(0, hit.Position.Y + height + 0.1 - position.Y)
		if lift > 0 then
			local ceiling =
				Workspace:Raycast(position, Vector3.yAxis * (lift + rig.root.Size.Y / 2), worldParams)
			if ceiling then
				lift = math.max(0, ceiling.Distance - rig.root.Size.Y / 2 - 0.1)
			end
			position += Vector3.yAxis * lift
		end
	end
	return CFrame.lookAt(position, position + look.Unit)
end
local function finish(rig: Rig, reason: string, destination: CFrame?)
	local state, before = rig.motion, rig.before
	local frame = destination or (if state then Motion.RootFrame(state) else rig.root.CFrame)
	local velocity = if state
			and Motion.IsAirborne(state)
			and (reason == "Timeout" or reason == "FlyTimeout")
		then state.velocity
		else Vector3.zero
	if reason == "Rejected" and before then
		frame, velocity = before.frame, before.velocity
	end
	if not destination and rig.kind ~= "Bag" and reason ~= "Removed" and reason ~= "Rejected" then
		frame = upright(rig, frame)
	end
	if rig.root.Parent then
		rootFrame(rig, frame)
		rig.root.Anchored = if rig.kind == "Bag"
			then true
			else (if before then before.anchored else rig.root.Anchored)
		rig.root.AssemblyLinearVelocity = if rig.kind == "Bag" then Vector3.zero else velocity
		rig.root.AssemblyAngularVelocity = if reason == "Rejected" and before
			then before.angularVelocity
			else Vector3.zero
	end
	restoreParts(rig)
	if rig.humanoid and before then
		rig.humanoid.AutoRotate = before.autoRotate
	end
	Streaming.Restore(rig.streaming, rig.model, rig.owner)
	rig.streaming = nil
	if rig.ownership and rig.root.Parent and not rig.root.Anchored then
		local saved = rig.ownership
		pcall(function()
			if saved.automatic then
				rig.root:SetNetworkOwnershipAuto()
			elseif saved.owner and saved.owner.Parent == Players then
				rig.root:SetNetworkOwner(saved.owner)
			else
				rig.root:SetNetworkOwner(nil)
			end
		end)
	end
	if state then
		rig.controlVersion += 1
		send({
			{
				kind = "Stop",
				actorId = rig.id,
				actorKind = rig.kind,
				userId = if rig.owner then rig.owner.UserId else 0,
				generation = rig.generation,
				revision = rig.revision,
				session = rig.session,
				version = rig.controlVersion,
				time = Workspace:GetServerTimeNow(),
				rootFrame = frame,
				reason = reason,
			},
		})
	end
	rig.motion, rig.before, rig.ownership = nil, nil, nil
	rig.active, rig.anchoredByService, rig.settled = false, rig.kind == "Bag", false
	rig.nextSupportCheck = 0
	active[rig.actor] = nil
	rig.lastSentFrame, rig.lastSentPhase = nil, nil
	if rig.actor.Parent then
		if reason == "FlyTimeout" and rig.kind == "Player" then
			-- Revision-scoped permission for the owner's existing air-jump controller.
			rig.actor:SetAttribute("RagdollFlyTimeoutRevision", rig.revision)
		end
		rig.actor:SetAttribute("RagdollPhase", "Stop")
		rig.actor:SetAttribute("IsRagdolled", false)
	end
	restoreNpcAnimate(rig)
	rig.collider = nil
	rig.actor:SetAttribute("RagdollFlyRecoveryRevision", nil)
end
local function destroy(rig: Rig)
	if rig.destroyed then
		return
	end
	rig.destroyed = true
	finish(rig, "Removed")
	disconnect(rig.connections)
	rigs[rig.actor], actorsById[rig.id], active[rig.actor] = nil, nil, nil
	if CollectionService:HasTag(rig.actor, "CombatActor") then
		CollectionService:RemoveTag(rig.actor, "CombatActor")
	end
	if rig.kind == "Bag" and rig.model.Parent then
		rig.model:Destroy()
	end
	filterDirty = true
end
local function profileFor(rig: Rig, id: string, strength: number): any?
	local original = profiles[id]
	if not original then
		if not unknownProfiles[id] then
			unknownProfiles[id] = true
			warn("Unknown Cartoon weapon profile:", id)
		end
		return nil
	end
	local copy: any = table.clone(original)
	copy.HorizontalSpeed *= strength
	copy.LaunchHeight *= strength
	copy.TimeToApex *= math.sqrt(strength)
	if rig.kind == "Bag" then
		copy.FlyVisualOffset, copy.RestVisualOffset = Vector3.zero, Vector3.zero
		copy.FlyTimeout = 0 -- Bags keep their existing overall timeout and scripted settling.
	elseif rig.kind ~= "Player" then
		copy.FlyTimeoutRequiresJump = true
	end
	
	return table.freeze(copy)
end
local function openSession(rig: Rig, state: Motion.State, now: number, stun: number, showTrail: boolean)
	rig.motion = state
	rig.revision += 1
	rig.launchedAt, rig.endsAt = now + stun, now + stun + state.profile.MaxDuration
	rig.voidPending, rig.settled = false, false
	rig.nextSupportCheck = 0
	nextSession += 1
	assert(nextSession <= 4294967295, "Knockback session IDs exhausted")
	rig.session, rig.sequence, rig.controlVersion, rig.reactionVersion = nextSession, 0, 1, 0
	rig.actor:SetAttribute("RagdollFlyTimeoutRevision", nil)
	rig.actor:SetAttribute("RagdollFlyRecoveryRevision", nil)
	rig.actor:SetAttribute("RagdollShowTrail", showTrail)
	publish(rig)
	Streaming.Update(rig.streaming, rig.owner, state.position, now, true)
	rig.lastSentFrame, rig.lastSentPhase = Motion.RootFrame(state), state.phase
	send({ descriptor(rig, "Start", now) })
end
local settleBag: (Rig) -> ()
settleBag = function(rig: Rig)
	if rig.destroyed or not alive(rig) then
		return
	end
	if not begin(rig) then
		return
	end
	updateFilter()
	local base = profileFor(rig, "Slap", 1)
	if not base then
		finish(rig, "InvalidProfile")
		return
	end
	local profile = table.clone(base)
	profile.HorizontalSpeed, profile.RestDuration, profile.GroundBounceCount, profile.WallBounceCount =
		0, 0, 0, 0
	local state =
		Motion.Start(rig.root, assert(rig.collider), table.freeze(profile), "Slap", -Vector3.zAxis, nil, 0)
	if not state then
		finish(rig, "InvalidSpawn", rig.spawnFrame)
		warn("Training bag has no valid spawn clearance:", rig.actor:GetFullName())
		return
	end
	state.velocity, state.launchVelocity, state.heading = Vector3.zero, Vector3.zero, rig.bagYaw
	openSession(rig, state, Workspace:GetServerTimeNow(), 0, false)
end

function Service.RegisterActor(actor: Actor, kind: string?, owner: Player?): number?
	if not initialized then
		Service.Init()
	end
	local existing = rigs[actor]
	if existing then
		return existing.id
	end
	if not actor:IsDescendantOf(Workspace) then
		return nil
	end
	owner = owner or (if actor:IsA("Model") then Players:GetPlayerFromCharacter(actor) else nil)
	kind = kind or (if owner then "Player" elseif actor:IsA("BasePart") then "Bag" else "NPC")
	local root: BasePart?
	local humanoid: Humanoid? = nil
	local model: Model
	if kind == "Bag" and actor:IsA("BasePart") then
		root = actor
		local container = Instance.new("Model")
		container.Name = "TrainingBag_" .. tostring(nextActor + 1)
		container.Parent = assert(runtime)
		actor.Parent = container
		container.PrimaryPart = actor
		model = container
	elseif actor:IsA("Model") and (kind == "Player" or kind == "NPC") then
		model = actor
		local candidate = actor:FindFirstChild("HumanoidRootPart")
		root = if candidate and candidate:IsA("BasePart") then candidate else nil
		humanoid = actor:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			return nil
		end
		if not humanoid:FindFirstChildOfClass("Animator") then
			Instance.new("Animator", humanoid)
		end
	else
		return nil
	end
	local body = assert(root)
	nextActor += 1
	local look = body.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.001 then
		look = -Vector3.zAxis
	end
	local rig: Rig = {
		actor = actor,
		kind = kind :: string,
		id = nextActor,
		owner = owner,
		model = model,
		root = body,
		humanoid = humanoid,
		generation = HttpService:GenerateGUID(false),
		revision = 0,
		spawnFrame = body.CFrame,
		originalSize = body.Size,
		bagYaw = CFrame.lookAt(Vector3.zero, look.Unit),
		parts = {},
		connections = {},
		active = false,
		destroyed = false,
		anchoredByService = kind == "Bag",
		collider = nil,
		motion = nil,
		session = 0,
		sequence = 0,
		controlVersion = 0,
		reactionVersion = 0,
		endsAt = 0,
		launchedAt = 0,
		voidPending = false,
		settled = false,
		nextSupportCheck = 0,
		before = nil,
		ownership = nil,
		animate = nil,
		animateEnabled = nil,
		streaming = nil,
		lastSentFrame = nil,
		lastSentPhase = nil,
	}
	rigs[actor], actorsById[rig.id] = rig, rig
	filterDirty = true
	actor:SetAttribute("KnockbackActorId", rig.id)
	actor:SetAttribute("KnockbackActorKind", rig.kind)
	actor:SetAttribute("RagdollGeneration", rig.generation)
	actor:SetAttribute("RagdollMode", "Cartoon")
	actor:SetAttribute("IsRagdolled", false)
	CollectionService:AddTag(actor, "CombatActor")
	table.insert(
		rig.connections,
		actor.AncestryChanged:Connect(function()
			if not actor:IsDescendantOf(Workspace) then
				destroy(rig)
			end
		end)
	)
	table.insert(
		rig.connections,
		model.DescendantAdded:Connect(function(instance)
			if rig.active and instance:IsA("BasePart") then
				rememberPart(rig, instance)
			end
		end)
	)
	if humanoid then
		table.insert(
			rig.connections,
			humanoid.Died:Connect(function()
				destroy(rig)
			end)
		)
	end
	if kind == "Bag" then
		body.Anchored = true
		task.defer(function()
			if rigs[actor] == rig and not rig.active then
				settleBag(rig)
			end
		end)
	end
	return rig.id
end
function Service.GetActorFromPart(part: BasePart): Actor?
	local cursor: Instance? = part
	while cursor and cursor ~= Workspace do
		local rig = rigs[cursor]
		if rig then
			if rig.active then
				return nil
			end -- Held visual bodies are never authoritative hit targets.
			if part:FindFirstAncestorOfClass("Accessory") or part:FindFirstAncestorOfClass("Tool") then
				return nil
			end
			local equipped = part:FindFirstAncestor("EquippedWeapon")
			if equipped then
				return nil
			end
			return rig.actor
		end
		cursor = cursor.Parent
	end
	return nil
end
function Service.GetActiveTargetsInBox(frame: CFrame, size: Vector3, exclude: Actor?): { HitCandidate }
	local targets: { HitCandidate } = {}
	for _, rig in active do
		local state = rig.motion
		if rig.actor == exclude or not state or not alive(rig) then
			continue
		end
		local targetFrame = if rig.kind == "Bag"
			then Motion.RootFrame(state)
			else CFrame.new(state.position)
		local targetSize = if rig.kind == "Bag"
			then rig.originalSize
			else Vector3.one * (state.radius * 2)
		-- Match the former GetPartBoundsInBox query, including the sphere's box bounds.
		if HitQuery.BoxesOverlap(frame, size, targetFrame, targetSize) then
			local position = if rig.kind == "Bag"
				then HitQuery.ClosestBoxPoint(targetFrame, targetSize, frame.Position)
				else HitQuery.ClosestSpherePoint(state.position, state.radius, frame.Position)
			table.insert(targets, { actor = rig.actor, position = position })
		end
	end
	return targets
end

function Service.GetAuthoritativePosition(actor: Actor): Vector3?
	local rig = rigs[actor]
	if rig then
		if rig.motion then
			return rig.motion.position
		end
		return rig.root.Position
	end
	local root = if actor:IsA("BasePart") then actor else actor:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end
function Service.IsRagdolled(actor: Actor): boolean
	local rig = rigs[actor]
	return rig ~= nil and rig.active
end
function Service.IsKnockbackAnchored(actor: Actor): boolean
	local rig = rigs[actor]
	return rig ~= nil and rig.anchoredByService and rig.root.Anchored
end
function Service.SetVoidHandler(handler: (Actor, Vector3) -> ())
	voidHandler = handler
end
function Service.ApplyHit(actor: Actor, direction: Vector3, context: HitContext): boolean
	if actor:GetAttribute("IsInvulnerable") == true then return false end -- bots after a respawn (players are gated in CombatService)
	if not initialized then
		Service.Init()
	end
	if
		typeof(direction) ~= "Vector3"
		or not finite(direction.X)
		or not finite(direction.Y)
		or not finite(direction.Z)
		or type(context) ~= "table"
		or type(context.weaponId) ~= "string"
		or type(context.strength) ~= "number"
		or not finite(context.strength)
		or context.strength < GameConfig.Combat.MinChargeMultiplier
		or context.strength > GameConfig.Combat.MaxChargeMultiplier
		or (context.knockbackMultiplier ~= nil and (type(context.knockbackMultiplier) ~= "number"
			or not finite(context.knockbackMultiplier) or context.knockbackMultiplier <= 0))
	then
		return false
	end
	local horizontal = direction * Vector3.new(1, 0, 1)
	if horizontal.Magnitude < 0.001 then
		return false
	end
	local rig = rigs[actor]
	if not rig or not alive(rig) then
		return false
	end
	local power = context.strength * (context.knockbackMultiplier or 1)
	local profile = profileFor(rig, context.weaponId, power)
	if not profile then
		return false
	end
	if not rig.active and rig.kind ~= "Bag" then
		for _, part in rig.model:GetDescendants() do
			if part:IsA("BasePart") and part.Anchored then
				return false
			end
		end
	end
	local wasActive = rig.active
	if not begin(rig) then
		return false
	end
	updateFilter()
	local stun = profile.StunDuration
	local state = Motion.Start(
		rig.root,
		assert(rig.collider),
		profile,
		context.weaponId,
		horizontal.Unit,
		rig.motion,
		stun
	)
	if not state then
		if not wasActive then
			finish(rig, "Rejected")
		end
		return false
	end
	if rig.kind == "Bag" then
		state.heading = rig.bagYaw
	end
	openSession(rig, state, Workspace:GetServerTimeNow(), stun, true)
	return true
end
function Service.Cancel(actor: Actor, reason: string?, destination: CFrame?)
	local rig = rigs[actor]
	if not rig and actor:IsDescendantOf(Workspace) then
		Service.RegisterActor(actor)
		rig = rigs[actor]
	end
	if not rig then
		if destination then
			actor:PivotTo(destination)
			actor:SetAttribute("RagdollGeneration", HttpService:GenerateGUID(false))
			actor:SetAttribute("LastHitBy", nil)
		end
		return
	end
	finish(rig, reason or "Cancelled", destination)
	rig.voidPending = false
	if destination then
		rig.generation = HttpService:GenerateGUID(false)
		rig.revision = 0
		actor:SetAttribute("RagdollGeneration", rig.generation)
		actor:SetAttribute("RagdollRevision", 0)
		actor:SetAttribute("LastHitBy", nil)
		if rig.kind == "Bag" then
			rig.root.Size = rig.originalSize
			local face = actor:GetAttribute("Face1")
			if rig.root:IsA("MeshPart") and type(face) == "string" then
				rig.root.TextureID = face
			end
			task.defer(function()
				if rigs[actor] == rig and not rig.active then
					settleBag(rig)
				end
			end)
		end
	end
end
function Service.GetNetworkStats(): any
	return Diagnostics.Read(stats)
end

local function trackPlayer(player: Player)
	if playerConnections[player] then
		return
	end
	local function characterAdded(character: Model)
		task.spawn(function()
			character:WaitForChild("HumanoidRootPart", 10)
			character:WaitForChild("Humanoid", 10)
			if player.Character == character then
				Service.RegisterActor(character, "Player", player)
			end
		end)
	end
	playerConnections[player] = {
		player.CharacterAdded:Connect(characterAdded),
		player.CharacterRemoving:Connect(function(character)
			local rig = rigs[character]
			if rig then
				destroy(rig)
			end
		end),
	}
	if player.Character then
		characterAdded(player.Character)
	end
end
local function canJumpRecover(rig: Rig): boolean
	local motion = rig.motion
	if not motion then return false end

	return rig.kind == "Player"
		and rig.active
		and alive(rig)
		and not rig.voidPending
		and motion.profile.FlyTimeoutRequiresJump == true
		and motion.profile.FlyTimeout > 0
		and motion.flyTime >= motion.profile.FlyTimeout
		and Motion.IsAirborne(motion)
end
function Service.Init()
	if initialized then
		return
	end
	initialized = true
	if not PhysicsService:IsCollisionGroupRegistered(GROUP) then
		PhysicsService:RegisterCollisionGroup(GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(GROUP, GROUP, false)
	local folder = Workspace:FindFirstChild("KnockbackRuntime")
	if folder and folder:IsA("Folder") then
		runtime = folder
	else
		local created = Instance.new("Folder")
		created.Name, created.Parent = "KnockbackRuntime", Workspace
		runtime = created
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local connections = playerConnections[player]
		if connections then
			disconnect(connections)
			playerConnections[player] = nil
		end
		for _, rig in rigs do
			if rig.owner == player then
				destroy(rig)
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	for _, tag in { "ArenaNPC", "TraningNPC", "TrainingBag" } do
		local function added(instance: Instance)
			task.defer(function()
				if not instance:IsDescendantOf(Workspace) then
					return
				end
				if tag == "TrainingBag" and instance:IsA("BasePart") then
					Service.RegisterActor(instance, "Bag")
				elseif instance:IsA("Model") then
					Service.RegisterActor(instance, "NPC")
				end
			end)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(added)
		for _, instance in CollectionService:GetTagged(tag) do
			added(instance)
		end
	end
	local bootstrapTimes: { [Player]: number } = {}
	Players.PlayerRemoving:Connect(function(player)
		bootstrapTimes[player] = nil
	end)
	initialState.OnServerInvoke = function(player: Player)
		local now = Workspace:GetServerTimeNow()
		if now - (bootstrapTimes[player] or -math.huge) < Network.ResyncInterval then
			return { throttled = true }
		end
		bootstrapTimes[player] = now
		local sessions = {}
		for _, rig in active do
			if rig.motion then
				table.insert(sessions, descriptor(rig, "Bootstrap", now))
			end
		end
		Diagnostics.Add(stats, "BootstrapResponses")
		return { time = now, sessions = sessions }
	end
	reactionRemote.OnServerEvent:Connect(
		function(player: Player, generation: any, revision: any, impactId: any, action: any, category: any)
			if SharedConfig.Animation.LocalReactionPrediction then
				return
			end
			local character = player.Character
			local rig = if character then rigs[character] else nil
			if not rig or rig.owner ~= player or rig.kind ~= "Player" or not rig.active or not rig.motion then
				return
			end
			Diagnostics.Add(stats, "ReactionRequests")
			if
				Combat.Reaction.Accept(
					rig.motion.impacts,
					rig.generation,
					rig.revision,
					generation,
					revision,
					impactId,
					action,
					category
				)
			then
				rig.reactionVersion += 1
				Diagnostics.Add(stats, "AcceptedReactions")
				for _, impact in rig.motion.impacts do
					if impact.id == impactId then
						send({
							{
								kind = "Reaction",
								session = rig.session,
								reactionVersion = rig.reactionVersion,
								impact = table.clone(impact),
							},
						})
						break
					end
				end
			end
		end
	)
	local accumulator, snapshotAccumulator = 0, 0
	local STEP = 1 / 60
	RunService.Heartbeat:Connect(function(dt)
		local now = Workspace:GetServerTimeNow()
		accumulator = math.min(accumulator + dt, STEP * 8)
		snapshotAccumulator += dt
		updateFilter()
		for _, rig in active do
			if not alive(rig) then
				destroy(rig)
			end
		end
		while accumulator >= STEP do
			accumulator -= STEP
			for _, rig in active do
				local state = rig.motion
				if not state then
					continue
				end
				if rig.kind == "Bag" and rig.settled and state.phase == "Rest" then
					-- Idle bags keep their hit bounds/session, but skip the full solver.
					-- Property comparisons catch support changes without new connections.
					local support = state.support
					local supportUnchanged = not support
						or (
							support:IsDescendantOf(Workspace)
							and support.CanCollide
							and support.CFrame == state.supportFrame
							and support.Size == state.supportSize
						)
					if
						supportUnchanged
						and state.velocity.Magnitude <= 0.05
						and now < rig.nextSupportCheck
					then
						continue
					end
					rig.nextSupportCheck = now + SETTLED_BAG_CHECK_INTERVAL
				end
				local completed, completionReason = Motion.Step(state, STEP, now - accumulator)
				if state.position.Y < GameConfig.VoidHeight and not rig.voidPending then
					rig.voidPending = true
					local handler = voidHandler
					if handler then
						handler(rig.actor, state.position)
					elseif rig.kind == "Bag" then
						Service.Cancel(rig.actor, "Void", rig.spawnFrame)
					else
						finish(rig, "Void")
					end
					continue
				end
				if rig.motion ~= state then
					continue
				end
				if state.position.Y < Workspace.FallenPartsDestroyHeight then
					if rig.kind == "Bag" then
						Service.Cancel(rig.actor, "DestructionHeight", rig.spawnFrame)
					else
						finish(rig, "DestructionHeight")
					end
					continue
				end
				if rig.kind == "Bag" and completed then
					if Motion.IsAirborne(state) then
						Service.Cancel(rig.actor, "InvalidPosition", rig.spawnFrame)
						continue
					end
					if not rig.settled then
						rig.settled, rig.endsAt = true, math.huge
						rig.nextSupportCheck = now + SETTLED_BAG_CHECK_INTERVAL
						rig.actor:SetAttribute("RagdollEndsAt", 0)
					end
					local frame = Motion.RootFrame(state)
					if rig.root.CFrame ~= frame then
						rig.root.CFrame = frame
					end
				elseif completed then
					finish(rig, completionReason or "Recovered")
					continue
				end
				if rig.kind == "Bag" and rig.settled and Motion.IsAirborne(state) then
					rig.settled, rig.endsAt = false, now + state.profile.MaxDuration
					rig.actor:SetAttribute("RagdollEndsAt", rig.endsAt)
				end
				if now >= rig.endsAt then
					if rig.kind == "Bag" then
						Service.Cancel(rig.actor, "Timeout", rig.spawnFrame)
					else
						finish(rig, "Timeout")
					end
					continue
				end
				
				local readyRevision = if canJumpRecover(rig) then rig.revision else nil
				if rig.actor:GetAttribute("RagdollFlyRecoveryRevision") ~= readyRevision then
					rig.actor:SetAttribute("RagdollFlyRecoveryRevision", readyRevision)
				end
				
				local events = {}
				for _, event in state.events do
					rig.controlVersion += 1
					table.insert(events, {
						kind = event.kind,
						session = rig.session,
						version = rig.controlVersion,
						checkpoint = checkpoint(rig, event, event.time),
						impact = event.impact,
					})
				end
				table.clear(state.events)
				if state.changed then
					rig.actor:SetAttribute("RagdollPhase", state.phase)
				end
				state.changed = false
				send(events)
			end
		end
		-- Focus changes run once per Heartbeat, outside fixed-step catch-up.
		for _, rig in active do
			local state = rig.motion
			if state and rig.owner then
				Streaming.Update(rig.streaming, rig.owner, state.position, now)
			end
		end
		if snapshotAccumulator >= 1 / Network.SnapshotRate then
			snapshotAccumulator %= 1 / Network.SnapshotRate
			local samples: { Knockback.Sample } = {}
			local count = 0
			for _, rig in active do
				local state = rig.motion
				if not state then
					continue
				end
				count += 1
				local frame = Motion.RootFrame(state)
				local previous = rig.lastSentFrame
				if
					not previous
					or (frame.Position - previous.Position).Magnitude >= 0.002
					or state.phase ~= rig.lastSentPhase
				then
					table.insert(samples, checkpoint(rig, nil, now))
					rig.lastSentFrame, rig.lastSentPhase = frame, state.phase
				end
			end
			Diagnostics.Set(stats, "ActiveCharacters", count)
			for _, data in Codec.Encode(samples, now, Network.MaxPayloadBytes) do
				Diagnostics.Add(stats, "MovementMessages")
				Diagnostics.Add(stats, "EncodedMovementBytes", buffer.len(data))
				Diagnostics.Add(stats, "EncodedFanoutBytes", buffer.len(data) * #Players:GetPlayers())
				snapshotRemote:FireAllClients(data)
			end
		end
	end)
	
	recoveryRequest.OnServerEvent:Connect(function(player, generation, revision)
		local character = player.Character
		local rig = if character then rigs[character] else nil

		if not rig or rig.owner ~= player then return end
		if generation ~= rig.generation or revision ~= rig.revision then return end
		if not canJumpRecover(rig) then return end

		finish(rig, "FlyTimeout")
	end)
end
return Service
