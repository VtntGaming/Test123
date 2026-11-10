--!strict
-- Owns actor availability, replayable command ingestion and stable surface identities.
-- Persistent player data is deliberately separate from these predicted actor instances.

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Types = require(script.Parent.Types)
local Attributes = require(script.Parent.Attributes)
local Diagnostics = require(script.Parent.Diagnostics)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local LocalSimulation = SimulationConfig.ClientSimulation.LocalPlayer

--// Types
type Actor = Types.Actor
type ActorRecord = Types.ActorRecord
type Command = Types.Command
export type State = {
	-- Current simulation records indexed by actor; readiness gates participation in each step.
	Records: { [Actor]: ActorRecord },
	-- Observes record creation, removal, owner, and readiness changes outside replay; returns cleanup.
	Observe: ((Actor, ActorRecord?) -> ()) -> () -> (),
	-- Starts observing combat actors and workspace surface identities once, restoring records as actor layouts become available.
	Init: () -> (),
	-- Binds actor carriers and creates or refreshes the record for its root, optional humanoid, and owner.
	Register: (Actor, BasePart, Humanoid?, Player?) -> ActorRecord,
	-- Clears the actor record, disconnects owned listeners, and releases forced client prediction.
	Remove: (Actor) -> (),
	-- Queues a sequenced callback scoped to the actor's current generation for the next server Drain.
	Queue: (Actor, () -> ()) -> (),
	-- Publishes pending surface metadata and applies queued commands whose actor generation and sequence are still valid.
	Drain: () -> (),
	-- Resolves a tracked surface identifier to its part, or nil when no part is registered.
	Surface: (number) -> BasePart?,
	-- Checks an instance and its bound simulation carriers against attribute layout budgets.
	ValidateLayout: (Instance) -> (),
	-- Rebuilds cached parts, joints, meshes, attachments, and weapon references from the actor's current layout.
	Refresh: (Actor) -> (),
	-- Refreshes readiness, owner, health, animator, and carrier prediction before simulation, removing unavailable records.
	Prepare: () -> (),
	-- Projects tracked scale onto joints, meshes, and attachments outside the simulation callback.
	ApplyJoints: () -> (),
}

--// Properties
local Surfaces: { [number]: BasePart? } = {}
local SurfaceConnections: { [BasePart]: RBXScriptConnection } = {}
local CollisionConnections: { [BasePart]: RBXScriptConnection } = {}
local PendingSurfaces: { [BasePart]: number } = {}
local PendingWallFlags: { [BasePart]: boolean } = {}
local VisibilityConnections: { [BasePart]: RBXScriptConnection } = {}
local Commands: { Command } = {}
local NextCommand = 0
local NextSurface = 0
local Initialized = false
local ActorConnections: { [Actor]: { RBXScriptConnection } } = {}
local PredictionConnections: { [Actor]: Attributes.Subscription } = {}
local ForcedRoots: { [Actor]: BasePart } = {}
local Observers: { [(Actor, ActorRecord?) -> ()]: boolean } = {}

--// Controller
local State: State = { Records = {} } :: State

local function Notify(actor: Actor, record: ActorRecord?)
	for callback in Observers do callback(actor, record) end
end

-- A missing root suspends simulation without ending observation of the tagged actor.
local function ClearRecord(actor: Actor)
	local record = State.Records[actor]
	if record then
		Attributes.Remove(record.Root)
		if record.Humanoid then
			Attributes.Remove(record.Humanoid)
		end
	end
	State.Records[actor] = nil
	if record then Notify(actor, nil) end
	local prediction = PredictionConnections[actor]
	if prediction then
		prediction:Disconnect()
		PredictionConnections[actor] = nil
	end
	local root = ForcedRoots[actor]
	if root and root.Parent then
		RunService:SetPredictionMode(root, Enum.PredictionMode.Automatic)
	end
	ForcedRoots[actor] = nil
end

