--!strict
-- Builds a local collidable Moon surface from server-authored geometry and shrinks it on the shared timeline.

--// Services
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Constants
local SOURCE_TAG = "MoonShrinkSource"

--// Types
type State = {
	Copy: Model,
	Parts: { [BasePart]: boolean },
	StartedAt: number,
	Duration: number,
	Minimum: number,
	Revision: number,
	Connection: RBXScriptConnection?,
	Dirty: boolean,
}
export type ShrinkVisual = {
	Setup: (self: ShrinkVisual) -> (),
	Start: (self: ShrinkVisual) -> (),
	Init: () -> (),
}

--// Properties
local Initialized = false
local States: { [Model]: State } = {}
local NextAttempt: { [Instance]: number } = {}

--// Controller
local ShrinkVisual = {} :: ShrinkVisual

local function Remove(source: Model)
	local state = States[source]
	if not state then return end
	States[source] = nil
	if state.Connection then state.Connection:Disconnect() end
	state.Copy:Destroy()
	for part, collide in state.Parts do
		if part.Parent then part.CanCollide = collide end
	end
end

local function Attach(source: Model): State?
	local pivot = source:GetAttribute("ShrinkPivot")
	local startedAt = source:GetAttribute("ShrinkStartedAt")
	local duration = source:GetAttribute("ShrinkDuration")
	local minimum = source:GetAttribute("ShrinkMinimum")
	local revision = source:GetAttribute("ShrinkRevision")
	if typeof(pivot) ~= "CFrame" or type(startedAt) ~= "number"
		or type(duration) ~= "number" or duration <= 0
		or type(minimum) ~= "number" or minimum <= 0
		or type(revision) ~= "number" then return nil end
	-- Wait for a complete replicated baseline, including on stream-in.
	for _, part in source:GetDescendants() do
		if part:IsA("BasePart") and (typeof(part:GetAttribute("ShrinkSize")) ~= "Vector3"
			or typeof(part:GetAttribute("ShrinkFrame")) ~= "CFrame"
			or type(part:GetAttribute("ShrinkTransparency")) ~= "number"
			or type(part:GetAttribute("ShrinkCollide")) ~= "boolean") then return nil end
	end
	local archivable = source.Archivable
	source.Archivable = true
	local cloned = source:Clone()
	source.Archivable = archivable
	if not cloned then return nil end
	-- A fresh root avoids inherited ScaleTo caches and works when joining after server resizing.
	local copy = Instance.new("Model")
	copy.Name = "MoonShrinkVisual"
	for _, child in cloned:GetChildren() do child.Parent = copy end
	cloned:Destroy()
	for _, item in copy:GetDescendants() do
		for _, tag in CollectionService:GetTags(item) do CollectionService:RemoveTag(item, tag) end
		if item:IsA("LuaSourceContainer") or item:IsA("Sound") or item:IsA("Constraint")
			or item:IsA("JointInstance") or item:IsA("BodyMover")
			or item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail")
			or item:IsA("ClickDetector") or item:IsA("ProximityPrompt") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Size = item:GetAttribute("ShrinkSize") :: Vector3
			item.CFrame = pivot * (item:GetAttribute("ShrinkFrame") :: CFrame)
			item.Transparency = item:GetAttribute("ShrinkTransparency") :: number
			item.LocalTransparencyModifier = 0
			item.Anchored = true
			item.CanCollide = item:GetAttribute("ShrinkCollide") == true
			item.CanTouch = false
			item.CanQuery = true
		elseif item:IsA("SpecialMesh") then
			local scale, offset = item:GetAttribute("ShrinkMeshScale"), item:GetAttribute("ShrinkMeshOffset")
			if typeof(scale) == "Vector3" then item.Scale = scale end
			if typeof(offset) == "Vector3" then item.Offset = offset end
		end
	end
	-- The fresh root uses the server's authored pivot without a PrimaryPart override.
	copy.WorldPivot = pivot
	local state: State = {
		Copy = copy, Parts = {}, StartedAt = startedAt, Duration = duration,
		Minimum = minimum, Revision = revision, Connection = nil, Dirty = false,
	}
	state.Connection = source.DescendantAdded:Connect(function() state.Dirty = true end)
	for _, part in source:GetDescendants() do
		if part:IsA("BasePart") then
			state.Parts[part] = part:GetAttribute("ShrinkCollide") == true
			part.CanCollide = false -- Only on this client; server ragdoll queries retain the original floor.
		end
	end
	local progress = math.clamp((Workspace:GetServerTimeNow() - startedAt) / duration, 0, 1)
	copy:ScaleTo(1 + (minimum - 1) * progress)
	copy.Parent = Workspace
	States[source] = state
	return state
end

--// APIs
function ShrinkVisual:Setup()
	CollectionService:GetInstanceRemovedSignal(SOURCE_TAG):Connect(function(instance: Instance)
		NextAttempt[instance] = nil
		if instance:IsA("Model") then Remove(instance) end
	end)
end

function ShrinkVisual:Start()
	RunService.PreSimulation:Connect(function()
		local now = Workspace:GetServerTimeNow()
		for source, state in States do
			if not source:IsDescendantOf(Workspace) or source:GetAttribute("ShrinkActive") ~= true
				or source:GetAttribute("ShrinkRevision") ~= state.Revision then Remove(source) end
		end
		for _, source in CollectionService:GetTagged(SOURCE_TAG) do
			if not source:IsA("Model") or not source:IsDescendantOf(Workspace)
				or source:GetAttribute("ShrinkActive") ~= true then continue end
			local state = States[source]
			if not state and now >= (NextAttempt[source] or 0) then
				NextAttempt[source] = now + 0.25
				state = Attach(source)
			end
			if state then
				local progress = math.clamp((now - state.StartedAt) / state.Duration, 0, 1)
				if progress >= 1 then
					state.Copy.Parent = nil
				else
					state.Copy:ScaleTo(1 + (state.Minimum - 1) * progress)
				end
				if state.Dirty then
					Remove(source)
					NextAttempt[source] = nil
				end
			end
		end
	end)
end

function ShrinkVisual.Init()
	if Initialized then return end
	Initialized = true
	ShrinkVisual:Setup()
	ShrinkVisual:Start()
end

return ShrinkVisual
