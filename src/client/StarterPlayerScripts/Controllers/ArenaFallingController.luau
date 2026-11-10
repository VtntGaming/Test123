--!strict
-- Owns one decorative copy per arena part, composing shrink and fall timelines every frame.
-- Nested shrinking arenas and falling platforms share copies; originals retain all gameplay collisions.

--// Services
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Modules
local Timelines = require(ReplicatedStorage.Simulation.Timelines)
local Config = require(ReplicatedStorage.Config.Simulation)
local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)
local Clock = require(script.Parent.SimulationPresentationController.Clock)

--// References
local FallingEvent = ReplicatedStorage.Events.FallingEvent
local Falling = GameConfig.ArenaFalling

--// Types
type Effect = ParticleEmitter | Trail | Beam | Light | SurfaceGui | BillboardGui
type Mesh = { Original: SpecialMesh, Visual: SpecialMesh, Scale: Vector3, Offset: Vector3 }
type Part = {
	Source: BasePart,
	Visual: BasePart?,
	Transparency: number,
	Members: { [Model]: boolean },
	Effects: { [Effect]: boolean },
	Meshes: { Mesh },
	Dirty: boolean,
}
type Record = { Model: Model, Parts: { [BasePart]: boolean }, Connections: { RBXScriptConnection }, Dirty: boolean }
export type Controller = { Init: () -> (), Setup: (Controller) -> (), Start: (Controller) -> () }

--// Properties
local Records: { [Model]: Record } = {}
local Parts: { [BasePart]: Part } = {}
local Folder: Folder?
local Initialized = false

--// Controller
local Controller: Controller = {} :: Controller

local function SetEnabled(effect: Effect, enabled: boolean)
	if effect:IsA("ParticleEmitter") then
		effect.Enabled = enabled
	elseif effect:IsA("Trail") then
		effect.Enabled = enabled
	elseif effect:IsA("Beam") then
		effect.Enabled = enabled
	elseif effect:IsA("Light") then
		effect.Enabled = enabled
	elseif effect:IsA("SurfaceGui") then
		effect.Enabled = enabled
	elseif effect:IsA("BillboardGui") then
		effect.Enabled = enabled
	end
end

local function ClearVisual(part: Part)
	if not part.Visual then
		return
	end
	part.Visual:Destroy()
	part.Visual = nil
	if part.Source.Parent and part.Source.LocalTransparencyModifier == 1 then
		part.Source.LocalTransparencyModifier = part.Transparency
	end
	for effect, enabled in part.Effects do
		if effect.Parent then
			SetEnabled(effect, enabled)
		end
	end
	table.clear(part.Effects)
	table.clear(part.Meshes)
end

local function Detach(model: Model)
	local record = Records[model]
	if not record then
		return
	end
	Records[model] = nil
	for _, connection in record.Connections do
		connection:Disconnect()
	end
	for source in record.Parts do
		local part = Parts[source]
		if part then
			part.Members[model] = nil
			if not next(part.Members) then
				ClearVisual(part)
				Parts[source] = nil
			end
		end
	end
end

local function Refresh(record: Record)
	local current: { [BasePart]: boolean } = {}
	for _, item in record.Model:GetDescendants() do
		if item:IsA("BasePart") then
			current[item] = true
			local part = Parts[item]
			if not part then
				part = {
					Source = item,
					Visual = nil,
					Transparency = item.LocalTransparencyModifier,
					Members = {},
					Effects = {},
					Meshes = {},
					Dirty = false,
				}
				Parts[item] = part
			end
			part.Members[record.Model] = true
		end
	end
	for source in record.Parts do
		if not current[source] then
			local part = Parts[source]
			if part then
				part.Members[record.Model] = nil
				if not next(part.Members) then
					ClearVisual(part)
					Parts[source] = nil
				end
			end
		end
	end
	record.Parts, record.Dirty = current, false
end