local function ObserveSurface(instance: Instance)
	if not instance:IsA("BasePart") or SurfaceConnections[instance] then
		return
	end
	local function refresh()
		if not instance.CanCollide then
			return
		end
		if IsServer then
			PendingWallFlags[instance] = instance.Transparency < 1
		end
		local id = instance:GetAttribute("SASurfaceId")
		if IsServer and (type(id) ~= "number" or (Surfaces[id] ~= nil and Surfaces[id] ~= instance)) then
			if not PendingSurfaces[instance] then
				NextSurface += 1
				PendingSurfaces[instance] = NextSurface
			end
			return
		end
		if type(id) == "number" then
			local existing = Surfaces[id]
			if not existing or not existing.Parent or existing == instance then
				Surfaces[id] = instance
			end
		end
	end
	SurfaceConnections[instance] = instance:GetAttributeChangedSignal("SASurfaceId"):Connect(refresh)
	CollisionConnections[instance] = instance:GetPropertyChangedSignal("CanCollide"):Connect(refresh)
	VisibilityConnections[instance] = instance:GetPropertyChangedSignal("Transparency"):Connect(refresh)
	refresh()
end

--// APIs
function State.Observe(callback)
	Observers[callback] = true
	return function() Observers[callback] = nil end
end

function State.ValidateLayout(instance)
	Attributes.Validate(instance)
end

function State.Register(actor, root, humanoid, owner)
	local existing = State.Records[actor]
	if existing and existing.Humanoid and existing.Humanoid ~= humanoid then
		Attributes.Remove(existing.Humanoid)
	end
	if existing and existing.Root ~= root then
		Attributes.Remove(existing.Root)
	end
	local ready = Attributes.Bind(root, humanoid)
	if IsServer and actor:IsA("Model") then
		if actor:GetAttribute("SABaseModelScale") == nil then
			actor:SetAttribute("SABaseModelScale", actor:GetScale())
		end
		if humanoid and humanoid:GetAttribute("SABaseHipHeight") == nil then
			humanoid:SetAttribute("SABaseHipHeight", humanoid.HipHeight)
		end
	end
	local generation = actor:GetAttribute("RagdollGeneration") :: string
	if existing and existing.Root == root and existing.Generation == generation then
		local changed = existing.Ready ~= ready or existing.Owner ~= owner
		existing.Ready = ready
		existing.Owner = owner
		if humanoid and not existing.Humanoid then
			existing.HipHeight = humanoid.HipHeight
		end
		existing.Humanoid = humanoid
		existing.R6 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R6
		if changed then Notify(actor, existing) end
		return existing
	end
	local parts: { BasePart } = {}
	local geometry: { { Part: BasePart, Size: Vector3, Weapon: boolean } } = {}
	local joints: { { Joint: JointInstance, C0: CFrame, C1: CFrame, Weapon: boolean } } = {}
	if actor:IsA("BasePart") then
		table.insert(parts, actor)
	end
	for _, item in actor:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(parts, item)
		end
		if item:IsA("JointInstance") then
			table.insert(
				joints,
				{ Joint = item, C0 = item.C0, C1 = item.C1, Weapon = item:FindFirstAncestor("EquippedWeapon") ~= nil }
			)
		end
	end
	for _, part in parts do
		table.insert(
			geometry,
			{ Part = part, Size = part.Size, Weapon = part:FindFirstAncestor("EquippedWeapon") ~= nil }
		)
	end
	local record: ActorRecord = {
		Actor = actor,
		Ready = ready,
		Root = root,
		Humanoid = humanoid,
		Owner = owner,
		Generation = generation,
		Parts = parts,
		Geometry = geometry,
		Joints = joints,
		Meshes = {},
		Attachments = {},
		HipHeight = if humanoid
			then (humanoid:GetAttribute("SABaseHipHeight") :: number?) or humanoid.HipHeight / ((Attributes.Get(
				root,
				"SABodyScale"
			) :: number?) or 1)
			else 0,
		Scale = if actor:IsA("Model")
			then (actor:GetAttribute("SABaseModelScale") :: number?) or actor:GetScale()
			else 1,
		Alive = humanoid == nil or humanoid.Health > 0,
		R6 = humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R6,
		Animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil,
		Weapon = nil,
	}
	State.Records[actor] = record
	if not IsServer then
		local connection = PredictionConnections[actor]
		if connection then
			connection:Disconnect()
		end
		local previous = ForcedRoots[actor]
		if previous and previous.Parent then
			RunService:SetPredictionMode(previous, Enum.PredictionMode.Automatic)
		end
		ForcedRoots[actor] = nil
		local function updatePrediction()
			if State.Records[actor] ~= record or not root.Parent then
				return
			end
			if Attributes.Get(root, "KBActive") == true then
				if ForcedRoots[actor] ~= root then
					RunService:SetPredictionMode(root, Enum.PredictionMode.On)
					ForcedRoots[actor] = root
				end
			elseif ForcedRoots[actor] == root then
				RunService:SetPredictionMode(root, Enum.PredictionMode.Automatic)
				ForcedRoots[actor] = nil
			end
		end
		PredictionConnections[actor] = Attributes.Observe(root, "KBActive", updatePrediction)
		updatePrediction()
	end
	State.Refresh(actor)
	Notify(actor, record)
	return record
