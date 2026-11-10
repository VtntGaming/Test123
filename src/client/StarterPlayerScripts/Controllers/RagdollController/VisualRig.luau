--!strict
-- Owns isolated appearances for Cartoon reactions, analytical actor timelines and smoothed facing.
-- Rendering changes decorative geometry only; gameplay remains on the source actor.

--// Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Config = require(ReplicatedStorage.Config.Animation)
local Actors = require(ReplicatedStorage.Knockback.Actors)
local Diagnostics = require(ReplicatedStorage.Knockback.Diagnostics)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)
local RenderClock = require(script.Parent.Parent.SimulationPresentationController.Clock)
local Motion = require(script.Parent.Parent.SimulationPresentationController.Motion)
local Smoothing = require(script.Parent.Parent.SimulationPresentationController.Smoothing)

--// Types
type Actor = Actors.Actor
export type Owner = "Cartoon" | "Simulation"
export type Presentation = {
	-- Optional displayed root transform; Cartoon ownership takes precedence over this override.
	Root: CFrame?,
	-- Optional analytical body scale relative to the cached unscaled geometry.
	BodyScale: number?,
	-- Optional analytical weapon scale before the body's weapon-scale contribution.
	WeaponScale: number?,
}
type PartPair = { Original: BasePart, Visual: BasePart, Transparency: number, Size: Vector3, Weapon: boolean }
type JointPair = { Original: Motor6D, Visual: Motor6D, C0: CFrame, C1: CFrame, Weapon: boolean }
type DecalPair = { Original: Decal, Visual: Decal }
type MeshPair = { Original: SpecialMesh, Visual: SpecialMesh, Scale: Vector3, Offset: Vector3, Weapon: boolean }
type AttachmentPair = { Original: Attachment, Visual: Attachment, Frame: CFrame, Weapon: boolean }
type LinkPair = { Original: JointInstance | WeldConstraint, Visual: JointInstance | WeldConstraint }
type AnimationLink = { Original: AnimationConstraint, Visual: AnimationConstraint }
type PathStep = { Name: string, ClassName: string, Index: number }
type GuiPair = { Gui: BillboardGui, Previous: Instance?, Applied: BasePart, External: boolean? }
export type Record = {
	Actor: Actor,
	Model: Model,
	Root: BasePart,
	SourceRoot: BasePart,
	Generation: string,
	Revision: number,
	Owners: { Cartoon: boolean?, Simulation: boolean? },
	-- Current timeline/facing overrides; never applied to the physical source actor.
	Presentation: Presentation?,
	Sample: Motion.Sample?,
	PendingSample: Motion.Sample?,
	Parts: { PartPair },
	Joints: { JointPair },
	Guis: { GuiPair },
	-- Critically damped visual correction; native velocity is retained between small corrections.
	Correction: Smoothing.Offset,
	Destroyed: boolean,
	Visuals: { [Instance]: Instance },
	Pending: { [Instance]: boolean },
	HierarchyConnections: { [Instance]: RBXScriptConnection },
	Links: { LinkPair },
	AnimationLinks: { AnimationLink },
	Connections: { RBXScriptConnection },
	Deformation: Vector3Value?,
	RecoveryAt: number?,
	RecoveryPoses: { [Motor6D]: CFrame },
	Decals: { DecalPair },
	Meshes: { MeshPair },
	AttachmentPairs: { AttachmentPair },
	Camera: Camera?,
	CameraSubject: (Humanoid | BasePart)?,
}
export type VisualRig = {
	Init: () -> (),
	-- Replaces the current presentation-only root/scale overrides, or clears them with nil.
	Present: (Actor, Presentation?) -> (),
	-- Applies final render-time rotation to a Simulation-owned visual, returning its frame; never advances damping or turns Cartoon rigs.
	PresentRotation: (Actor, CFrame) -> CFrame?,
	Acquire: (Actor, BasePart, Owner?) -> Record?,
	Get: (Instance) -> Record?,
	Original: (Instance) -> Actor?,
	Release: (Actor, Owner?) -> (),
	Render: (number) -> (),
	Subject: (Instance) -> BasePart?,
	Adorn: (Actor, BillboardGui, BasePart) -> (),
	Deform: (Actor) -> Vector3Value?,
	GetDiagnostics: () -> Diagnostics.Snapshot,
	FollowCamera: (Actor, Camera, Humanoid | BasePart) -> (),
	-- Restores the saved camera subject only while the camera still follows this visual rig.
	RestoreCamera: (Actor) -> (),
}

