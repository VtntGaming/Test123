-- Best-effort server evidence. Reports accumulate suspicion; this service never kicks, bans or changes hits.
local DetectionService = {}
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)
local Settings = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig")).Detection

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
	if PlayerData.Get(player, "DetectionFlagged") ~= flagged then
		PlayerData.Set(player, "DetectionFlagged", flagged)
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

function DetectionService.Init()
	if initialized then
		return
	end

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
	RunService.Heartbeat:Connect(function()
		for player, entry in entries do
			updateScore(player, entry, Workspace:GetServerTimeNow())
		end
	end)
end
return DetectionService
