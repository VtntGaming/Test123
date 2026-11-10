--!strict
-- Advances shared arena dimensions, platform phases and collision deadlines before gameplay casts.

--// Services
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)
local Timelines = require(script.Parent.Timelines)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local Falling = GameConfig.ArenaFalling
local ClientArena = SimulationConfig.ClientSimulation.Arena

--// Types
type Part = { Instance: BasePart, Size: Vector3, Frame: CFrame }
type Fields = { [string]: boolean | number | string | Vector3 | CFrame }
type Record = { Model: Model, Parts: { Part }, Pivot: CFrame, Connections: { RBXScriptConnection } }
export type Arena = {
	-- Starts observing arena tags and removals once, and projects mesh scaling after simulation.
	Init: () -> (),
	-- Applies queued server fields, shrink and fall timelines, and collision deadlines at now in seconds; dt is the step interval.
	Step: (number, number) -> (),
	-- Queues a shrink timeline starting at started, lasting duration seconds, and ending at the minimum scale factor.
	RegisterScale: (Model, number, number, number) -> (),
	-- Queues a deadline in simulation seconds for disabling collision, queries, and touches on the arena parts.
	DisableAt: (Model, number) -> (),
	-- Prepares baseline geometry and queues model attributes for the next server simulation step.
	Publish: (Model, Fields) -> (),
	-- Stops tracking the model, disconnects its listeners, and restores automatic client prediction.
	Clear: (Model) -> (),
}

--// Properties
local Records: { [Model]: Record } = {}
local Pending: { { Model: Model, Fields: Fields } } = {}
local Initialized = false

--// Controller
local Arena: Arena = {} :: Arena

local function Refresh(record: Record)
	table.clear(record.Parts)
	record.Pivot = (record.Model:GetAttribute("SAPivot") :: CFrame?) or record.Model:GetPivot()
	for _, item in record.Model:GetDescendants() do
		if item:IsA("BasePart") then
			local size, frame = item:GetAttribute("SABaseSize"), item:GetAttribute("SABaseFrame")
			if typeof(size) == "Vector3" and typeof(frame) == "CFrame" then
				table.insert(record.Parts, { Instance = item, Size = size, Frame = frame })
				if not IsServer then
					RunService:SetPredictionMode(item, Enum.PredictionMode.On)
				end
			end
		end
	end
end
local function Observe(instance: Instance)
	if not instance:IsA("Model") or Records[instance] then
		return
	end
	local record: Record = { Model = instance, Parts = {}, Pivot = instance:GetPivot(), Connections = {} }
	Records[instance] = record
	local function refresh()
		if Records[instance] == record then
			Refresh(record)
		end
	end
	local function added(item: Instance)
		if item:IsA("BasePart") then
			table.insert(record.Connections, item:GetAttributeChangedSignal("SABaseSize"):Connect(refresh))
			table.insert(record.Connections, item:GetAttributeChangedSignal("SABaseFrame"):Connect(refresh))
		end
		task.defer(refresh)
	end
	record.Connections = {
		instance.DescendantAdded:Connect(added),
		instance.DescendantRemoving:Connect(function()
			task.defer(refresh)
		end),
		instance:GetAttributeChangedSignal("SAPivot"):Connect(refresh),
	}
	for _, child in instance:GetDescendants() do
		added(child)
	end
	Refresh(record)
	if not IsServer then
		RunService:SetPredictionMode(instance, Enum.PredictionMode.On)
	end
end
local function Prepare(model: Model)
	if not model:GetAttribute("SAPivot") then
		model:SetAttribute("SAPivot", model:GetPivot())
	end
	local pivot = model:GetAttribute("SAPivot") :: CFrame
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and not item:GetAttribute("SABaseSize") then
			item:SetAttribute("SABaseSize", item.Size)
			item:SetAttribute("SABaseFrame", pivot:ToObjectSpace(item.CFrame))
		elseif item:IsA("SpecialMesh") and not item:GetAttribute("SABaseMeshScale") then
			item:SetAttribute("SABaseMeshScale", item.Scale)
			item:SetAttribute("SABaseMeshOffset", item.Offset)
		end
	end
	CollectionService:AddTag(model, "SAArena")
	Observe(model)
	local record = Records[model]
	if record then
		Refresh(record)
	end
end
--// APIs
function Arena.Publish(model, fields)
	Prepare(model)
	table.insert(Pending, { Model = model, Fields = fields })