--// Properties
local DiagnosticState = Diagnostics.New(SimulationConfig.Diagnostics)
local Records: { [Actor]: Record } = {}
local Originals: { [Instance]: Actor } = {}
local Folder: Folder?
local Initialized = false

--// Controller
local VisualRig: VisualRig = {} :: VisualRig

local function RelativePath(instance: Instance, ancestor: Instance): { PathStep }
	local path: { PathStep } = {}
	local cursor: Instance? = instance
	while cursor and cursor ~= ancestor do
		local index = 0
		local parent = cursor.Parent
		if parent then
			for _, sibling in parent:GetChildren() do
				if sibling.Archivable and sibling.Name == cursor.Name and sibling.ClassName == cursor.ClassName then
					index += 1
				end
				if sibling == cursor then
					break
				end
			end
		end
		table.insert(
			path,
			1,
			{ Name = cursor.Name, ClassName = cursor.ClassName, Index = if cursor.Archivable then index else 0 }
		)
		cursor = cursor.Parent
	end
	return path
end

local function Corresponding(model: Instance, path: { PathStep }): Instance?
	local result: Instance? = model
	for _, step in path do
		if not result then
			return nil
		end
		local matched: Instance? = nil
		local index = 0
		for _, child in result:GetChildren() do
			if child.Name == step.Name and child.ClassName == step.ClassName then
				index += 1
				if index == step.Index then
					matched = child
					break
				end
			end
		end
		result = matched
	end
	return result
end

local function Excluded(instance: Instance): boolean
	return Attributes.IsContainer(instance)
		or (instance:IsA("Folder") and instance.Name == "PublicValues")
		or instance:IsA("BaseScript")
		or instance:IsA("ModuleScript")
		or instance:IsA("BillboardGui")
		or instance:IsA("Sound")
		or instance:IsA("ParticleEmitter")
		or instance:IsA("Trail")
		or instance:IsA("Beam")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Sparkles")
		or instance:IsA("Highlight")
		or (instance:IsA("Constraint") and not instance:IsA("AnimationConstraint") and not instance:IsA(
			"WeldConstraint"
		))
		or instance:IsA("BodyMover")
end

local function StateOnly(instance: Instance, actor: Actor): boolean
	local cursor: Instance? = instance
	while cursor and cursor ~= actor do
		if Attributes.IsContainer(cursor) or (cursor:IsA("Folder") and cursor.Name == "PublicValues") then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

local function AffectsAppearance(instance: Instance): boolean
	return instance:IsA("BasePart")
		or instance:IsA("JointInstance")
		or instance:IsA("WeldConstraint")
		or instance:IsA("AnimationConstraint")
		or instance:IsA("Attachment")
		or instance:IsA("DataModelMesh")
		or instance:IsA("Decal")
		or instance:IsA("SurfaceAppearance")
		or instance:IsA("Clothing")
		or instance:IsA("BodyColors")
		or instance:IsA("CharacterMesh")
		or instance:IsA("WrapLayer")
		or instance:IsA("WrapTarget")
		or instance:IsA("Accessory")
		or instance:IsA("Model")
		or instance:IsA("Tool")
		or instance:IsA("BillboardGui")
end

local function Sanitize(branch: Instance, root: BasePart)
	local descendants = branch:GetDescendants()
	table.insert(descendants, 1, branch)
	for _, item in descendants do
		for _, tag in CollectionService:GetTags(item) do
			CollectionService:RemoveTag(item, tag)
		end
		for name in item:GetAttributes() do
			if string.sub(name, 1, 2) == "SA" or string.sub(name, 1, 2) == "KB" then
				item:SetAttribute(name, nil)
			end
		end
		if Excluded(item) then
			item:Destroy()
		elseif item:IsA("Humanoid") then
			-- Decorative rigs retain their Humanoid for appearance, but must never restore body collisions.
			item.EvaluateStateMachine = false
		elseif item:IsA("BasePart") then
			item.CanCollide, item.CanQuery, item.CanTouch, item.Massless = false, false, false, true
			item.Anchored = item == root
			item.LocalTransparencyModifier = 0
		end
	end
end

local function IsolateParts(record: Record)
	for _, pair in record.Parts do
		local part = pair.Visual
		if part.Parent and (part.CanCollide or part.CanQuery or part.CanTouch) then
			part.CanCollide, part.CanQuery, part.CanTouch = false, false, false
		end
	end
end

local function RestoreGui(pair: GuiPair)
	if pair.Gui.Adornee == pair.Applied then
		if pair.Previous and pair.Previous.Parent then
			pair.Gui.Adornee = pair.Previous
		else
			pair.Gui:ResetPropertyToDefault("Adornee")
		end
	end
