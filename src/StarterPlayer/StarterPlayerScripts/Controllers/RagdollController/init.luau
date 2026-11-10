--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SharedConfig = require(ReplicatedStorage:WaitForChild("Config"))
local Combat = require(ReplicatedStorage:WaitForChild("Combat"))
local Knockback = require(ReplicatedStorage:WaitForChild("Knockback"))
local Motion = require(script:WaitForChild("CartoonPresentation"))
local Tilt = require(script:WaitForChild("Tilt"))
local Reactions = require(script:WaitForChild("Reactions"))
local Actors, Reaction = Knockback.Actors, Combat.Reaction
local RagdollController = {}
local localPlayer = Players.LocalPlayer :: Player
local initialized = false

-- Local ribbon settings; no trail instances or landing polls are replicated.
local TRAIL_COLOR = Color3.new(1, 1, 1)
local TRAIL_WIDTH_RATIO = 0.3
local TRAIL_LIFETIME = 0.2
local TRAIL_MAX_LENGTH = 8
local TRAIL_TRANSPARENCY = NumberSequence.new(0.2, 1)
local TRAIL_WIDTH_SCALE = NumberSequence.new(1, 0)
local VISUAL_INTERVAL = 1 / 20

-- Local presentation and cleanup resources for one visible combat actor.
type Record = {
	actor: Knockback.Actor, -- Character Model or training-bag BasePart being presented.
	kind: string, -- Player, NPC, or Bag; bags skip character animation and tilt.
	root: BasePart?, -- Current character root or bag mesh; nil while unavailable.
	humanoid: Humanoid?, -- Current character Humanoid; nil for bags or missing streamed rigs.
	connections: { RBXScriptConnection }, -- Actor-level attribute and descendant listeners.
	humanoidConnections: { RBXScriptConnection }, -- Listeners tied to the current Humanoid, including death cleanup.
	rootConnections: { RBXScriptConnection }, -- Listeners tied to the current root's anchoring state.
	active: boolean, -- Whether knockback presentation is currently active for this actor.
	destroyed: boolean, -- Whether this record has been released and callbacks must stop using it.
	queued: boolean, -- Whether a deferred refresh is already scheduled, preventing duplicate work.
	revision: number, -- Latest hit revision applied to this local record.
	generation: string?, -- Actor lifetime identifier used to detect replacements.
	tilt: Tilt.State, -- Joint rotation layer and orientation-blending state.
	reactions: Reactions.State, -- Animation selection, track playback, and per-impact reaction state.
	recoveryToken: number, -- Invalidates delayed restoration when another hit or cleanup starts.
	camera: Camera?, -- Local player's camera temporarily following the knockback root.
	cameraSubject: (BasePart | Humanoid)?, -- Previous camera subject saved for restoration.
	animateScripts: { [LocalScript]: boolean }, -- Default Animate LocalScripts mapped to their previous Enabled values.
	animateConnections: { RBXScriptConnection }, -- Listeners keeping saved Animate scripts disabled during knockback.
	trail: Trail?, -- Local flight trail, if currently created.
	trailTorso: BasePart?, -- Torso or bag part holding the trail attachments.
	trailAttachments: { Attachment }, -- Attachments owned by the local trail and destroyed with it.
}
local records: { [Instance]: Record } = {}
local activeRecords: { [Record]: boolean } = {}
local recoveringRecords: { [Record]: boolean } = {}

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function suspendAnimate(record: Record)
	if not record.active or localPlayer.Character ~= record.actor then
		return
	end
	for _, child in record.actor:GetChildren() do
		if child:IsA("LocalScript") and child.Name == "Animate" and record.animateScripts[child] == nil then
			record.animateScripts[child] = child.Enabled
			child.Enabled = false
			table.insert(
				record.animateConnections,
				child:GetPropertyChangedSignal("Enabled"):Connect(function()
					if record.active and child.Enabled then
						child.Enabled = false
					end
				end)
			)
		end
	end
end

local function restoreAnimate(record: Record)
	disconnectAll(record.animateConnections)
	local restarting = false
	for animate, wasEnabled in record.animateScripts do
		if wasEnabled and animate.Parent then
			restarting = true
		end
	end
	-- Animate may destroy old tracks during startup; invalidate cached resources.
	if restarting then
		Reactions.ClearTracks(record.reactions)
	end
	for animate, wasEnabled in record.animateScripts do
		if animate.Parent then
			animate.Enabled = wasEnabled
		end
	end
	table.clear(record.animateScripts)