end
function Arena.RegisterScale(model, started, duration, minimum)
	Arena.Publish(model, { SAShrinkStart = started, SAShrinkDuration = duration, SAShrinkMinimum = minimum })
end
function Arena.DisableAt(model, deadline)
	Arena.Publish(model, { SADisableAt = deadline })
end
function Arena.Clear(model)
	CollectionService:RemoveTag(model, "SAArena")
	local record = Records[model]
	if record and not IsServer then
		for _, part in record.Parts do
			if part.Instance.Parent then
				RunService:SetPredictionMode(part.Instance, Enum.PredictionMode.Automatic)
			end
		end
		if model.Parent then
			RunService:SetPredictionMode(model, Enum.PredictionMode.Automatic)
		end
	end
	if record then
		for _, connection in record.Connections do
			connection:Disconnect()
		end
	end
	Records[model] = nil
end
function Arena.Step(dt, now)
	if IsServer then
		local pending = Pending
		Pending = {}
		for _, command in pending do
			if Records[command.Model] and command.Model.Parent then
				for name, value in command.Fields do
					command.Model:SetAttribute(name, value)
				end
			end
		end
	end
	local shrinking = IsServer or ClientArena.ShrinkingGeometry
	local falling = IsServer or ClientArena.FallingGeometry
	local collisionDeadlines = IsServer or ClientArena.CollisionDeadlines
	for model, record in Records do
		local started = model:GetAttribute("SAShrinkStart") :: number?
		local deadline = model:GetAttribute("SADisableAt") :: number?
		local scale = 1
		if shrinking and started then
			local duration = model:GetAttribute("SAShrinkDuration") :: number
			local minimum = model:GetAttribute("SAShrinkMinimum") :: number
			scale = Timelines.ArenaScale(now, started, duration, minimum)
		end
		local frame = record.Pivot
		local fallStart = model:GetAttribute("SAFallStart") :: number?
		if falling and fallStart then
			local elapsed = math.max(0, now - fallStart)
			local warning = elapsed < Falling.WarningDuration
			local phaseAt = if warning then fallStart else fallStart + Falling.WarningDuration
			local phase = if warning then "Warning" else "Fall"
			model:SetAttribute("FallingPhase", phase)
			model:SetAttribute("FallingStartedAt", phaseAt)
			if model:GetAttribute("FallingClientVisuals") ~= true then
				frame = Timelines.Fall(frame, elapsed, Falling)
			end
		end
		for _, part in record.Parts do
			if shrinking and started then
				part.Instance.Size = part.Size * scale
			end
			if
				(shrinking and started)
				or (falling and fallStart and model:GetAttribute("FallingClientVisuals") ~= true)
			then
				part.Instance.CFrame = frame * CFrame.new(part.Frame.Position * scale) * part.Frame.Rotation
			end
			if collisionDeadlines and deadline and now >= deadline then
				part.Instance.CanCollide, part.Instance.CanQuery, part.Instance.CanTouch = false, false, false
			end
		end
	end
end
function Arena.Init()
	if Initialized then
		return
	end
	Initialized = true
	CollectionService:GetInstanceAddedSignal("SAArena"):Connect(Observe)
	CollectionService:GetInstanceRemovedSignal("SAArena"):Connect(function(instance)
		if instance:IsA("Model") then
			Arena.Clear(instance)
		end
	end)
	for _, model in CollectionService:GetTagged("SAArena") do
		Observe(model)
	end
	Workspace.DescendantRemoving:Connect(function(instance)
		if instance:IsA("Model") then
			Arena.Clear(instance)
		end
	end)
	RunService.PostSimulation:Connect(function()
		if not IsServer and not ClientArena.ShrinkingGeometry then
			return
		end
		for model in Records do
			local scale = 1
			local started = model:GetAttribute("SAShrinkStart") :: number?
			if started then
				local duration = model:GetAttribute("SAShrinkDuration") :: number
				local minimum = model:GetAttribute("SAShrinkMinimum") :: number
				scale = Timelines.ArenaScale(time(), started, duration, minimum)
			end
			for _, item in model:GetDescendants() do
				if item:IsA("SpecialMesh") then
					local size, offset = item:GetAttribute("SABaseMeshScale"), item:GetAttribute("SABaseMeshOffset")
					if typeof(size) == "Vector3" then
						item.Scale = size * scale
					end
					if typeof(offset) == "Vector3" then
						item.Offset = offset * scale
					end
				end
			end
		end
	end)
end
return Arena