end

local function BindGui(record: Record, gui: BillboardGui)
	for _, pair in record.Guis do
		if pair.Gui == gui then
			return
		end
	end
	local target = gui.Adornee or gui.Parent
	local visual = if target then record.Visuals[target] else nil
	if visual and visual:IsA("BasePart") then
		table.insert(record.Guis, { Gui = gui, Previous = gui.Adornee, Applied = visual })
		gui.Adornee = visual
	end
end

local function BindBranch(record: Record, source: Instance, branch: Instance)
	-- Resolve paths before stripping children so duplicate names retain their identity.
	local originals: { Instance } = {}
	local function collect(original: Instance)
		table.insert(originals, original)
		for _, child in original:GetChildren() do
			collect(child)
		end
	end
	collect(source)
	local matches: { [Instance]: Instance } = {}
	for _, original in originals do
		local visual = if original == source then branch else Corresponding(branch, RelativePath(original, source))
		if visual then
			matches[original] = visual
		end
	end
	Sanitize(branch, record.Root)
	local added: { [Instance]: boolean } = {}
	local discarded: { Instance } = {}
	for _, original in originals do
		local visual = matches[original]
		if visual and (visual == branch or visual:IsDescendantOf(branch)) then
			local previous = record.Visuals[original]
			local parent = original.Parent
			local visualParent = if parent then record.Visuals[parent] else nil
			if previous then
				-- Moving an existing part beneath a newly added container preserves its clone.
				table.insert(discarded, visual)
				if visualParent then
					previous.Parent = visualParent
				end
			else
				if original ~= source and visualParent then
					visual.Parent = visualParent
				end
				record.Visuals[original] = visual
				added[original] = true
				if original ~= record.Actor and (AffectsAppearance(original) or original:IsA("Folder")) then
					record.HierarchyConnections[original] = original
						:GetPropertyChangedSignal("Parent")
						:Connect(function()
							if not record.Destroyed then
								record.Pending[original] = true
							end
						end)
				end
			end
		end
	end
	for _, visual in discarded do
		visual:Destroy()
	end
	for _, original in originals do
		local visual = record.Visuals[original]
		if original:IsA("BillboardGui") and not StateOnly(original, record.Actor) then
			BindGui(record, original)
		end
		if not added[original] then
			continue
		end
		if original:IsA("BasePart") and visual and visual:IsA("BasePart") then
			table.insert(record.Parts, {
				Original = original,
				Visual = visual,
				Transparency = original.LocalTransparencyModifier,
				Size = (original:GetAttribute("SABasePartSize") :: Vector3?) or original.Size,
				Weapon = original:FindFirstAncestor("EquippedWeapon") ~= nil,
			})
			original.LocalTransparencyModifier = 1
		elseif original:IsA("Motor6D") and visual and visual:IsA("Motor6D") then
			table.insert(record.Joints, {
				Original = original,
				Visual = visual,
				C0 = (original:GetAttribute("SABaseC0") :: CFrame?) or original.C0,
				C1 = (original:GetAttribute("SABaseC1") :: CFrame?) or original.C1,
				Weapon = original:FindFirstAncestor("EquippedWeapon") ~= nil,
			})
		elseif original:IsA("Decal") and visual and visual:IsA("Decal") then
			table.insert(record.Decals, { Original = original, Visual = visual })
		elseif original:IsA("SpecialMesh") and visual and visual:IsA("SpecialMesh") then
			table.insert(record.Meshes, {
				Original = original,
				Visual = visual,
				Scale = (original:GetAttribute("SABaseMeshScale") :: Vector3?) or original.Scale,
				Offset = (original:GetAttribute("SABaseMeshOffset") :: Vector3?) or original.Offset,
				Weapon = original:FindFirstAncestor("EquippedWeapon") ~= nil,
			})
		elseif original:IsA("Attachment") and visual and visual:IsA("Attachment") then
			table.insert(record.AttachmentPairs, {
				Original = original,
				Visual = visual,
				Frame = (original:GetAttribute("SABaseAttachment") :: CFrame?) or original.CFrame,
				Weapon = original:FindFirstAncestor("EquippedWeapon") ~= nil,
			})
		end
		if
			(original:IsA("JointInstance") or original:IsA("WeldConstraint"))
			and visual
			and (visual:IsA("JointInstance") or visual:IsA("WeldConstraint"))
		then
			table.insert(record.Links, { Original = original, Visual = visual })
		end
		if original:IsA("AnimationConstraint") and visual and visual:IsA("AnimationConstraint") then
			table.insert(record.AnimationLinks, { Original = original, Visual = visual })
		end
	end
