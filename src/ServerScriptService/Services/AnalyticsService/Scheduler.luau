--!strict
-- Shares one paced rolling-minute budget across analytics queues and combines compatible pending observations.
-- Queue overflow and lifecycle drains remain best effort and never change gameplay state.

--// Services
local Players = game:GetService("Players")

--// Modules
local Economy = require(script.Parent.Economy)
local DailyWins = require(script.Parent.DailyWins)
local Monetization = require(script.Parent.Monetization)

--// Constants
local WINDOW_SECONDS = 60
local BUDGET_SHARE = 0.8
local AGGREGATION_SECONDS = 2
local MAX_PLAYER_EVENTS = 256
local MAX_SERVER_EVENTS = 4096
local ACTIVITY_KEY = Enum.AnalyticsCustomFieldKeys.CustomField01.Name

--// Types
export type Event = Economy.Event | DailyWins.Event | Monetization.Event
type Entry = { Event: Event, ReadyAt: number }
type PlayerQueue = {
	Events: { Entry },
	KillEntries: { [string]: Entry },
	BonusEntry: Entry?,
}
export type Store = {
	Queues: { [Player]: PlayerQueue },
	Order: { Player },
	Cursor: number,
	Count: number,
	Attempts: { number },
	NextSendAt: number,
	Busy: boolean,
	Closed: boolean,
	OverflowWarned: boolean,
	SubmissionWarned: boolean,
	Submit: (Player, Event) -> (),
}
export type Scheduler = {
	New: (submit: (Player, Event) -> ()) -> Store,
	Enqueue: (store: Store, player: Player, event: Event, now: number) -> (),
	Step: (store: Store, now: number, playerCount: number, force: boolean?, onlyPlayer: Player?) -> (),
	RemovePlayer: (store: Store, player: Player, now: number, playerCount: number) -> (),
	Clear: (store: Store) -> (),
}

--// Module
local Scheduler = {} :: Scheduler

--// APIs
local function FieldsEqual(first: { [string]: string }?, second: { [string]: string }?): boolean
	if not first or not second then
		return first == second
	end
	for key, value in first do
		if second[key] ~= value then
			return false
		end
	end
	for key, value in second do
		if first[key] ~= value then
			return false
		end
	end
	return true
end

local function Capture(event: Event): Event
	if event.kind == "Economy" then
		local captured = table.clone(event)
		captured.customFields = table.clone(event.customFields)
		return captured
	end
	local captured = table.clone(event)
	if event.customFields then
		captured.customFields = table.clone(event.customFields)
	end
	return captured
end

local function IsKillSource(event: Economy.Event): boolean
	local activity = event.customFields[ACTIVITY_KEY]
	return event.resource == "Coins"
		and event.flow == Enum.AnalyticsEconomyFlowType.Source
		and event.transactionType == Enum.AnalyticsEconomyTransactionType.Gameplay.Name
		and (activity == "PlayerKill" or activity == "NPCKill")
end

local function CloseBonus(queue: PlayerQueue, now: number)
	local pending = queue.BonusEntry
	if pending then
		pending.ReadyAt = math.min(pending.ReadyAt, now)
	end
	queue.BonusEntry = nil
end

local function CloseCurrency(queue: PlayerQueue, resource: string, now: number)
	local pending = queue.KillEntries[resource]
	if pending then
		pending.ReadyAt = math.min(pending.ReadyAt, now)
	end
	queue.KillEntries[resource] = nil
end

local function CloseBatches(queue: PlayerQueue, now: number)
	for resource in queue.KillEntries do
		CloseCurrency(queue, resource, now)
	end
	CloseBonus(queue, now)
end

local function DropPlayer(store: Store, player: Player)
	local queue = store.Queues[player]
	if not queue then
		return
	end
	store.Count -= #queue.Events
	table.clear(queue.Events)
	table.clear(queue.KillEntries)
	queue.BonusEntry = nil
	store.Queues[player] = nil
	local index = table.find(store.Order, player)
	if index then
		table.remove(store.Order, index)
	end
end

local function NextReady(store: Store, now: number, force: boolean, onlyPlayer: Player?): (Player?, Entry?)
	if onlyPlayer then
		local queue = store.Queues[onlyPlayer]
		local entry = if queue then queue.Events[1] else nil
		if entry and (force or entry.ReadyAt <= now) then
			return onlyPlayer, entry
		end
		return nil, nil
	end
	local count = #store.Order
	for offset = 0, count - 1 do
		local index = (store.Cursor + offset - 1) % count + 1
		local player = store.Order[index]
		local entry = store.Queues[player].Events[1]
		if entry and (force or entry.ReadyAt <= now) then
			store.Cursor = index % count + 1
			return player, entry
		end
	end
	return nil, nil
end