local function Observe(instance: Instance)
	if not instance:IsA("Model") or not instance:IsDescendantOf(Workspace) then
		return
	end
	if Records[instance] then
		return
	end
	local record: Record = { Model = instance, Parts = {}, Connections = {}, Dirty = true }
	Records[instance] = record
	local function changed(item: Instance)
		if item:IsA("BasePart") then
			record.Dirty = true
		elseif item:IsA("Decal") or item:IsA("DataModelMesh") or item:IsA("SurfaceAppearance") then
			local source = item:FindFirstAncestorWhichIsA("BasePart")
			local part = if source then Parts[source] else nil
			if part then
				part.Dirty = true
			end
		end
	end
	record.Connections = {
		instance.DescendantAdded:Connect(changed),
		instance.DescendantRemoving:Connect(changed),
		instance.AncestryChanged:Connect(function()
			if not instance:IsDescendantOf(Workspace) then
				Detach(instance)
			end
		end),
	}
	Refresh(record)
end

local function Removed(instance: Instance)
	if
		instance:IsA("Model")
		and not CollectionService:HasTag(instance, "SAArena")
		and not CollectionService:HasTag(instance, "CombatFallingPlatform")
	then
		Detach(instance)
	end
end

local function CreateVisual(part: Part): BasePart?
	ClearVisual(part)
	local source = part.Source
	part.Transparency = source.LocalTransparencyModifier
	local archivable = source.Archivable
	source.Archivable = true
	local visual = source:Clone()
	source.Archivable = archivable
	if not visual then
		return nil
	end
	local descendants = visual:GetDescendants()
	table.insert(descendants, 1, visual)
	for _, item in descendants do
		for _, tag in CollectionService:GetTags(item) do
			CollectionService:RemoveTag(item, tag)
		end
		if
			item:IsA("LuaSourceContainer")
			or item:IsA("Constraint")
			or item:IsA("JointInstance")
			or item:IsA("BodyMover")
			or item:IsA("Sound")
			or item:IsA("ClickDetector")
			or item:IsA("ProximityPrompt")
			or item:IsA("BasePart") and item ~= visual
		then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored, item.CanCollide, item.CanTouch, item.CanQuery, item.Massless =
				true, false, false, false, true
		end
	end
	if not Folder then
		local folder = Instance.new("Folder")
		folder.Name, folder.Parent = "LocalFallingPlatformVisuals", Workspace
		Folder = folder
	end
	visual.Name = source.Name .. "_ArenaVisual"
	visual.Parent = Folder
	RunService:SetPredictionMode(visual, Enum.PredictionMode.Off)
	local originals, copies = source:GetDescendants(), visual:GetDescendants()
	local originalMeshes: { SpecialMesh } = {}
	for _, item in originals do
		if item:IsA("SpecialMesh") and item:FindFirstAncestorWhichIsA("BasePart") == source then
			table.insert(originalMeshes, item)
		end
	end
	local index = 0
	for _, item in copies do
		if item:IsA("SpecialMesh") then
			index += 1
			local original = originalMeshes[index]
			if original then
				table.insert(part.Meshes, {
					Original = original,
					Visual = item,
					Scale = (original:GetAttribute("SABaseMeshScale") :: Vector3?) or original.Scale,
					Offset = (original:GetAttribute("SABaseMeshOffset") :: Vector3?) or original.Offset,
				})
			end
		end
	end
	for _, item in originals do
		if
			item:FindFirstAncestorWhichIsA("BasePart") == source
			and (
				item:IsA("ParticleEmitter")
				or item:IsA("Trail")
				or item:IsA("Beam")
				or item:IsA("Light")
				or item:IsA("SurfaceGui")
				or item:IsA("BillboardGui")
			)
		then
			part.Effects[item] = item.Enabled
			SetEnabled(item, false)
		end
	end
	part.Visual, part.Dirty = visual, false
	return visual
end

