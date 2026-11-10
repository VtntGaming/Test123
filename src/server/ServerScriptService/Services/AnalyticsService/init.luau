--!strict
-- Captures server-owned telemetry and submits it through one bounded, budget-aware server scheduler.
-- Submission remains best effort; failures never change rewards or saved player progress.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RobloxAnalyticsService = game:GetService("AnalyticsService")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Funnel = require(script.Funnel)
local Economy = require(script.Economy)
local DailyWins = require(script.DailyWins)
local Monetization = require(script.Monetization)
local Scheduler = require(script.Scheduler)
local DailyConfig = require(ReplicatedStorage.SharedModules.DailyChestConfig)

--// Constants
local DAY_SECONDS = 86400
local SCHEDULER_INTERVAL = 0.25
local SHUTDOWN_SECONDS = 5

--// Types
type Event = Scheduler.Event
type Session = {
	player: Player,
	funnel: { gamesPlayed: number },
	daily: DailyWins.Session,
	lastMatchId: number,
	closed: boolean,
}
export type AnalyticsService = {
	Init: () -> (),
	Setup: (self: AnalyticsService) -> (),
	Start: (self: AnalyticsService) -> (),
	RecordMatchStarted: (player: Player, matchId: number) -> (),
	RecordEconomy: (player: Player, event: Economy.Input) -> (),
	RecordCustom: (player: Player, event: Monetization.Event?) -> (),
	RecordDailyWins: (player: Player, dayStart: number, wins: number, winsRequired: number, claimed: boolean) -> (),
}

--// Properties
local Initialized = false
local Closing = false
local DepartingPlayers = setmetatable({} :: { [Player]: boolean }, { __mode = "k" })
local Sessions: { [Player]: Session } = {}
local DataLoadedConnections: { [Player]: PlayerData.Connection } = {}

--// Service
local AnalyticsService = {} :: AnalyticsService

--// APIs
local function SubmitEvent(player: Player, event: Event)
	if RunService:IsStudio() then
		if event.kind == "Economy" then
			print(
				"[AnalyticsService] Economy",
				player.Name,
				event.flow.Name,
				event.resource,
				event.amount,
				event.balance,
				event.transactionType,
				event.itemSku,
				event.customFields
			)
		elseif event.kind == "Funnel" then
			print(
				"[AnalyticsService]",
				player.Name,
				event.name,
				event.sessionId,
				event.step,
				event.stepName,
				event.customFields
			)
		else
			print("[AnalyticsService]", player.Name, event.name, event.value, event.customFields)
		end
		return
	end
	if event.kind == "Economy" then
		RobloxAnalyticsService:LogEconomyEvent(
			player,
			event.flow,
			event.resource,
			event.amount,
			event.balance,
			event.transactionType,
			event.itemSku,
			event.customFields
		)
	elseif event.kind == "Custom" then
		RobloxAnalyticsService:LogCustomEvent(player, event.name, event.value, event.customFields)
	else
		RobloxAnalyticsService:LogFunnelStepEvent(
			player,
			event.name,
			event.sessionId,
			event.step,
			event.stepName,
			event.customFields
		)
	end
end

local EventStore = Scheduler.New(SubmitEvent)

local function Enqueue(session: Session, event: Event)
	if session.closed then
		return
	end
	Scheduler.Enqueue(EventStore, session.player, event, os.clock())
end

local function GetOrCreateSession(player: Player): Session?
	if Closing or DepartingPlayers[player] then
		return nil
	end
	if player.Parent ~= Players then
		return nil
	end
	if PlayerData.Get(player, "DataLoaded") ~= true then
		return nil
	end
	local existing = Sessions[player]
	if existing then
		return existing
	end
	local session: Session = {
		player = player,
		funnel = Funnel.NewSession(PlayerData.Get(player, "GamesPlayed") or 0),
		daily = DailyWins.NewSession(),
		lastMatchId = 0,
		closed = false,
	}
	Sessions[player] = session
	local funnelEvent = Funnel.DataReady(session.funnel)
	if funnelEvent then
		Enqueue(session, funnelEvent)
	end
	local dayStart = math.floor(os.time() / DAY_SECONDS) * DAY_SECONDS
	-- C2: do not restore yesterday's progress while DailyWinsService is normalizing data.
	local sameDay = PlayerData.Get(player, "DailyWinsTimestamp") == dayStart
	local wins = if sameDay then PlayerData.Get(player, "DailyWins") :: number else 0
	local claimed = sameDay and PlayerData.Get(player, "DailyWinsClaimed") == true
	for _, event in DailyWins.Record(session.daily, player.UserId, dayStart, wins, DailyConfig.WinsRequired, claimed) do
		Enqueue(session, event)
	end
	return session