end

local function clearTrail(record: Record)
	local trail = record.trail
	record.trail, record.trailTorso = nil, nil
	if trail then
		trail.Enabled = false
		trail:Clear()
		trail:Destroy()
	end
	for _, attachment in record.trailAttachments do
		attachment:Destroy()
	end
	table.clear(record.trailAttachments)
end

local function ensureTrail(record: Record)
	if record.kind == "Bag" and record.actor:GetAttribute("RagdollShowTrail") == false then
		clearTrail(record)
		return
	end
	local body: BasePart? = nil
	if record.actor:IsA("BasePart") then
		body = record.actor
	else
		local torso = record.actor:FindFirstChild("Torso") or record.actor:FindFirstChild("UpperTorso")
		if torso and torso:IsA("BasePart") then
			body = torso
		end
	end
	if not body then
		return
	end
	if record.trail and record.trail.Parent == body and record.trailTorso == body then
		return
	end
	clearTrail(record)
	local halfWidth = math.clamp(body.Size.X * TRAIL_WIDTH_RATIO, 0.3, 1.2) * 0.5
	local first, second = Instance.new("Attachment"), Instance.new("Attachment")
	first.Name, second.Name = "CombatFlightTrail0", "CombatFlightTrail1"
	first.Position, second.Position =
		Vector3.new(-halfWidth, 0, body.Size.Z * 0.5), Vector3.new(halfWidth, 0, body.Size.Z * 0.5)
	record.trailAttachments, record.trailTorso = { first, second }, body
	first.Parent, second.Parent = body, body
	local trail = Instance.new("Trail")
	trail.Name = "CombatFlightTrail"
	trail.Attachment0, trail.Attachment1 = first, second
	trail.Color, trail.Transparency, trail.WidthScale =
		ColorSequence.new(TRAIL_COLOR), TRAIL_TRANSPARENCY, TRAIL_WIDTH_SCALE
	trail.Lifetime, trail.MaxLength, trail.MinLength = TRAIL_LIFETIME, TRAIL_MAX_LENGTH, 0.05
	trail.FaceCamera, trail.LightEmission, trail.LightInfluence = true, 1, 0
	record.trail = trail
	trail.Parent = body
end

local function updateTrail(record: Record)
	local phase = Motion.GetState(record.actor) or record.actor:GetAttribute("RagdollPhase")
	if not record.active or phase == "Stun" or phase == "Slide" or phase == "Rest" or phase == "Stop" then
		if record.trail then
			clearTrail(record)
		end
	else
		ensureTrail(record)
	end
end

local function restoreCamera(record: Record)
	local camera = record.camera
	if camera and camera.CameraSubject == record.root then
		local previous = record.cameraSubject
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character == record.actor and previous and previous.Parent then
			camera.CameraSubject = previous
		elseif humanoid then
			camera.CameraSubject = humanoid
		end
	end
	record.camera, record.cameraSubject = nil, nil
end

local function followRoot(record: Record)
	if localPlayer.Character ~= record.actor or not record.root then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom or record.camera == camera then
		return
	end
	local subject = camera.CameraSubject
	-- Leave spectating and other explicitly selected camera subjects alone.
	if
		subject ~= record.humanoid
		and subject ~= record.root
		and (not subject or not subject:IsDescendantOf(record.actor))
	then
		return
	end
	restoreCamera(record)
	record.camera, record.cameraSubject = camera, subject
	camera.CameraSubject = record.root
end

local function stop(record: Record, recover: boolean, preserveDecisions: boolean?)
	if not record.active then
		return
	end
	record.active = false
	activeRecords[record] = nil
	record.recoveryToken += 1
	local token = record.recoveryToken
	clearTrail(record)
	if record.actor:IsA("Model") then
		Reactions.Stop(record.reactions, preserveDecisions)
		if recover and record.root and record.humanoid and record.humanoid.Health > 0 then
			recoveringRecords[record] = true
		else
			recoveringRecords[record] = nil
			Tilt.Reset(record.tilt)
		end
	end
	restoreCamera(record)
	if recover then
		local transition = record.reactions.presentation.transition
		local duration = if transition then transition.duration else 0
		task.delay(duration + 0.1, function()
			if not record.destroyed and not record.active and record.recoveryToken == token then
				restoreAnimate(record)
			end
		end)
	else
		restoreAnimate(record)
	end
end

