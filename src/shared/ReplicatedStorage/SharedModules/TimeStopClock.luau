--!strict
-- Stores confirmed pause intervals on separate predicted carriers for arena and training gameplay.
-- Remote presentation notifications never mutate a client's independent interval history.

--// Services
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// References
local IsServer = RunService:IsServer()

--// Constants
local CAPACITY = 20

--// Types
type Command = { Kind: string, At: number, Scope: string }
export type Clock = {
	-- Observes or creates one persistent, initialized carrier per gameplay scope.
	Init: () -> (),
	-- Applies server pause commands inside the shared simulation callback.
	Step: () -> (),
	-- Begins a confirmed pause in the supplied scope; omitted scope means Arena.
	Begin: (number, string?) -> (),
	-- Ends a confirmed pause in the supplied scope; omitted scope means Arena.
	End: (number, string?) -> (),
	-- Clears pause history in both scopes.
	Reset: () -> (),
	-- Reports whether the supplied scope is paused; omitted scope means Arena.
	IsStopped: (string?) -> boolean,
	-- Returns the current pause start in seconds, or nil when not paused.
	StoppedSince: (string?) -> number?,
	-- Returns paused seconds overlapping [a, b] in the supplied scope.
	Paused: (number, number, string?) -> number,
}

--// Properties
local Carriers: { [string]: BasePart? } = {}
local Pending: { Command } = {}
local Initialized = false

--// Controller
local Clock: Clock = {} :: Clock

local function Observe(instance: Instance)
	if instance.Name ~= "AuthorityTimeline" or not instance:IsA("Model") then
		return
	end
	local function attach(child: Instance)
		if (child.Name == "Arena" or child.Name == "Training") and child:IsA("BasePart") then
			Carriers[child.Name] = child
			if not IsServer then
				RunService:SetPredictionMode(child, Enum.PredictionMode.On)
			end
		end
	end
	instance.ChildAdded:Connect(attach)
	for _, child in instance:GetChildren() do
		attach(child)
	end
end

--// APIs
function Clock.Init()
	if Initialized then
		return
	end
	Initialized = true
	Workspace.ChildAdded:Connect(Observe)
	if IsServer then
		local model = Instance.new("Model")
		model.Name, model.ModelStreamingMode = "AuthorityTimeline", Enum.ModelStreamingMode.Persistent
		for _, scope in { "Arena", "Training" } do
			local part = Instance.new("Part")
			part.Name, part.Anchored, part.Transparency = scope, true, 1
			part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
			part.Size, part.Position = Vector3.one, Vector3.zero
			part:SetAttribute("Index", 0)
			part:SetAttribute("Stopped", false)
			part:SetAttribute("Session", 0)
			part.Parent = model
		end
		model.Parent = Workspace
	end
	for _, child in Workspace:GetChildren() do
		Observe(child)
	end
end

function Clock.Begin(at, scope)
	if IsServer then
		table.insert(Pending, { Kind = "Begin", At = at, Scope = scope or "Arena" })
	end
end
function Clock.End(at, scope)
	if IsServer then
		table.insert(Pending, { Kind = "End", At = at, Scope = scope or "Arena" })
	end
end
function Clock.Reset()
	if IsServer then
		for _, scope in { "Arena", "Training" } do
			table.insert(Pending, { Kind = "Reset", At = time(), Scope = scope })
		end
	end
end
function Clock.Step()
	if not IsServer then
		return
	end
	local pending = Pending
	Pending = {}
	for _, command in pending do
		local carrier = Carriers[command.Scope]
		if not carrier then
			continue
		end
		local index = (carrier:GetAttribute("Index") :: number?) or 0
		if command.Kind == "Reset" then
			carrier:SetAttribute("Session", ((carrier:GetAttribute("Session") :: number?) or 0) + 1)
			carrier:SetAttribute("Index", 0)
			carrier:SetAttribute("Stopped", false)
			for i = 1, CAPACITY do
				carrier:SetAttribute("From" .. i, nil)
				carrier:SetAttribute("To" .. i, nil)
			end
		elseif command.Kind == "Begin" and carrier:GetAttribute("Stopped") ~= true then
			index = index % CAPACITY + 1
			carrier:SetAttribute("Index", index)
			carrier:SetAttribute("From" .. index, command.At)
			carrier:SetAttribute("To" .. index, nil)
			carrier:SetAttribute("Stopped", true)
		elseif command.Kind == "End" and carrier:GetAttribute("Stopped") == true then
			carrier:SetAttribute("To" .. index, command.At)
			carrier:SetAttribute("Stopped", false)
		end
	end
end
function Clock.IsStopped(scope)
	local carrier = Carriers[scope or "Arena"]
	return carrier ~= nil and carrier:GetAttribute("Stopped") == true
end
function Clock.StoppedSince(scope)
	local carrier = Carriers[scope or "Arena"]
	if carrier and Clock.IsStopped(scope) then
		return carrier:GetAttribute("From" .. tostring(carrier:GetAttribute("Index"))) :: number?
	end
	return nil
end
function Clock.Paused(a, b, scope)
	local carrier = Carriers[scope or "Arena"]
	if not carrier then
		return 0
	end
	local total = 0
	for i = 1, CAPACITY do
		local started = carrier:GetAttribute("From" .. i) :: number?
		if started then
			local ended = (carrier:GetAttribute("To" .. i) :: number?) or b
			total += math.max(0, math.min(ended, b) - math.max(started, a))
		end
	end
	return total
end
return Clock
