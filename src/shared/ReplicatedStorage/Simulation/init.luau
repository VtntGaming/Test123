--!strict
-- Binds shared gameplay in one explicit order and drains server-only commits after simulation.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Modules
local Types = require(script.Types)
local Attributes = require(script.Attributes)
local Diagnostics = require(script.Diagnostics)
local State = require(script.State)
local Input = require(script.Input)
local Arena = require(script.Arena)
local ActorTimelines = require(script.ActorTimelines)
local Movement = require(script.Movement)
local Combat = require(script.Combat)
local Animations = require(script.Animations)
local KnockbackState = require(ReplicatedStorage.Knockback.State)
local Motion = require(ReplicatedStorage.Knockback.CartoonMotion)
local Config = require(ReplicatedStorage.Config.Simulation)
local Clock = require(ReplicatedStorage.SharedModules.TimeStopClock)

--// References
local IsServer = RunService:IsServer()

--// Constants
local TIMELINE_FREQUENCY = Enum.StepFrequency.Hz60
local ANIMATION_FREQUENCY = Enum.StepFrequency.Hz60

--// Types
export type Simulation = {
	-- Initializes shared dependencies and binds simulation callbacks once, calling Setup before Start.
	Init: () -> (),
	-- Initializes actor state, input, arenas, and the shared time-stop clock.
	Setup: (Simulation) -> (),
	-- Binds ordered gameplay and animation steps, then runs commits and listeners after simulation; call once through Init.
	Start: (Simulation) -> (),
	-- Queues a server-only callback after simulation, deduplicated by identity within the actor's current generation.
	Commit: (Types.Actor, string, () -> ()) -> (),
	-- Registers a callback receiving dt and now in seconds after simulation; lower priorities run first, and the return value unregisters it.
	AfterStep: (Types.Step, number?) -> () -> (),
	-- Returns a bounded local diagnostics snapshot; disabled by default and never replicated.
	GetDiagnostics: () -> Diagnostics.Snapshot,
}

--// Properties
local Initialized = false
local Commits: { Types.Commit } = {}
local Committed: { [Types.Actor]: { Generation: string, Identities: { [string]: boolean } } } = {}
type Listener = { Callback: Types.Step, Priority: number, Order: number }
local Listeners: { [Types.Step]: Listener } = {}
local ListenerOrder = 0
local StepTime = 0
local StepDelta = 0
local Stepped = false

local Validated = setmetatable({} :: { [Types.ActorRecord]: Humanoid | boolean }, { __mode = "k" })
--// Controller
local Simulation: Simulation = {} :: Simulation

function Simulation.GetDiagnostics()
	return Diagnostics.GetSnapshot()
end

--// APIs
function Simulation.Commit(actor, identity, apply)
	if not IsServer then
		return
	end
	table.insert(Commits, {
		Actor = actor,
		Generation = actor:GetAttribute("RagdollGeneration") :: string,
		Identity = identity,
		Apply = apply,
	})
end

function Simulation.AfterStep(callback, priority)
	ListenerOrder += 1
	Listeners[callback] = { Callback = callback, Priority = priority or 0, Order = ListenerOrder }
	return function()
		Listeners[callback] = nil
	end
end

function Simulation:Setup()
	State.Init()
	Input.Init()
	Arena.Init()
	Clock.Init()
end

function Simulation:Start()
	local function refreshFilter()
		State.Prepare()
		Animations.Prepare()
		for _, record in State.Records do
			if not record.Ready then
				Validated[record] = nil
				continue
			end
			if Validated[record] ~= (record.Humanoid or true) then
				State.ValidateLayout(record.Root)
				if record.Humanoid then
					State.ValidateLayout(record.Humanoid)
				end
				Validated[record] = record.Humanoid or true
			end
		end
		local excluded: { Instance } = {}
		for actor in State.Records do
			table.insert(excluded, actor)
		end
		for _, name in { "CombatLocalEffects", "CombatEffects", "ClientEffects" } do
			local folder = workspace:FindFirstChild(name)
			if folder then
				table.insert(excluded, folder)
			end
		end
		Motion.SetFilter(excluded)
	end
	RunService.PreSimulation:Connect(refreshFilter)
	-- Keep command ingestion at the gameplay rate, but apply it before both projection and gameplay.
	RunService:BindToSimulation(function()
		Clock.Step()
		if IsServer then
			State.Drain()
		end
	end, Config.Frequency, Config.Priority - 2)
	-- Known paths are sampled independently of the configurable input/combat rate.
	-- The values are analytical functions of time; no previous projection is integrated.
	RunService:BindToSimulation(function(dt: number)
		local now = time()
		ActorTimelines.Project(State.Records, now)
		Arena.Step(dt, now)
	end, TIMELINE_FREQUENCY, Config.Priority - 1)
	RunService:BindToSimulation(function(dt: number)
		local now = time()
		Combat.Step(dt, now)
		Movement.Step(dt, now)
		KnockbackState.Step(dt, now)
		StepTime, StepDelta, Stepped = now, dt, true
	end, Config.Frequency, Config.Priority)
	-- Animation control remains replayable and follows gameplay on frames where both run.
	-- Its hold/release boundaries must not inherit a diagnostic gameplay rate such as 10 Hz.
	RunService:BindToSimulation(function(dt: number)
		Animations.Step(dt, time())
	end, ANIMATION_FREQUENCY, Config.Priority + 1)
	RunService.PostSimulation:Connect(function()
		State.ApplyJoints()
		if not Stepped then
			return
		end
		Stepped = false
		if IsServer then
			local pending = Commits
			Commits = {}
			for _, commit in pending do
				if
					commit.Actor.Parent
					and (commit.Actor:GetAttribute("RagdollGeneration") :: string?) == commit.Generation
				then
					local previous = Committed[commit.Actor]
					local seen = if previous and previous.Generation == commit.Generation
						then previous
						else { Generation = commit.Generation, Identities = {} :: { [string]: boolean } }
					Committed[commit.Actor] = seen
					if not seen.Identities[commit.Identity] then
						seen.Identities[commit.Identity] = true
						commit.Apply()
					end
				end
			end
		end
		local listeners: { Listener } = {}
		for _, listener in Listeners do
			table.insert(listeners, listener)
		end
		table.sort(listeners, function(a: Listener, b: Listener)
			return if a.Priority == b.Priority then a.Order < b.Order else a.Priority < b.Priority
		end)
		for _, listener in listeners do
			if Listeners[listener.Callback] == listener then
				listener.Callback(StepDelta, StepTime)
			end
		end
		for actor in Committed do
			if not actor.Parent then
				Committed[actor] = nil
			end
		end
		if Config.Diagnostics then
			local actors = 0
			for _ in State.Records do actors += 1 end
			Diagnostics.Sample(os.clock(), actors, Attributes.CarrierCount())
		end
	end)
end

function Simulation.Init()
	if Initialized then
		return
	end
	Initialized = true
	Simulation:Setup()
	Simulation:Start()
end

return Simulation