end

-- C0/C1 have no Simulation Access. Geometry state is tracked in the callback;
-- the joint projection runs outside it and never becomes a second scale clock.
function State.ApplyJoints()
	for _, record in State.Records do
		local bodyScaling = IsServer or record.Owner ~= LocalPlayer or LocalSimulation.BodyScaling
		local weaponScaling = IsServer or record.Owner ~= LocalPlayer or LocalSimulation.WeaponScaling
		local bodyScale = (Attributes.Get(record.Root, "SABodyScale") :: number?) or 1
		local weaponScale = (Attributes.Get(record.Root, "SAWeaponScale") :: number?) or 1
		if Attributes.Get(record.Root, "SAWeaponScaleRevision") ~= ((record.Actor:GetAttribute("WeaponRevision") :: number?) or 0) then
			weaponScale = 1
		end
		local includeWeapon = Attributes.Get(record.Root, "SAScaleWeapon") == true
		for _, item in record.Joints do
			if item.Joint.Parent and (if item.Weapon then weaponScaling else bodyScaling) then
				local scale = if item.Weapon then weaponScale * (if includeWeapon then bodyScale else 1) else bodyScale
				local part0, part1 = item.Joint.Part0, item.Joint.Part1
				local scale0 = if part0 and part0:FindFirstAncestor("EquippedWeapon") then scale else bodyScale
				local scale1 = if part1 and part1:FindFirstAncestor("EquippedWeapon") then scale else bodyScale
				item.Joint.C0 = CFrame.new(item.C0.Position * scale0) * item.C0.Rotation
				item.Joint.C1 = CFrame.new(item.C1.Position * scale1) * item.C1.Rotation
			end
		end
		for _, item in record.Meshes do
			if item.Mesh.Parent and (if item.Weapon then weaponScaling else bodyScaling) then
				local scale = if item.Weapon then weaponScale * (if includeWeapon then bodyScale else 1) else bodyScale
				item.Mesh.Scale, item.Mesh.Offset = item.Scale * scale, item.Offset * scale
			end
		end
		for _, item in record.Attachments do
			if item.Attachment.Parent and (if item.Weapon then weaponScaling else bodyScaling) then
				local scale = if item.Weapon then weaponScale * (if includeWeapon then bodyScale else 1) else bodyScale
				item.Attachment.CFrame = CFrame.new(item.Frame.Position * scale) * item.Frame.Rotation
			end
		end
	end
end

function State.Prepare()
	for actor, record in State.Records do
		if not actor.Parent then
			State.Remove(actor)
			continue
		end
		if not record.Root.Parent or (actor:IsA("Model") and record.Root.Parent ~= actor) then
			ClearRecord(actor)
			continue
		end
		local humanoid = record.Humanoid
		local wasReady, previousOwner = record.Ready, record.Owner
		record.Ready = Attributes.Bind(record.Root, humanoid)
		if not IsServer then
			local mode = if RunService:GetPredictionStatus(record.Root) == Enum.PredictionStatus.Predicted
				then Enum.PredictionMode.On
				else Enum.PredictionMode.Off
			Attributes.Predict(record.Root, mode)
			if humanoid then
				Attributes.Predict(humanoid, mode)
			end
		end
		if actor:IsA("Model") then
			record.Owner = Players:GetPlayerFromCharacter(actor)
		end
		record.Alive = humanoid == nil or humanoid.Health > 0
		record.Animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
		if wasReady ~= record.Ready or previousOwner ~= record.Owner then Notify(actor, record) end
		local animate = actor:FindFirstChild("Animate")
		if animate and animate:IsA("BaseScript") then
			animate.Enabled = false
		end
	end
