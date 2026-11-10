local ArenaFallingService = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local ArenaPlatformOrder = require(script.Parent.Helper.ArenaPlatformOrder)
local ArenaSimulation = require(ReplicatedStorage.Simulation.Arena)
local FallingEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("FallingEvent")
local config = GameConfig.ArenaFalling
local clientVisuals = config.ClientVisuals == true
local initialized, running, revision = false, false, 0
-- Original part settings restored when a falling-platform sequence stops.
type SavedPart = {
	anchored: boolean, -- Original Anchored value.
	collide: boolean, -- Original CanCollide value.
	query: boolean, -- Original CanQuery value.
	touch: boolean, -- Original CanTouch value.
}
-- Server lifecycle and saved geometry settings for one falling platform.
type State = {
	origin: CFrame, -- Platform pivot before the warning animation.
	fallOrigin: CFrame, -- Pivot at the end of Warning, used as the start of the drop.
	revision: number, -- Arena sequence number that invalidates work from an earlier run.
	phase: string, -- Current Warning, Fall, or Stop phase.
	startedAt: number, -- Server timestamp in seconds when the current phase began.
	clientVisuals: boolean, -- True moves a client-only copy; false moves server geometry.
	parts: { [BasePart]: SavedPart }, -- Original settings of each platform part, keyed by the part instance.
	connection: RBXScriptConnection?, -- DescendantAdded listener that prepares parts added during the sequence.
	destroying: RBXScriptConnection?, -- Destroying listener that releases this platform's state.
}
local active: { [Model]: State } = {}

local function valid(token, model)
	return running and token == revision and model and model:IsDescendantOf(workspace)
end

local function setPhase(model: Model, state: State, phase: string)
	state.phase, state.startedAt = phase, time()
	if phase == "Warning" then
		ArenaSimulation.Publish(
			model,
			{
				FallingClientVisuals = state.clientVisuals,
				FallingOrigin = state.origin,
				FallingRevision = state.revision,
				FallingStartedAt = state.startedAt,
				FallingPhase = phase,
				SAFallStart = state.startedAt,
				SADisableAt = state.startedAt + config.WarningDuration,
			}
		)
	end
	FallingEvent:FireAllClients(phase, model, state.revision, state.startedAt, state.clientVisuals, state.origin)
end

local function preparePart(state: State, item: Instance)
	if not item:IsA("BasePart") or state.parts[item] then
		return
	end
	state.parts[item] = {
		anchored = item.Anchored,
		collide = item.CanCollide,
		query = item.CanQuery,
		touch = item.CanTouch,
	}
	item.Anchored = true
	if state.clientVisuals and state.phase == "Fall" then
		item.CanCollide, item.CanTouch, item.CanQuery = false, false, false
	end
end

local function disconnect(state: State)
	if state.destroying then
		state.destroying:Disconnect()
		state.destroying = nil
	end
	if state.connection then
		state.connection:Disconnect()
		state.connection = nil
	end
end

local function dropModel(model: Model, token: number)
	if not valid(token, model) then
		return
	end
	local origin = model:GetPivot()
	local state: State = {
		origin = origin,
		fallOrigin = origin,
		revision = token,
		phase = "Warning",
		startedAt = 0,
		clientVisuals = clientVisuals,
		parts = {},
		connection = nil,
		destroying = nil,
	}
	active[model] = state
	for _, item in model:GetDescendants() do
		preparePart(state, item)
	end
	state.connection = model.DescendantAdded:Connect(function(item)
		preparePart(state, item)
	end)
	state.destroying = model.Destroying:Connect(function()
		if active[model] == state then
			active[model] = nil
		end
		disconnect(state)
	end)
	setPhase(model, state, "Warning")
	CollectionService:AddTag(model, "CombatFallingPlatform")
	task.wait(config.WarningDuration)
	if not valid(token, model) or active[model] ~= state then
		return
	end

	setPhase(model, state, "Fall")
	task.wait(config.DropDuration + 0.5)
	if valid(token, model) and active[model] == state then
		active[model] = nil
		disconnect(state)
		model:Destroy()
	end
end

local function destructionRoutine(token)
	task.wait(config.InitialDelay)
	if not running or token ~= revision then
		return
	end
	local arena = CollectionService:GetTagged("DestroyableArena")[1]
	if not arena then
		return
	end
	local container = arena:FindFirstChild("Main", true) or arena:FindFirstChild("Platforms")
	if not container then
		return
	end
	local platforms = {}
	for _, child in container:GetChildren() do
		if child:IsA("Model") then
			table.insert(platforms, child)
		end
	end
	for i = #platforms, 2, -1 do
		local j = math.random(i)
		platforms[i], platforms[j] = platforms[j], platforms[i]
	end
	platforms = ArenaPlatformOrder.SpawnLast(arena, platforms)
	for i, platform in platforms do
		if not valid(token, platform) then
			return
		end
		if i == #platforms then
			task.wait(config.IntervalLastPlatform)
		end
		if not valid(token, platform) then
			return
		end
		dropModel(platform, token)
		if i ~= #platforms then
			task.wait(config.IntervalBetweenPlatforms)
		end
	end
end

function ArenaFallingService.Start()
	ArenaFallingService.Stop()
	running = true
	local token = revision
	task.spawn(destructionRoutine, token)
end

function ArenaFallingService.Stop()
	running = false
	revision += 1
	for model, state in active do
		disconnect(state)
		if model.Parent then
			ArenaSimulation.Clear(model)
			model:SetAttribute("FallingPhase", "Stop")
			for part, saved in state.parts do
				if part.Parent then
					part.CanCollide, part.CanQuery, part.CanTouch = saved.collide, saved.query, saved.touch
					part.Anchored = saved.anchored
				end
			end
			state.revision = revision
			setPhase(model, state, "Stop")
			CollectionService:RemoveTag(model, "CombatFallingPlatform")
		end
	end
	table.clear(active)
end

function ArenaFallingService.Init()
	if initialized then
		return
	end
	initialized = true
	-- Shared simulation owns both physical modes and their collision deadlines.
end

return ArenaFallingService