function Scheduler.New(submit)
	return {
		Queues = {},
		Order = {},
		Cursor = 1,
		Count = 0,
		Attempts = {},
		NextSendAt = 0,
		Busy = false,
		Closed = false,
		OverflowWarned = false,
		SubmissionWarned = false,
		Submit = submit,
	}
end

function Scheduler.Enqueue(store, player, event, now)
	-- C8: closure is a lifecycle boundary, not a gameplay failure.
	if store.Closed then
		return
	end
	local queue = store.Queues[player]
	if not queue then
		queue = { Events = {}, KillEntries = {}, BonusEntry = nil }
		store.Queues[player] = queue
		table.insert(store.Order, player)
	end
	local readyAt = now
	if event.kind == "Economy" then
		local previous = queue.KillEntries[event.resource]
		local old = if previous then previous.Event else nil
		-- C6: only a still-open contiguous currency run can receive another increment.
		if
			previous
			and old
			and old.kind == "Economy"
			and now < previous.ReadyAt
			and IsKillSource(event)
			and old.flow == event.flow
			and old.resource == event.resource
			and old.transactionType == event.transactionType
			and old.itemSku == event.itemSku
			and FieldsEqual(old.customFields, event.customFields)
			and old.balance + event.amount == event.balance
		then
			old.amount += event.amount
			old.balance = event.balance
			return
		end
		CloseCurrency(queue, event.resource, now)
		if event.resource == "Coins" then
			CloseBonus(queue, now)
		end
		if IsKillSource(event) then
			readyAt = now + AGGREGATION_SECONDS
		end
	elseif event.kind == "Custom" and event.name == "VIPBonusCoins" then
		local previous = queue.BonusEntry
		local old = if previous then previous.Event else nil
		if
			previous
			and old
			and old.kind == "Custom"
			and now < previous.ReadyAt
			and old.name == event.name
			and FieldsEqual(old.customFields, event.customFields)
		then
			old.value += event.value
			return
		end
		CloseBonus(queue, now)
		readyAt = now + AGGREGATION_SECONDS
	else
		-- Keep discrete custom observations and funnel milestones individually ordered.
		CloseBatches(queue, now)
	end
	-- C7: a compatible merge above needs no extra memory; a new entry needs capacity.
	if #queue.Events >= MAX_PLAYER_EVENTS or store.Count >= MAX_SERVER_EVENTS then
		CloseBatches(queue, now)
		if not store.OverflowWarned then
			store.OverflowWarned = true
			warn("[AnalyticsService] Queue capacity reached; newest observations are being dropped")
		end
		return
	end
	local captured = Capture(event)
	local entry: Entry = { Event = captured, ReadyAt = readyAt }
	table.insert(queue.Events, entry)
	store.Count += 1
	if captured.kind == "Economy" and IsKillSource(captured) then
		queue.KillEntries[captured.resource] = entry
	elseif captured.kind == "Custom" and captured.name == "VIPBonusCoins" then
		queue.BonusEntry = entry
	end
end

function Scheduler.Step(store, now, playerCount, force, onlyPlayer)
	-- C5/C8: all callers share this attempt window and a single active drain.
	if store.Busy then
		return
	end
	store.Busy = true
	while store.Attempts[1] and store.Attempts[1] <= now - WINDOW_SECONDS do
		table.remove(store.Attempts, 1)
	end
	local limit = math.floor((120 + 20 * playerCount) * BUDGET_SHARE)
	while #store.Attempts < limit and (force or now >= store.NextSendAt) do
		local player, entry = NextReady(store, now, force == true, onlyPlayer)
		if not player or not entry then
			store.NextSendAt = now
			break
		end
		if player.Parent ~= Players then
			DropPlayer(store, player)
			continue
		end
		local queue = store.Queues[player]
		table.remove(queue.Events, 1)
		store.Count -= 1
		local event = entry.Event
		if event.kind == "Economy" and queue.KillEntries[event.resource] == entry then
			queue.KillEntries[event.resource] = nil
		end
		if queue.BonusEntry == entry then
			queue.BonusEntry = nil
		end
		table.insert(store.Attempts, now)
		-- Do not accumulate idle credit; a tick can catch up only on an active backlog.
		store.NextSendAt = math.max(store.NextSendAt, now - 0.25) + WINDOW_SECONDS / limit
		local success, message = pcall(function()
			store.Submit(player, event)
			return true
		end)
		if not success and not store.SubmissionWarned then
			store.SubmissionWarned = true
			warn("[AnalyticsService] Submission failed:", message)
		end
		-- Attempted calls consume quota even on failure. Never retry uncertain outcomes.
	end
	store.Busy = false
end

function Scheduler.RemovePlayer(store, player, now, playerCount)
	Scheduler.Step(store, now, playerCount, true, player)
	DropPlayer(store, player)
end

function Scheduler.Clear(store)
	store.Closed = true
	for _, player in table.clone(store.Order) do
		DropPlayer(store, player)
	end
end

return Scheduler