local function Render()
	local now = Clock.Now()
	for model, record in Records do
		if not model:IsDescendantOf(Workspace) then
			Detach(model)
		elseif record.Dirty then
			Refresh(record)
		end
	end
	for source, part in Parts do
		local shrink: Model? = nil
		local falling: Model? = nil
		-- Cached membership gives each source part exactly one visual owner.
		for model in part.Members do
			if
				model:GetAttribute("SAShrinkStart")
				and model:GetAttribute("SAShrinkDuration") ~= nil
				and model:GetAttribute("SAShrinkMinimum") ~= nil
				and Config.ClientPresentation.ArenaVisuals
			then
				if not shrink or model:IsDescendantOf(shrink) then
					shrink = model
				end
			end
			local phase = model:GetAttribute("FallingPhase")
			if
				(phase == "Warning" or phase == "Fall")
				and typeof(model:GetAttribute("FallingStartedAt")) == "number"
				and typeof(model:GetAttribute("FallingOrigin")) == "CFrame"
				and (Config.ClientPresentation.ArenaVisuals or model:GetAttribute("FallingClientVisuals") == true)
			then
				if not falling or model:IsDescendantOf(falling) then
					falling = model
				end
			end
		end
		local scale = 1
		local shrinking = false
		if shrink then
			local at = shrink:GetAttribute("SAShrinkStart") :: number
			local duration = shrink:GetAttribute("SAShrinkDuration") :: number
			scale = Timelines.ArenaScale(now, at, duration, shrink:GetAttribute("SAShrinkMinimum") :: number)
			local base = source:GetAttribute("SABaseSize") :: Vector3?
			shrinking = now < at + duration or (base ~= nil and (source.Size - base * scale).Magnitude > 0.0001)
		end
		if not shrinking and not falling then
			ClearVisual(part)
			continue
		end
		local visual = part.Visual
		if not visual or part.Dirty then
			visual = CreateVisual(part)
		end
		if not visual then
			continue
		end
		local owner = shrink or falling
		local pivot = if owner then owner:GetAttribute("SAPivot") :: CFrame? else nil
		local relative = source:GetAttribute("SABaseFrame") :: CFrame?
		local frame = if pivot and relative
			then pivot * CFrame.new(relative.Position * scale) * relative.Rotation
			else source.CFrame
		local baseSize = source:GetAttribute("SABaseSize") :: Vector3?
		visual.Size = if baseSize then baseSize * scale else source.Size
		visual.Color, visual.Transparency = source.Color, source.Transparency
		visual.LocalTransparencyModifier = part.Transparency
		if falling then
			local started = falling:GetAttribute("SAFallStart") :: number?
			local phase = falling:GetAttribute("FallingPhase")
			local phaseAt = falling:GetAttribute("FallingStartedAt") :: number
			local elapsed = if started
				then now - started
				else now - phaseAt + (if phase == "Fall" then Falling.WarningDuration else 0)
			local origin = falling:GetAttribute("FallingOrigin") :: CFrame
			frame += Timelines.Fall(origin, elapsed, Falling).Position - origin.Position
			if elapsed < Falling.WarningDuration then
				if source.Name == "Neon" then
					visual.Color = source.Color:Lerp(Color3.fromRGB(255, 0, 0), (math.sin(elapsed * 12) + 1) * 0.5)
				end
			else
				local fade = Timelines.Progress(
					elapsed - Falling.WarningDuration,
					Falling.FadeDelay,
					Falling.DropDuration - Falling.FadeDelay
				)
				visual.LocalTransparencyModifier = part.Transparency + (1 - part.Transparency) * fade
			end
		end
		visual.CFrame = frame
		for _, mesh in part.Meshes do
			mesh.Visual.Scale, mesh.Visual.Offset = mesh.Scale * scale, mesh.Offset * scale
		end
		source.LocalTransparencyModifier = 1
	end
end

--// APIs
function Controller:Setup() end

function Controller:Start()
	for _, tag in { "SAArena", "CombatFallingPlatform" } do
		CollectionService:GetInstanceAddedSignal(tag):Connect(Observe)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(Removed)
		for _, model in CollectionService:GetTagged(tag) do
			Observe(model)
		end
	end
	FallingEvent.OnClientEvent:Connect(function(action: unknown, model: unknown)
		if typeof(model) == "Instance" then
			Observe(model)
		end
	end)
	RunService:BindToRenderStep("ArenaTimelinePresentation", Enum.RenderPriority.Camera.Value - 3, Render)
end

function Controller.Init()
	if Initialized then
		return
	end
	Initialized = true
	Controller:Setup()
	Controller:Start()
end

return Controller