end

local function Relink(record: Record)
	for _, pair in record.Links do
		local first = if pair.Original.Part0 then record.Visuals[pair.Original.Part0] else nil
		local second = if pair.Original.Part1 then record.Visuals[pair.Original.Part1] else nil
		pair.Visual.Part0 = if first and first:IsA("BasePart") then first else nil
		pair.Visual.Part1 = if second and second:IsA("BasePart") then second else nil
	end
	for _, pair in record.AnimationLinks do
		local first = if pair.Original.Attachment0 then record.Visuals[pair.Original.Attachment0] else nil
		local second = if pair.Original.Attachment1 then record.Visuals[pair.Original.Attachment1] else nil
		pair.Visual.Attachment0 = if first and first:IsA("Attachment") then first else nil
		pair.Visual.Attachment1 = if second and second:IsA("Attachment") then second else nil
	end
end

local function EnsureVisual(record: Record, original: Instance): Instance?
	if original == record.Actor then
		return record.Visuals[original]
	end
	if
		not original:IsDescendantOf(record.Actor)
		or StateOnly(original, record.Actor)
		or Excluded(original)
		or not original.Archivable
	then
		return nil
	end
	local parent = original.Parent
	local visualParent = if parent then EnsureVisual(record, parent) else nil
	if not visualParent then
		return nil
	end
	local existing = record.Visuals[original]
	if existing then
		existing.Parent = visualParent
		return existing
	end
	local branch = original:Clone()
	if not branch then
		return nil
	end
	BindBranch(record, original, branch)
	-- Subtree clones retain references to objects outside the subtree. Never weld to the real actor.
	Relink(record)
	branch.Parent = visualParent
	IsolateParts(record)
	return branch
end

local function RemoveBranch(record: Record, branch: Instance)
	-- Moving within the same actor need not emit an actor-level DescendantAdded event.
	local survivors: { Instance } = {}
	for original, visual in record.Visuals do
		if
			visual:IsDescendantOf(branch)
			and original:IsDescendantOf(record.Actor)
			and not StateOnly(original, record.Actor)
		then
			table.insert(survivors, original)
		end
	end
	for _, original in survivors do
		EnsureVisual(record, original)
	end
	for original, visual in record.Visuals do
		if visual == branch or visual:IsDescendantOf(branch) then
			record.Visuals[original] = nil
			local connection = record.HierarchyConnections[original]
			if connection then
				connection:Disconnect()
				record.HierarchyConnections[original] = nil
			end
		end
	end
	branch:Destroy()
end

local function PrunePairs<T>(pairs: { T }, keep: (T) -> boolean)
	for index = #pairs, 1, -1 do
		if not keep(pairs[index]) then
			table.remove(pairs, index)
		end
	end
end