end

function State.Refresh(actor)
	local record = State.Records[actor]
	if not record then
		return
	end
	local humanoid = record.Humanoid
	if humanoid then
		record.HipHeight = (humanoid:GetAttribute("SABaseHipHeight") :: number?) or record.HipHeight
	end
	if actor:IsA("Model") then
		record.Scale = (actor:GetAttribute("SABaseModelScale") :: number?) or record.Scale
	end
	local weapon = actor:FindFirstChild("EquippedWeapon")
	record.Weapon = if weapon and weapon:IsA("Model") then weapon else nil
	table.clear(record.Geometry)
	table.clear(record.Joints)
	table.clear(record.Meshes)
	table.clear(record.Attachments)
	table.clear(record.Parts)
	local descendants = actor:GetDescendants()
	if actor:IsA("BasePart") then
		table.insert(descendants, actor)
	end
	for _, item in descendants do
		if item:IsA("BasePart") then
			local cached = item:GetAttribute("SABasePartSize") :: Vector3?
			local size = cached or item.Size
			if not cached then
				if IsServer then
					item:SetAttribute("SABasePartSize", size)
				end
			end
			table.insert(record.Parts, item)
			table.insert(
				record.Geometry,
				{ Part = item, Size = size, Weapon = item:FindFirstAncestor("EquippedWeapon") ~= nil }
			)
		elseif item:IsA("JointInstance") then
			local cachedC0 = item:GetAttribute("SABaseC0") :: CFrame?
			local cachedC1 = item:GetAttribute("SABaseC1") :: CFrame?
			local c0, c1 = cachedC0 or item.C0, cachedC1 or item.C1
			if not cachedC0 or not cachedC1 then
				if IsServer then
					item:SetAttribute("SABaseC0", c0)
					item:SetAttribute("SABaseC1", c1)
				end
			end
			table.insert(
				record.Joints,
				{ Joint = item, C0 = c0, C1 = c1, Weapon = item:FindFirstAncestor("EquippedWeapon") ~= nil }
			)
		elseif item:IsA("Attachment") then
			local cached = item:GetAttribute("SABaseAttachment") :: CFrame?
			local frame = cached or item.CFrame
			if IsServer and not cached then
				item:SetAttribute("SABaseAttachment", frame)
			end
			table.insert(
				record.Attachments,
				{ Attachment = item, Frame = frame, Weapon = item:FindFirstAncestor("EquippedWeapon") ~= nil }
			)
		elseif item:IsA("SpecialMesh") then
			local cachedScale, cachedOffset =
				item:GetAttribute("SABaseMeshScale") :: Vector3?, item:GetAttribute("SABaseMeshOffset") :: Vector3?
			local scale, offset = cachedScale or item.Scale, cachedOffset or item.Offset
			if IsServer and (not cachedScale or not cachedOffset) then
				item:SetAttribute("SABaseMeshScale", scale)
				item:SetAttribute("SABaseMeshOffset", offset)
			end
			table.insert(record.Meshes, {
				Mesh = item,
				Scale = scale,
				Offset = offset,
				Weapon = item:FindFirstAncestor("EquippedWeapon") ~= nil,
			})
		end
	end
end

function State.Remove(actor)
	ClearRecord(actor)
	local connections = ActorConnections[actor]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	ActorConnections[actor] = nil
end

function State.Queue(actor, apply)
	NextCommand += 1
	table.insert(Commands, {
		Actor = actor,
		Generation = actor:GetAttribute("RagdollGeneration") :: string,
		Sequence = NextCommand,
		Apply = apply,
	})
end

function State.Drain()
	for part, allowed in PendingWallFlags do
		if part.Parent then
			part:SetAttribute("SAWallJumpAllowed", allowed)
		end
		PendingWallFlags[part] = nil
	end
	for part, id in PendingSurfaces do
		if part.Parent then
			part:SetAttribute("SASurfaceId", id)
			Surfaces[id] = part
		end
		PendingSurfaces[part] = nil
	end
	local pending = Commands
	Commands = {}
	for _, command in pending do
		local record = State.Records[command.Actor]
		if
			record
			and record.Generation == command.Generation
			and command.Actor.Parent
			and record.Root.Parent
			and command.Sequence > ((Attributes.Get(record.Root, "SACommand") :: number?) or 0)
		then
			Attributes.Set(record.Root, "SACommand", command.Sequence)
			command.Apply()
		else
			Diagnostics.Count("StaleCommands")
		end
	end