end

local function AttachPlayer(player: Player)
	if player.Parent ~= Players or DataLoadedConnections[player] then
		return
	end
	DataLoadedConnections[player] = PlayerData.Observe(player, "DataLoaded", function()
		GetOrCreateSession(player)
	end)
	GetOrCreateSession(player)
end

local function RemovePlayer(player: Player)
	DepartingPlayers[player] = true
	local session = Sessions[player]
	if session then
		session.closed = true
		Sessions[player] = nil
	end
	Scheduler.RemovePlayer(EventStore, player, os.clock(), #Players:GetPlayers())
	local connection = DataLoadedConnections[player]
	if connection then
		connection:Disconnect()
		DataLoadedConnections[player] = nil
	end
end

function AnalyticsService:Setup()
	-- State exists before any player observers are connected.
	Sessions = {}
	DataLoadedConnections = {}
	DepartingPlayers = setmetatable({} :: { [Player]: boolean }, { __mode = "k" })
	EventStore = Scheduler.New(SubmitEvent)
end

function AnalyticsService:Start()
	Players.PlayerAdded:Connect(AttachPlayer)
	Players.PlayerRemoving:Connect(RemovePlayer)
	task.spawn(function()
		while not Closing do
			Scheduler.Step(EventStore, os.clock(), #Players:GetPlayers())
			task.wait(SCHEDULER_INTERVAL)
		end
	end)
	game:BindToClose(function()
		Closing = true
		EventStore.Closed = true
		local deadline = os.clock() + SHUTDOWN_SECONDS
		while EventStore.Count > 0 and os.clock() < deadline do
			Scheduler.Step(EventStore, os.clock(), #Players:GetPlayers(), true)
			if EventStore.Count > 0 then
				task.wait(SCHEDULER_INTERVAL)
			end
		end
		Scheduler.Clear(EventStore)
	end)
	for _, player in Players:GetPlayers() do
		AttachPlayer(player)
	end
end

function AnalyticsService.Init()
	if Initialized then
		return
	end
	Initialized = true
	AnalyticsService:Setup()
	AnalyticsService:Start()
end

function AnalyticsService.RecordEconomy(player, input)
	xpcall(function(...) 
		AnalyticsService.Init()
		local session = GetOrCreateSession(player)
		if not session then
			return
		end
		local event = Economy.Build(player, input)
		if event then
			Enqueue(session, event)
		end
	end, function(err) 
		warn(err)
	end)
end

function AnalyticsService.RecordCustom(player, event)
	xpcall(function(...) 
		-- Optional builders implement C3 by returning no event for a zero VIP bonus.
		if not event then
			return
		end
		AnalyticsService.Init()
		local session = GetOrCreateSession(player)
		if session then
			Enqueue(session, event)
		end
	end, function(err) 
		warn(err)
	end)
end

function AnalyticsService.RecordDailyWins(player, dayStart, wins, winsRequired, claimed)
	xpcall(function(...) 
		AnalyticsService.Init()
		local session = GetOrCreateSession(player)
		if not session then
			return
		end
		for _, event in DailyWins.Record(session.daily, player.UserId, dayStart, wins, winsRequired, claimed) do
			Enqueue(session, event)
		end
	end, function(err) 
		warn(err)
	end)
end

-- Preserve the existing match eligibility and server match-ID deduplication contract.
function AnalyticsService.RecordMatchStarted(player, matchId)
	xpcall(function(...) 
		AnalyticsService.Init()
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		if type(matchId) ~= "number" or matchId ~= matchId or matchId == math.huge or matchId < 1 or matchId % 1 ~= 0 then
			return
		end
		if ReplicatedValues.GetString(ReplicatedStorage, "MatchState") ~= "Playing" then
			return
		end
		if PlayerData.Get(player, "IsOnArena") ~= true or PlayerData.Get(player, "MatchId") ~= matchId then
			return
		end
		local session = GetOrCreateSession(player)
		if not session or matchId <= session.lastMatchId then
			return
		end
		session.lastMatchId = matchId
		Enqueue(session, { kind = "Custom", name = "MatchStartedParticipation", value = 1 })
		local event = Funnel.RecordMatch(session.funnel, PlayerData.Get(player, "GamesPlayed") or 0)
		if event then
			Enqueue(session, event)
		end
	end, function(err) 
		warn(err)
	end)
end

return AnalyticsService