local function Synchronize(record: Record)
	if not next(record.Pending) then
		return
	end
	local pending = record.Pending
	record.Pending = {}
	-- Move surviving descendants first, before deleting their former visual ancestors.
	for original in pending do
		if not original:IsDescendantOf(record.Actor) or StateOnly(original, record.Actor) then
			continue
		end
		if original:IsA("BillboardGui") then
			BindGui(record, original)
		else
			EnsureVisual(record, original)
		end
	end
	for original in pending do
		if not original:IsDescendantOf(record.Actor) or StateOnly(original, record.Actor) then
			local visual = record.Visuals[original]
			if visual then
				RemoveBranch(record, visual)
			end
		end
	end
	PrunePairs(record.Parts, function(pair: PartPair)
		local keep = record.Visuals[pair.Original] == pair.Visual
		if not keep and pair.Original.LocalTransparencyModifier == 1 then
			pair.Original.LocalTransparencyModifier = pair.Transparency
		end
		return keep
	end)
	PrunePairs(record.Joints, function(pair: JointPair)
		local keep = record.Visuals[pair.Original] == pair.Visual
		if not keep then
			record.RecoveryPoses[pair.Visual] = nil
		end
		return keep
	end)
	PrunePairs(record.Decals, function(pair: DecalPair)
		return record.Visuals[pair.Original] == pair.Visual
	end)
	PrunePairs(record.Meshes, function(pair: MeshPair)
		return record.Visuals[pair.Original] == pair.Visual
	end)
	PrunePairs(record.AttachmentPairs, function(pair: AttachmentPair)
		return record.Visuals[pair.Original] == pair.Visual
	end)
	PrunePairs(record.Links, function(pair: LinkPair)
		return record.Visuals[pair.Original] == pair.Visual
	end)
	PrunePairs(record.AnimationLinks, function(pair: AnimationLink)
		return record.Visuals[pair.Original] == pair.Visual
	end)
	PrunePairs(record.Guis, function(pair: GuiPair)
		local keep = (pair.Gui:IsDescendantOf(record.Actor) or (pair.External == true and pair.Gui.Parent ~= nil))
			and pair.Applied:IsDescendantOf(record.Model)
		if not keep then
			RestoreGui(pair)
		end
		return keep
	end)
	-- Reparenting can change body/weapon membership without replacing the visual instance.
	for _, pair in record.Parts do
		pair.Weapon = pair.Original:FindFirstAncestor("EquippedWeapon") ~= nil
		pair.Size = (pair.Original:GetAttribute("SABasePartSize") :: Vector3?) or pair.Size
	end
	for _, pair in record.Joints do
		pair.Weapon = pair.Original:FindFirstAncestor("EquippedWeapon") ~= nil
		pair.C0 = (pair.Original:GetAttribute("SABaseC0") :: CFrame?) or pair.C0
		pair.C1 = (pair.Original:GetAttribute("SABaseC1") :: CFrame?) or pair.C1
	end
	for _, pair in record.Meshes do
		pair.Weapon = pair.Original:FindFirstAncestor("EquippedWeapon") ~= nil
		pair.Scale = (pair.Original:GetAttribute("SABaseMeshScale") :: Vector3?) or pair.Scale
		pair.Offset = (pair.Original:GetAttribute("SABaseMeshOffset") :: Vector3?) or pair.Offset
	end
	for _, pair in record.AttachmentPairs do
		pair.Weapon = pair.Original:FindFirstAncestor("EquippedWeapon") ~= nil
		pair.Frame = (pair.Original:GetAttribute("SABaseAttachment") :: CFrame?) or pair.Frame
	end
	Relink(record)
end

--// APIs
function VisualRig.Get(actor)
	return Records[(Originals[actor] or actor) :: Actor]
end

function VisualRig.Present(actor, presentation)
	local record = Records[actor]
	if record then
		record.Presentation = presentation
	end
end

function VisualRig.PresentRotation(actor, rotation)
	local record = Records[actor]
	local presentation = if record then record.Presentation else nil
	if
		not record
		or record.Destroyed
		or not record.Root.Parent
		or not record.Owners.Simulation
		or record.Owners.Cartoon
		or not presentation
	then
		return nil
	end
	local frame = CFrame.new(record.Root.Position) * rotation.Rotation
	presentation.Root = frame
	record.Root.CFrame = frame
	return frame
end

function VisualRig.Original(visual)
	return Originals[visual]
end

function VisualRig.Subject(actor)
	local record = VisualRig.Get(actor)
	return if record and not record.Destroyed then record.Root else Actors.GetRoot(actor)
end

local function RestoreCamera(record: Record)
	local camera, subject = record.Camera, record.CameraSubject
	if
		camera
		and camera.CameraType == Enum.CameraType.Custom
		and camera.CameraSubject == record.Root
		and subject
		and subject.Parent
	then
		camera.CameraSubject = subject
	end
	record.Camera, record.CameraSubject = nil, nil
end

function VisualRig.RestoreCamera(actor)
	local record = Records[actor]
	if record then
		RestoreCamera(record)
	end
end

function VisualRig.FollowCamera(actor, camera, subject)
	local record = Records[actor]
	if not record then
		return
	end
	record.Camera, record.CameraSubject = camera, subject
	camera.CameraSubject = record.Root
end

function VisualRig.Adorn(actor, gui, target)
	local record = Records[actor]
	if not record then
		return
	end
	for _, pair in record.Guis do
		if pair.Gui == gui then
			return
		end
	end
	for _, pair in record.Parts do
		if pair.Original == target then
			table.insert(record.Guis, { Gui = gui, Previous = gui.Adornee, Applied = pair.Visual, External = true })
			gui.Adornee = pair.Visual
			return
		end
	end
end

function VisualRig.Deform(actor)
	local record = Records[actor]
	if not record then
		return nil
	end
	if not record.Deformation then
		local value = Instance.new("Vector3Value")
		value.Name, value.Value, value.Parent = "CartoonDeformation", Vector3.one, record.Root
		record.Deformation = value
	end
	return record.Deformation
end