end

function State.Surface(id)
	return Surfaces[id]
end

function State.Init()
	if Initialized then
		return
	end
	Initialized = true
	for _, instance in Workspace:GetDescendants() do
		local id = instance:GetAttribute("SASurfaceId")
		if type(id) == "number" then
			NextSurface = math.max(NextSurface, id)
		end
	end
	for _, instance in Workspace:GetDescendants() do
		ObserveSurface(instance)
	end
	Workspace.DescendantAdded:Connect(ObserveSurface)
	Workspace.DescendantRemoving:Connect(function(instance)
		if instance:IsA("BasePart") then
			local connection = SurfaceConnections[instance]
			if connection then
				connection:Disconnect()
				SurfaceConnections[instance] = nil
			end
			local collision = CollisionConnections[instance]
			if collision then
				collision:Disconnect()
				CollisionConnections[instance] = nil
			end
			PendingSurfaces[instance] = nil
			PendingWallFlags[instance] = nil
			local visibility = VisibilityConnections[instance]
			if visibility then
				visibility:Disconnect()
				VisibilityConnections[instance] = nil
			end
			local id = instance:GetAttribute("SASurfaceId")
			if type(id) == "number" and Surfaces[id] == instance then
				Surfaces[id] = nil
			end
		end
	end)
	local function observe(actor: Instance)
		if not actor:IsA("Model") and not actor:IsA("BasePart") then
			return
		end
		if ActorConnections[actor] then
			return
		end
		local connections: { RBXScriptConnection } = {}
		ActorConnections[actor] = connections
		local function refresh()
			if
				ActorConnections[actor] ~= connections
				or not actor.Parent
				or not CollectionService:HasTag(actor, "CombatActor")
			then
				return
			end
			local root = if actor:IsA("BasePart") then actor else actor:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and type(actor:GetAttribute("RagdollGeneration")) == "string" then
				State.Register(
					actor,
					root,
					if actor:IsA("Model") then actor:FindFirstChildOfClass("Humanoid") else nil,
					if actor:IsA("Model") then Players:GetPlayerFromCharacter(actor) else nil
				)
				State.Refresh(actor)
			else
				ClearRecord(actor)
			end
		end
		local function schedule()
			task.defer(refresh)
		end
		local baselineConnections: { [Instance]: RBXScriptConnection } = {}
		local function attach(instance: Instance)
			if baselineConnections[instance] then
				return
			end
			local connection = instance.AttributeChanged:Connect(function(name: string)
				if
					name == "SABasePartSize"
					or name == "SABaseC0"
					or name == "SABaseC1"
					or name == "SABaseHipHeight"
					or name == "SABaseMeshScale"
					or name == "SABaseMeshOffset"
					or name == "SABaseAttachment"
				then
					schedule()
				end
			end)
			baselineConnections[instance] = connection
			table.insert(connections, connection)
			schedule()
		end
		table.insert(connections, actor.DescendantAdded:Connect(attach))
		table.insert(
			connections,
			actor.DescendantRemoving:Connect(function(instance: Instance)
				local connection = baselineConnections[instance]
				if connection then
					connection:Disconnect()
					baselineConnections[instance] = nil
				end
				schedule()
			end)
		)
		table.insert(connections, actor:GetAttributeChangedSignal("RagdollGeneration"):Connect(refresh))
		table.insert(connections, actor:GetAttributeChangedSignal("SABaseModelScale"):Connect(refresh))
		for _, child in actor:GetDescendants() do
			attach(child)
		end
		refresh()
	end
	CollectionService:GetInstanceAddedSignal("CombatActor"):Connect(observe)
	CollectionService:GetInstanceRemovedSignal("CombatActor"):Connect(function(actor)
		State.Remove(actor :: Actor)
	end)
	for _, actor in CollectionService:GetTagged("CombatActor") do
		observe(actor)
	end
end

return State