local refresh: (Record) -> ()
local function queueRefresh(record: Record)
	if record.destroyed or record.queued then
		return
	end
	record.queued = true
	task.defer(function()
		record.queued = false
		if not record.destroyed then
			refresh(record)
		end
	end)
end

refresh = function(record: Record)
	local actor = record.actor
	local root = Actors.GetRoot(actor)
	local humanoid: Humanoid? = if actor:IsA("Model") then actor:FindFirstChildOfClass("Humanoid") else nil
	local phase = Motion.GetState(actor)
	local enabled = actor:IsDescendantOf(Workspace)
		and root ~= nil
		and root.Anchored
		and (record.kind == "Bag" or (humanoid ~= nil and humanoid.Health > 0))
		and actor:GetAttribute("IsRagdolled") == true
		and phase ~= "Stop"
	local structuralChange = record.root ~= root or record.humanoid ~= humanoid
	if record.active and (not enabled or structuralChange) then
		local recover = actor:GetAttribute("IsRagdolled") ~= true or phase == "Stop"
		stop(record, recover, not recover)
	end
	if record.humanoid ~= humanoid then
		disconnectAll(record.humanoidConnections)
		if humanoid then
			table.insert(
				record.humanoidConnections,
				humanoid.Died:Connect(function()
					stop(record, false)
					Reactions.Destroy(record.reactions)
					Tilt.Reset(record.tilt)
				end)
			)
		end
	end
	if record.root ~= root then
		disconnectAll(record.rootConnections)
		if root then
			table.insert(
				record.rootConnections,
				root:GetPropertyChangedSignal("Anchored"):Connect(function()
					queueRefresh(record)
				end)
			)
		end
	end
	record.root, record.humanoid = root, humanoid
	if actor:IsA("Model") then
		Reactions.Observe(record.reactions, actor, humanoid, enabled)
	end
	if not enabled then
		return
	end
	local generation = actor:GetAttribute("RagdollGeneration")
	local revision = actor:GetAttribute("RagdollRevision")
	if generation ~= record.generation or revision ~= record.revision then
		record.generation = if type(generation) == "string" then generation else nil
		record.revision = if type(revision) == "number" then revision else 0
		Tilt.Reset(record.tilt)
		clearTrail(record)
	end
	if not record.active then
		record.active = true
		record.recoveryToken += 1
		activeRecords[record], recoveringRecords[record] = true, nil
	end
	suspendAnimate(record)
	followRoot(record)
	updateTrail(record)
end

local function release(actor: Instance)
	local record = records[actor]
	if not record then
		return
	end
	local preserve = actor:GetAttribute("IsRagdolled") == true
		and (record.kind == "Bag" or (record.humanoid ~= nil and record.humanoid.Health > 0))
	stop(record, false, preserve)
	record.destroyed = true
	record.recoveryToken += 1
	disconnectAll(record.connections)
	disconnectAll(record.humanoidConnections)
	disconnectAll(record.rootConnections)
	restoreAnimate(record)
	Reactions.Destroy(record.reactions, preserve)
	Tilt.Reset(record.tilt)
	clearTrail(record)
	activeRecords[record], recoveringRecords[record], records[actor] = nil, nil, nil
end

local function track(actor: Knockback.Actor, _actorId: number)
	if records[actor] then
		return
	end
	local record: Record = {
		actor = actor,
		kind = Actors.GetKind(actor) or "NPC",
		root = nil,
		humanoid = nil,
		connections = {},
		humanoidConnections = {},
		rootConnections = {},
		active = false,
		destroyed = false,
		queued = false,
		revision = -1,
		generation = nil,
		tilt = Tilt.New(),
		reactions = Reactions.New(),
		recoveryToken = 0,
		camera = nil,
		cameraSubject = nil,
		animateScripts = {},
		animateConnections = {},
		trail = nil,
		trailTorso = nil,
		trailAttachments = {},
	}
	records[actor] = record
	for _, attribute in
		{
			"IsRagdolled",
			"RagdollGeneration",
			"RagdollRevision",
			"RagdollPhase",
			"RagdollLaunchedAt",
			"RagdollWeaponId",
			"RagdollShowTrail",
		}
	do
		table.insert(
			record.connections,
			actor:GetAttributeChangedSignal(attribute):Connect(function()
				queueRefresh(record)
			end)
		)
	end
	table.insert(
		record.connections,
		actor.DescendantAdded:Connect(function(item)
			if
				item:IsA("Animator")
				or item:IsA("Humanoid")
				or item:IsA("BasePart")
				or item:IsA("Animation")
				or (item:IsA("LocalScript") and item.Name == "Animate")
			then
				queueRefresh(record)
			end
			if item:IsA("Motor6D") or item.ClassName == "AnimationConstraint" then
				Tilt.MarkDirty(record.tilt)
			end
		end)
	)
	table.insert(
		record.connections,
		actor.DescendantRemoving:Connect(function(item)
			if
				item == record.root
				or item == record.humanoid
				or item == record.reactions.animator
				or item:IsA("Animator")
				or item:IsA("Animation")
			then
				queueRefresh(record)
			end
			if item == record.tilt.joint or item == record.tilt.waist or item == record.tilt.core then
				Tilt.MarkDirty(record.tilt)
			end
		end)
	)
	table.insert(
		record.connections,
		actor.AncestryChanged:Connect(function()
			queueRefresh(record)
		end)
	)
	refresh(record)