local function Destroy(actor: Actor)
	local record = Records[actor]
	if not record or record.Destroyed then
		return
	end
	record.Destroyed = true
	RestoreCamera(record)
	Diagnostics.Add(DiagnosticState, "Cleanups")
	for _, connection in record.Connections do
		connection:Disconnect()
	end
	for _, connection in record.HierarchyConnections do
		connection:Disconnect()
	end
	Records[actor], Originals[record.Model] = nil, nil
	for _, pair in record.Parts do
		if pair.Original.Parent and pair.Original.LocalTransparencyModifier == 1 then
			pair.Original.LocalTransparencyModifier = pair.Transparency
		end
	end
	for _, pair in record.Guis do
		RestoreGui(pair)
	end
	record.Model:Destroy()
end

function VisualRig.Release(actor, owner)
	local record = Records[actor]
	if not record then
		return
	end
	local key: Owner = owner or "Cartoon"
	record.Owners[key] = nil
	if not next(record.Owners) then
		Destroy(actor)
	end
end

function VisualRig.Acquire(actor, root, owner)
	local key: Owner = owner or "Cartoon"
	if key == "Cartoon" and not SimulationConfig.ClientPresentation.CartoonVisualRigs then
		return nil
	end
	local generation = actor:GetAttribute("RagdollGeneration") :: string
	local revision = (Attributes.Get(root, "KBSession") :: number?) or 0
	local existing = Records[actor]
	if existing and existing.SourceRoot == root and existing.Generation == generation then
		existing.Owners[key] = true
		if key == "Cartoon" and existing.Revision ~= revision then
			existing.Revision = revision
			existing.RecoveryAt = nil
			table.clear(existing.RecoveryPoses)
		end
		Synchronize(existing)
		return existing
	end
	Destroy(actor)
	local source: Instance = actor
	local archivable = source.Archivable
	source.Archivable = true
	local clone = source:Clone()
	source.Archivable = archivable
	local model: Model
	if clone:IsA("Model") then
		model = clone
	else
		model = Instance.new("Model")
		clone.Parent = model
	end
	model.Name = "CartoonVisual"
	model:SetAttribute("CartoonVisualOnly", true)
	local visualRoot = if actor:IsA("BasePart")
		then clone :: BasePart
		else model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not visualRoot then
		model:Destroy()
		return nil
	end
	if not Folder then
		local folder = Workspace:FindFirstChild("CombatLocalEffects")
		if folder and folder:IsA("Folder") then
			Folder = folder
		else
			local created = Instance.new("Folder")
			created.Name, created.Parent = "CombatLocalEffects", Workspace
			Folder = created
		end
	end
	visualRoot.CFrame = root.CFrame
	model.PrimaryPart = visualRoot
	local record: Record = {
		Actor = actor,
		Model = model,
		Root = visualRoot,
		SourceRoot = root,
		Generation = generation,
		Revision = revision,
		Owners = { [key] = true },
		Presentation = nil,
		Sample = nil,
		PendingSample = nil,
		Parts = {},
		Joints = {},
		Guis = {},
		Decals = {},
		Meshes = {},
		AttachmentPairs = {},
		Camera = nil,
		CameraSubject = nil,
		Correction = Smoothing.NewOffset(),
		Destroyed = false,
		Visuals = {},
		Pending = {},
		HierarchyConnections = {},
		Links = {},
		AnimationLinks = {},
		Connections = {},
		Deformation = nil,
		RecoveryAt = nil,
		RecoveryPoses = {},
	}
	BindBranch(record, actor, clone)
	Relink(record)
	ReplicatedValues.CopyToVisual(actor, model)
	model.Parent = Folder
	IsolateParts(record)
	RunService:SetPredictionMode(model, Enum.PredictionMode.Off)
	local function changed(instance: Instance)
		if
			not record.Destroyed
			and (record.Visuals[instance] ~= nil or (AffectsAppearance(instance) and not StateOnly(instance, actor)))
		then
			record.Pending[instance] = true
		end
	end
	record.Connections = {
		actor.DescendantAdded:Connect(changed),
		actor.DescendantRemoving:Connect(changed),
	}
	Records[actor], Originals[model] = record, actor
	Diagnostics.Add(DiagnosticState, "Acquired")
	return record
end

