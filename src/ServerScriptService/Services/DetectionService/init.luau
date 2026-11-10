-- Best-effort server evidence. Reports accumulate suspicion; this service never kicks, bans or changes hits.
local DetectionService = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Settings = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig")).Detection
local Tracker = require(script:WaitForChild("AttackStateTracker"))

local reported = Instance.new("BindableEvent")
DetectionService.Reported = reported.Event
local initialized = false
local entries = {}

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function entryFor(player)
	local entry = entries[player]
	if not entry then
		entry = {
			tracker = Tracker.new(Settings.AttackState),
			score = 0,
			scoreAt = Workspace:GetServerTimeNow(),
			totalReports = 0,
			reports = {},
		}
		entries[player] = entry
	end
	return entry
end

local function updateScore(player, entry, now)
	entry.score = math.max(0, entry.score - math.max(0, now - entry.scoreAt) * Settings.DecayPerSecond)
	entry.scoreAt = now
	local flagged = entry.score >= Settings.FlagThreshold
	if player:GetAttribute("DetectionFlagged") ~= flagged then
		player:SetAttribute("DetectionFlagged", flagged)
	end
	return flagged
end

function DetectionService.Report(player, reason, details)
	if player.Parent ~= Players then
		return
	end
	local entry, now = entryFor(player), Workspace:GetServerTimeNow()
	updateScore(player, entry, now)
	entry.score += Settings.AttackStateMismatchWeight
	entry.totalReports += 1
	local record = { reason = reason, at = now, details = table.clone(details), score = entry.score }
	table.insert(entry.reports, record)
	if #entry.reports > Settings.MaxReports then
		table.remove(entry.reports, 1)
	end
	updateScore(player, entry, now)
	if Settings.WarnOnReport then
		warn(string.format("[DetectionService] %s: %s (suspicion %.2f)", player.Name, reason, entry.score))
	end
	reported:Fire(player, { reason = reason, at = now, details = table.clone(details), score = entry.score })
end

function DetectionService.GetSummary(player)
	local entry = entries[player]
	if not entry then
		return { score = 0, flagged = false, totalReports = 0, reports = {} }
	end
	local flagged = updateScore(player, entry, Workspace:GetServerTimeNow())
	local reports = {}
	for _, record in entry.reports do
		local copy = table.clone(record)
		copy.details = table.clone(record.details)
		table.insert(reports, copy)
	end
	return { score = entry.score, flagged = flagged, totalReports = entry.totalReports, reports = reports }
end

local function sample(player, entry, now)
	local actor = player.Character
	local humanoid = actor and actor:FindFirstChildOfClass("Humanoid")
	local root = actor and actor:FindFirstChild("HumanoidRootPart")
	local generation = actor and actor:GetAttribute("RagdollGeneration")
	if entry.root ~= root or entry.generation ~= generation then
		entry.tracker:Reset()
	end
	entry.root, entry.generation = root, generation
	local airborne
	if
		actor
		and actor:IsDescendantOf(Workspace)
		and humanoid
		and humanoid.Health > 0
		and root
		and root:IsA("BasePart")
		and not root.Anchored
		and not actor:GetAttribute("IsRagdolled")
		and not actor:GetAttribute("IsFrozen")
		and not actor:GetAttribute("MovementLocked")
		and not player:GetAttribute("IsFrozen")
		and not player:GetAttribute("TeleportingActive")
	then
		airborne = humanoid.FloorMaterial == Enum.Material.Air
	end
	for _, check in entry.tracker:Observe(actor, airborne, now) do
		DetectionService.Report(player, "AttackStateMismatch", {
			attackId = check.attackId,
			attackType = check.attackType,
			clientStartedAt = check.clientStartedAt,
			receivedAt = check.receivedAt,
			deadline = check.deadline,
			ping = check.ping,
			lastAirborneAt = check.lastAirborneAt,
			lastGroundedAt = check.lastGroundedAt,
		})
	end
end

function DetectionService.TrackAttack(player, actor, attackId, attackType, clientStartedAt)
	DetectionService.Init()
	if not Settings.AttackState.Enable or player.Parent ~= Players or player.Character ~= actor then
		return
	end
	if attackType ~= "Attack" and attackType ~= "JumpAttack" then
		return
	end
	local now, entry = Workspace:GetServerTimeNow(), entryFor(player)
	sample(player, entry, now)
	-- This timestamp is context only; it cannot expand the server's history or future grace period.
	if
		not finite(clientStartedAt)
		or clientStartedAt < now - Settings.AttackState.HistoryWindow
		or clientStartedAt > now + 0.05
	then
		clientStartedAt = nil
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	if not ok or not finite(ping) or ping < 0 then
		ping = nil
	end
	-- A connection slower than the entire grace period cannot supply timely evidence reliably.
	if ping and ping * 0.5 > Settings.AttackState.ObservationWindow then
		return
	end
	entry.tracker:Track(attackId, attackType, clientStartedAt, now, ping)
end

function DetectionService.Init()
	if initialized then
		return
	end
	assert(
		type(Settings.AttackState.Enable) == "boolean" and type(Settings.WarnOnReport) == "boolean",
		"Invalid detection toggles"
	)
	for _, name in { "HistoryWindow", "ObservationWindow", "SampleInterval", "MaxSampleGap", "MaxPending" } do
		local value = Settings.AttackState[name]
		assert(finite(value) and value > 0, "Invalid Detection.AttackState." .. name)
	end
	assert(
		Settings.AttackState.MaxPending % 1 == 0
			and Settings.AttackState.MaxSampleGap > Settings.AttackState.SampleInterval,
		"Invalid detection sample budget"
	)
	for _, name in { "AttackStateMismatchWeight", "FlagThreshold", "MaxReports", "DecayPerSecond" } do
		local value = Settings[name]
		assert(finite(value) and value >= 0 and (name == "DecayPerSecond" or value > 0), "Invalid Detection." .. name)
	end
	assert(Settings.MaxReports % 1 == 0, "Detection.MaxReports must be an integer")
	initialized = true
	local function attach(player)
		local entry = entryFor(player)
		updateScore(player, entry, Workspace:GetServerTimeNow())
	end
	Players.PlayerAdded:Connect(attach)
	Players.PlayerRemoving:Connect(function(player)
		entries[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		attach(player)
	end
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < Settings.AttackState.SampleInterval then
			return
		end
		accumulated = 0
		local now = Workspace:GetServerTimeNow()
		for player, entry in entries do
			if player.Parent ~= Players then
				entries[player] = nil
				continue
			end
			updateScore(player, entry, now)
			if Settings.AttackState.Enable then
				sample(player, entry, now)
			else
				entry.tracker:Reset()
			end
		end
	end)
end

return DetectionService
