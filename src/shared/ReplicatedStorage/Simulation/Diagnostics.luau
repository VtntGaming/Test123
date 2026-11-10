--!strict
-- Collects opt-in, bounded local observations without replicating telemetry or influencing gameplay.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

--// Modules
local Config = require(ReplicatedStorage.Config.Simulation)

--// Types
export type Sample = {
	-- Local observation timestamp in seconds, outside the simulation callback.
	At: number,
	-- Observed frame duration in milliseconds; not a resimulation CPU measurement.
	FrameMs: number,
	-- Observed physics processing duration in milliseconds.
	PhysicsMs: number,
	-- Engine network-tree receive rate, or nil when that counter is unavailable.
	ReceiveKbps: number?,
	-- Engine network-tree send rate, or nil when that counter is unavailable.
	SendKbps: number?,
	-- Registered actor count at the sample boundary.
	Actors: number,
	-- Bound simulation-carrier count at the sample boundary.
	Carriers: number,
}
export type Snapshot = {
	-- Whether local diagnostics are enabled in the startup config.
	Enabled: boolean,
	-- Observed event counts; attribute writes are not network byte counts.
	Counters: { [string]: number },
	-- At most 120 samples, ordered oldest to newest, collected at most twice per second.
	Samples: { Sample },
}
export type Diagnostics = {
	-- Increments a local counter when diagnostics are enabled.
	Count: (string, number?) -> (),
	-- Records correction count and largest observed translation/rotation errors.
	Correction: (CFrame) -> (),
	-- Samples engine metrics outside simulation, at most once per half second.
	Sample: (number, number, number) -> (),
	-- Returns an independent snapshot; does not expose mutable collector state.
	GetSnapshot: () -> Snapshot,
}

--// Properties
local Counters: { [string]: number } = {}
local Samples: { Sample } = {}
local NextSample = 0
local Diagnostics: Diagnostics = {} :: Diagnostics

local function NetworkRate(name: string): number?
	local network = Stats:FindFirstChild("Network")
	local items = network and network:FindFirstChild("ServerStatsItem")
	local item = items and items:FindFirstChild(name)
	if not item or not item:IsA("StatsItem") then return nil end
	local ok, value = pcall(function() return item:GetValue() end)
	return if ok then value else nil
end

function Diagnostics.Count(name, amount)
	if Config.Diagnostics then Counters[name] = (Counters[name] or 0) + (amount or 1) end
end

function Diagnostics.Correction(error)
	if not Config.Diagnostics then return end
	Diagnostics.Count("Corrections")
	local _, angle = error.Rotation:ToAxisAngle()
	Counters.MaxPositionError = math.max(Counters.MaxPositionError or 0, error.Position.Magnitude)
	Counters.MaxRotationErrorDegrees = math.max(Counters.MaxRotationErrorDegrees or 0, math.deg(math.abs(angle)))
end

function Diagnostics.Sample(now, actors, carriers)
	if not Config.Diagnostics or now < NextSample then return end
	NextSample = now + 0.5
	table.insert(Samples, {
		At = now, FrameMs = Stats.FrameTime * 1000, PhysicsMs = Stats.PhysicsStepTime * 1000,
		ReceiveKbps = NetworkRate("Receive kBps"), SendKbps = NetworkRate("Send kBps"),
		Actors = actors, Carriers = carriers,
	})
	if #Samples > 120 then table.remove(Samples, 1) end
end

function Diagnostics.GetSnapshot()
	local samples: { Sample } = {}
	for _, sample in Samples do table.insert(samples, table.clone(sample)) end
	return { Enabled = Config.Diagnostics, Counters = table.clone(Counters), Samples = samples }
end

return Diagnostics