function VisualRig.Render(dt)
	for actor, record in Records do
		if
			record.Destroyed
			or not actor.Parent
			or not record.SourceRoot.Parent
			or Actors.GetRoot(actor) ~= record.SourceRoot
			or (actor:GetAttribute("RagdollGeneration") :: string?) ~= record.Generation
		then
			Destroy(actor)
			continue
		end
		Synchronize(record)
		local root = record.SourceRoot
		local target = root.CFrame
		local now = RenderClock.Now()
		local active = Attributes.Get(root, "KBActive") == true
		local frozen = actor:GetAttribute("IsFrozen") == true or actor:GetAttribute("TimeStopped") == true
		local sample = record.PendingSample
		local error = Vector3.zero
		if
			active
			and sample
			and record.Owners.Cartoon
			and SimulationConfig.ClientPresentation.CartoonCorrectionSmoothing
		then
			target = Motion.Frame(sample, now, frozen)
			local previous = record.Sample
			if previous and previous ~= sample then
				if Motion.Discontinuous(previous, sample) then
					Smoothing.Reset(record.Correction)
				else
					error = Motion.Frame(previous, now, frozen).Position - target.Position
				end
			end
		elseif record.Sample and not active then
			-- Preserve the displayed endpoint while ordinary physics takes ownership again.
			Smoothing.Rebase(record.Correction, CFrame.new(record.Root.Position - target.Position))
		end
		record.Sample = if active then sample else nil
		if not SimulationConfig.ClientPresentation.CartoonCorrectionSmoothing then
			Smoothing.Reset(record.Correction)
		elseif
			error.Magnitude > Config.CorrectionSnapDistance
			or record.Correction.Value.Position.Magnitude > Config.CorrectionSnapDistance
			or frozen
		then
			Diagnostics.Add(DiagnosticState, "Snaps")
			Smoothing.Reset(record.Correction)
		elseif error.Magnitude > 0 then
			-- Retain every correction in the visual offset; classify the accumulated error, not the packet size.
			local offset = record.Correction.Value.Position + error
			if offset.Magnitude > Config.CorrectionSnapDistance then
				Smoothing.Reset(record.Correction)
			else
				if
					not record.Correction.PositionActive
					and offset.Magnitude >= SimulationConfig.ClientPresentation.CorrectionDeadzone.PositionStart
				then
					Diagnostics.Add(DiagnosticState, "SmoothingStarts")
				end
				Diagnostics.Add(DiagnosticState, "Corrections")
				Smoothing.Rebase(record.Correction, CFrame.new(offset))
			end
		end
		Smoothing.Step(
			record.Correction,
			Config.CorrectionSmoothTime,
			dt,
			SimulationConfig.ClientPresentation.CorrectionDeadzone
		)
		local presentation = record.Presentation
		if presentation and presentation.Root and not record.Owners.Cartoon then
			target = presentation.Root
			Smoothing.Reset(record.Correction)
		end
		record.Root.CFrame = target + record.Correction.Value.Position
		local function scaleFor(weapon: boolean): number?
			if not presentation or (presentation.BodyScale == nil and presentation.WeaponScale == nil) then
				return nil
			end
			local body = presentation.BodyScale or (Attributes.Get(root, "SABodyScale") :: number?) or 1
			if not weapon then
				return body
			end
			local size = presentation.WeaponScale or (Attributes.Get(root, "SAWeaponScale") :: number?) or 1
			return size * (if Attributes.Get(root, "SAScaleWeapon") == true then body else 1)
		end
		for name, value in actor:GetAttributes() do
			if string.sub(name, 1, 2) ~= "SA" and string.sub(name, 1, 2) ~= "KB" then
				record.Model:SetAttribute(name, value)
			end
		end
		ReplicatedValues.CopyToVisual(actor, record.Model)
		for _, pair in record.Parts do
			if pair.Original.Parent and pair.Visual.Parent then
				pair.Original.LocalTransparencyModifier = 1
				pair.Visual.Transparency, pair.Visual.Color, pair.Visual.Size =
					pair.Original.Transparency, pair.Original.Color, pair.Original.Size
				local scale = scaleFor(pair.Weapon)
				if scale then
					pair.Visual.Size = pair.Size * scale
				end
				if pair.Visual == record.Root and record.Deformation then
					pair.Visual.Size *= record.Deformation.Value
				end
			end
		end
		for _, pair in record.Decals do
			if pair.Original.Parent and pair.Visual.Parent then
				pair.Visual.Transparency = pair.Original.Transparency
				pair.Visual.LocalTransparencyModifier = pair.Original.LocalTransparencyModifier
			end
		end
		for _, pair in record.Meshes do
			if pair.Original.Parent and pair.Visual.Parent then
				local scale = scaleFor(pair.Weapon)
				pair.Visual.Scale, pair.Visual.Offset =
					if scale then pair.Scale * scale else pair.Original.Scale,
					if scale then pair.Offset * scale else pair.Original.Offset
			end
		end
		for _, pair in record.AttachmentPairs do
			if pair.Original.Parent and pair.Visual.Parent then
				local scale = scaleFor(pair.Weapon)
				pair.Visual.CFrame = if scale
					then CFrame.new(pair.Frame.Position * scale) * pair.Frame.Rotation
					else pair.Original.CFrame
			end
		end
		-- Fixed weapon welds also change during scale timelines; cloned offsets are not a baseline.
		for _, pair in record.Links do
			local original, visual = pair.Original, pair.Visual
			if original:IsA("JointInstance") and not original:IsA("Motor6D") and visual:IsA("JointInstance") then
				local part0, part1 = original.Part0, original.Part1
				local scale0 = scaleFor(part0 ~= nil and part0:FindFirstAncestor("EquippedWeapon") ~= nil)
				local scale1 = scaleFor(part1 ~= nil and part1:FindFirstAncestor("EquippedWeapon") ~= nil)
				local c0, c1 =
					original:GetAttribute("SABaseC0") :: CFrame?, original:GetAttribute("SABaseC1") :: CFrame?
				visual.C0 = if c0 and scale0 then CFrame.new(c0.Position * scale0) * c0.Rotation else original.C0
				visual.C1 = if c1 and scale1 then CFrame.new(c1.Position * scale1) * c1.Rotation else original.C1
			end
		end
		local cartoon = record.Owners.Cartoon == true
		local recovering = cartoon and not active
		if recovering and not record.RecoveryAt then
			record.RecoveryAt = os.clock()
			for _, pair in record.Joints do
				record.RecoveryPoses[pair.Visual] = pair.Visual.Transform
			end
		end
		for _, pair in record.Joints do
			if pair.Original.Parent and pair.Visual.Parent then
				local part0, part1 = pair.Original.Part0, pair.Original.Part1
				local scale0 = scaleFor(part0 ~= nil and part0:FindFirstAncestor("EquippedWeapon") ~= nil)
				local scale1 = scaleFor(part1 ~= nil and part1:FindFirstAncestor("EquippedWeapon") ~= nil)
				pair.Visual.C0, pair.Visual.C1 =
					if scale0 then CFrame.new(pair.C0.Position * scale0) * pair.C0.Rotation else pair.Original.C0,
					if scale1 then CFrame.new(pair.C1.Position * scale1) * pair.C1.Rotation else pair.Original.C1
				local pose = record.RecoveryPoses[pair.Visual]
				if not cartoon then
					pair.Visual.Transform = pair.Original.Transform
				elseif recovering and record.RecoveryAt and pose then
					local alpha = if Config.RestToNormalFadeTime > 0
						then math.clamp((os.clock() - record.RecoveryAt) / Config.RestToNormalFadeTime, 0, 1)
						else 1
					pair.Visual.Transform = pose:Lerp(pair.Original.Transform, alpha)
				end
			end
		end
		if not cartoon then
			for _, pair in record.AnimationLinks do
				pair.Visual.Transform = pair.Original.Transform
			end
		end
	end