end

local function beforeAnimation(dt: number)
	for record in activeRecords do
		local actor, humanoid = record.actor, record.humanoid
		if actor:IsA("Model") and humanoid then
			local presentation = record.reactions.presentation
			local generation, revision, impact =
				presentation.generation, presentation.revision, presentation.impactId
			Reactions.Update(record.reactions, actor, humanoid, dt)
			if
				generation ~= presentation.generation
				or revision ~= presentation.revision
				or presentation.phase == "Normal"
				or impact ~= presentation.impactId
			then
				Tilt.ClearPending(record.tilt)
			end
			if presentation.impactId > 0 and not presentation.categoryConfirmed then
				Tilt.CapturePending(record.tilt, actor)
			end
			Tilt.Restore(record.tilt)
		end
	end
	for record in recoveringRecords do
		Tilt.Restore(record.tilt)
	end
end

local function afterAnimation(dt: number)
	for record in activeRecords do
		local actor, root, humanoid = record.actor, record.root, record.humanoid
		if not actor:IsA("Model") or not root or not humanoid or humanoid.Health <= 0 then
			continue
		end
		local phase = Motion.GetState(actor) or actor:GetAttribute("RagdollPhase")
		if phase == "Stun" then
			Tilt.Reset(record.tilt)
			continue
		end
		local presentation = record.reactions.presentation
		local pending = presentation.impactId > 0 and not presentation.categoryConfirmed
		local flying = not pending
			and (
				presentation.phase == "Fly"
				or (presentation.phase == "Bounce" and SharedConfig.Animation.BounceFollowVelocity == true)
			)
		local horizontalBounce = if presentation.phase == "Bounce"
				and not flying
				and not pending
			then presentation.category
			else nil
		Tilt.Apply(
			record.tilt,
			actor,
			root,
			Motion.GetVelocity(actor),
			flying,
			dt,
			SharedConfig.Animation.RestFadeTime,
			presentation.transition,
			horizontalBounce,
			pending,
			if presentation.phase == "Rest" then presentation.restDirection else nil
		)
	end
	for record in recoveringRecords do
		local actor, root, humanoid = record.actor, record.root, record.humanoid
		local transition = record.reactions.presentation.transition
		if
			record.active
			or not actor:IsA("Model")
			or not root
			or not root.Parent
			or not humanoid
			or humanoid.Health <= 0
			or not transition
		then
			recoveringRecords[record] = nil
			Tilt.Reset(record.tilt)
		else
			Tilt.Apply(record.tilt, actor, root, Vector3.zero, false, dt, 0, transition)
			if Reaction.Alpha(transition, os.clock()) >= 1 then
				recoveringRecords[record] = nil
				Tilt.Reset(record.tilt)
			end
		end
	end
end

function RagdollController.Init()
	if initialized then
		return
	end
	initialized = true
	Motion.Init()
	Reactions.Preload()
	Actors.Observe(track, function(actor)
		release(actor)
	end)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		for record in activeRecords do
			followRoot(record)
		end
	end)
	RunService.PreAnimation:Connect(beforeAnimation)
	RunService.PreSimulation:Connect(afterAnimation)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < VISUAL_INTERVAL then
			return
		end
		elapsed %= VISUAL_INTERVAL
		for record in activeRecords do
			-- Reliable Stop may arrive before its replicated attributes.
			if Motion.GetState(record.actor) == "Stop" then
				queueRefresh(record)
			else
				updateTrail(record)
			end
		end
	end)
end

return RagdollController