end

function VisualRig.Init()
	if Initialized then
		return
	end
	Initialized = true
	RunService:BindToRenderStep("CombatCartoonPresentation", Enum.RenderPriority.Camera.Value - 1, VisualRig.Render)
	-- Only final post-simulation samples reach rendering, never intermediate replay frames.
	RunService.PostSimulation:Connect(function()
		for _, record in Records do
			if
				record.SourceRoot.Parent
				and record.Owners.Cartoon
				and SimulationConfig.ClientPresentation.CartoonCorrectionSmoothing
			then
				record.PendingSample = Motion.Capture(record.SourceRoot, record.PendingSample)
			else
				record.PendingSample = nil
			end
		end
	end)
	RunService.PreSimulation:Connect(function()
		for _, record in Records do
			-- Humanoid initialization can restore torso collision after the clone is parented.
			-- Reassert isolation before physics, including parts added by appearance updates.
			IsolateParts(record)
			if not record.Owners.Cartoon then
				for _, pair in record.Joints do
					pair.Visual.Transform = pair.Original.Transform
				end
				for _, pair in record.AnimationLinks do
					pair.Visual.Transform = pair.Original.Transform
				end
			end
		end
	end)
end

function VisualRig.GetDiagnostics()
	local count = 0
	for _ in Records do
		count += 1
	end
	Diagnostics.Set(DiagnosticState, "ActiveVisuals", count)
	return Diagnostics.Read(DiagnosticState)
end
return VisualRig
