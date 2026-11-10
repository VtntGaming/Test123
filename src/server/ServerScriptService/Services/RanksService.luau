--!optimize 2
-- Owns ranks service behavior and accesses player state through the shared data API.
local RanksService = {}
local initialized = false

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local LeagueConfig = require(SharedModules:WaitForChild("LeagueConfig"))
local LeagueUtil = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("LeagueUtil"))

-- Adjust this path if PlayerDataService doesn't sit next to RanksService.
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local Events = ReplicatedStorage:WaitForChild("Events")
local RanksPageFunction = Events:WaitForChild("RanksPageFunction")

-- ==========================================
-- CONFIG
-- ==========================================
local Config = LeagueConfig.Leaderboard

-- Studio playtests use their own stores/topics so they never touch the live board.
local STORE_SUFFIX = if RunService:IsStudio() then "_Studio" else ""

local MANIFEST_KEY = "Manifest"
local TOPIC_COMMITTED = "RanksCommitted" .. STORE_SUFFIX

local FLUSH_INTERVAL = 60          -- Ordered-store writes: at most one per dirty player per minute.
local BUDGET_POLL = 1              -- Seconds between budget re-checks when starved.
local WRITE_BUDGET_MAX_WAIT = 10   -- Give up (and retry next flush) after this long.
local READ_BUDGET_MAX_WAIT = 30
local SEGMENT_FETCH_SPACING = 0.05 -- Small gap between segment reads.
local READ_JITTER = 30             -- Random extra seconds on the fallback poll.
local COMMIT_LOAD_JITTER = 30      -- Spread reloads after a commit (per-key read throughput).
local SHUTDOWN_FLUSH_TIMEOUT = 5

local PAGE_MAX_SPAN = 100          -- Max rows per page request.
local PAGE_RATE = 10               -- Page requests refilled per second, per player.
local PAGE_BURST = 20              -- Bucket size (covers the initial open + fast scroll).

-- ==========================================
-- DATASTORES
-- ==========================================
local TrophiesStore = DataStoreService:GetOrderedDataStore(Config.OrderedStoreName .. STORE_SUFFIX)
local SnapshotStore = DataStoreService:GetDataStore(Config.SnapshotStoreName .. STORE_SUFFIX)

-- Shared with RanksBuildService so both always use the same stores, keys and topics.
RanksService.TrophiesStore = TrophiesStore
RanksService.SnapshotStore = SnapshotStore
RanksService.MANIFEST_KEY = MANIFEST_KEY
RanksService.TOPIC_COMMITTED = TOPIC_COMMITTED
RanksService.STORE_SUFFIX = STORE_SUFFIX

-- ==========================================
-- STATE
-- ==========================================
local function newSnapshot()
	return {
		seq = 0,            -- build sequence of the loaded manifest (0 = nothing loaded)
		builtAt = 0,
		floor = 1,          -- lowest trophy value scanned; below it = deeper than the scan
		scanned = 0,        -- total entries counted (rows + tail)
		displayCount = 0,   -- min(#rows, DisplayDepth): what the client list shows

		-- Rows region (names + ids), descending. Includes the DisplayMargin rows.
		rowsU = {},
		rowsV = {},
		rowsN = {},
		rankByUserId = {},  -- userId -> row index

		-- Tail region (counts only), descending distinct values.
		tailV = {},         -- distinct values
		tailAtOrAbove = {}, -- global number of entries with value >= tailV[j]
	}
end

local snapshot = newSnapshot()
local nameCache = {}         -- userId -> display name (from the loaded snapshot, carried forward by builders)
local loadingSnapshot = false
local debugLocked = false    -- set by DebugInjectSnapshot so the reader loop doesn't overwrite it
local isShuttingDown = false

local dirtyPlayers = {}      -- [Player] = true -> needs an ordered-store write
local lastWritten = {}       -- [userId] = value this server last wrote to the ordered store
local playerConnections = {} -- [Player] = { (RBXScriptConnection | PlayerData.Connection) }
local pageBuckets = {}       -- [Player] = { tokens, t }

-- ==========================================
-- HELPERS
-- ==========================================

-- Number of entries in a DESCENDING array strictly greater than v.
local function countGreater(values, v)
	local lo, hi = 1, #values
	local firstLE = #values + 1
	while lo <= hi do
		local mid = (lo + hi) // 2
		if values[mid] <= v then
			firstLE = mid
			hi = mid - 1
		else
			lo = mid + 1
		end
	end
	return firstLE - 1
end

-- Yields until the server has budget for this request type. False if maxWait expires.
local function waitForBudget(requestType, maxWait)
	local waited = 0
	while DataStoreService:GetRequestBudgetForRequestType(requestType) < 1 do
		if maxWait and waited >= maxWait then return false end
		task.wait(BUDGET_POLL)
		waited += BUDGET_POLL
	end
	return true
end

function RanksService.SegmentKey(seq, id, attempt)
	return string.format("S_%d_%d_%d", seq, id, attempt)
end

-- ==========================================
-- TROPHY RULES
-- ==========================================

-- placement: 1 = winner, N = last, nil = draw.
-- Only the first #PlacementWinScale places earn trophies; the rest lose (or get 0).
local function computeDelta(trophies, placement, matchSize)
	if placement == nil then
		return LeagueConfig.DrawTrophies or 0
	end

	local league = LeagueUtil.GetLeague(trophies)
	placement = math.clamp(math.floor(placement), 1, math.max(1, matchSize))

	-- Rewarded places.
	local winScales = LeagueConfig.PlacementWinScale or { 1 }
	local rewarded = #winScales
	if placement <= rewarded then
		return math.max(1, math.round(league.Win * winScales[placement]))
	end

	-- Everyone else.
	if LeagueConfig.LoseOutsideTop == false then
		return 0
	end

	local scale = LeagueConfig.LossScaleByPlacement or { Min = 1, Max = 1 }
	local firstLoser = rewarded + 1
	local t = if matchSize > firstLoser then (placement - firstLoser) / (matchSize - firstLoser) else 1
	t = math.clamp(t, 0, 1)
	return -math.round(league.Loss * (scale.Min + (scale.Max - scale.Min) * t))
end
RanksService.ComputeDelta = computeDelta -- handy for UI previews and tests

-- Applies one match result. Idempotent per match: a player gets exactly one
-- result per matchId, so elimination, match end and leaving can never stack.
-- Returns the applied delta, or nil if nothing was applied.
function RanksService.ApplyMatchResult(player, placement, matchSize, matchId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	if PlayerData.Get(player, "DataLoaded") ~= true then
		return nil
	end
	if type(matchSize) ~= "number" or matchSize < LeagueConfig.MinPlayersForTrophies then return nil end
	if matchId == nil or PlayerData.Get(player, "MatchId") ~= matchId then
		return nil
	end -- not a participant
	if PlayerData.Get(player, "TrophyMatchId") == matchId then
		return nil
	end -- already resolved
	PlayerData.Set(player, "TrophyMatchId", matchId)

	local trophies = PlayerData.Get(player, "Trophies") or 0
	local newTrophies = math.max(0, trophies + computeDelta(trophies, placement, matchSize))
	local applied = newTrophies - trophies

	-- Delta first, so the client already has it when the Trophies change arrives.
	PlayerData.Set(player, "MatchTrophyDelta", applied)
	PlayerData.Set(player, "Trophies", newTrophies) -- listener handles dirty flag, PeakTrophies and rank
	return applied
end

-- ==========================================
-- ORDERED STORE WRITES
-- ==========================================

-- Returns false only when the write should be retried later.
local function writeTrophies(userId, trophies)
	if userId < 1 then return true end -- Studio local-server test players have negative ids
	trophies = math.max(0, math.floor(tonumber(trophies) or 0))

	local last = lastWritten[userId]
	if last == trophies then return true end
	if trophies == 0 and last == nil then return true end -- never indexed, nothing to clear

	if not waitForBudget(Enum.DataStoreRequestType.OrderedWrite, WRITE_BUDGET_MAX_WAIT) then
		return false
	end

	local ok, err = pcall(function()
		TrophiesStore:SetAsync(tostring(userId), trophies)
	end)
	if not ok then
		warn("[RanksService] Ordered write failed for " .. userId .. ": " .. tostring(err))
		return false
	end
	lastWritten[userId] = trophies
	return true
end

local function flushDirty()
	-- Copy first: writes yield, and new dirty marks may arrive meanwhile.
	local batch = {}
	for player in pairs(dirtyPlayers) do
		table.insert(batch, player)
	end
	table.clear(dirtyPlayers)

	for _, player in ipairs(batch) do
		if player.Parent == Players and PlayerData.Get(player, "DataLoaded") == true then
			if not writeTrophies(player.UserId, PlayerData.Get(player, "Trophies") or 0) then
				dirtyPlayers[player] = true -- retry next flush
			end
		end
	end
end

-- ==========================================
-- RANK READS
-- ==========================================

-- Returns (rank, overflow). rank 0 = unranked. overflow = deeper than the scan ("N+").
local function computeRank(userId, trophies)
	local snap = snapshot
	if trophies <= 0 or snap.seq == 0 then return 0, false end

	local rowsV = snap.rowsV
	local rowCount = #rowsV
	local idx = snap.rankByUserId[userId]

	-- Unchanged since the snapshot: keep the exact list position (panel == list row).
	if idx and rowsV[idx] == trophies then return idx, false end

	-- Rows region: exact.
	if rowCount > 0 and trophies >= rowsV[rowCount] then
		local greater = countGreater(rowsV, trophies)
		if idx and rowsV[idx] > trophies then
			greater -= 1 -- don't count our own stale (higher) row
		end
		return greater + 1, false
	end

	-- Deeper than anything scanned.
	if trophies < snap.floor then return snap.scanned, true end

	-- Tail region: exact as of the build, except our own stale tail entry (±1, invisible below the list).
	local k = countGreater(snap.tailV, trophies)
	local greater = if k == 0 then rowCount else snap.tailAtOrAbove[k]
	if idx then
		greater -= 1 -- our stale row sits in the rows region, which is entirely above us
	end
	return greater + 1, false
end

function RanksService.GetRank(userId, trophies)
	return computeRank(userId, trophies or 0)
end

function RanksService.RefreshPlayerRank(player)
	if PlayerData.Get(player, "DataLoaded") ~= true then
		return
	end
	local trophies = PlayerData.Get(player, "Trophies") or 0
	local rank, overflow = computeRank(player.UserId, trophies)
	local idx = snapshot.rankByUserId[player.UserId]

	PlayerData.Set(player, "SnapshotRank", if idx and idx <= snapshot.displayCount then idx else 0)
	PlayerData.Set(player, "GlobalRankOverflow", overflow)
	PlayerData.Set(player, "GlobalRank", rank)
end

-- Value at a given rank in the loaded snapshot (nil past the scanned depth).
-- Used by RanksBuildService to plan shards on quantiles of the previous build.
function RanksService.ValueAtRank(rank)
	local snap = snapshot
	if snap.seq == 0 or rank < 1 then return nil end

	local rowsV = snap.rowsV
	if rank <= #rowsV then return rowsV[rank] end
	if rank > snap.scanned then return nil end

	-- Smallest j with tailAtOrAbove[j] >= rank (tailAtOrAbove is increasing).
	local acc = snap.tailAtOrAbove
	local lo, hi, found = 1, #acc, nil
	while lo <= hi do
		local mid = (lo + hi) // 2
		if acc[mid] >= rank then
			found = mid
			hi = mid - 1
		else
			lo = mid + 1
		end
	end
	return if found then snap.tailV[found] else nil
end

function RanksService.GetSnapshotSeq()
	return snapshot.seq
end

function RanksService.GetSnapshotInfo()
	return {
		seq = snapshot.seq,
		builtAt = snapshot.builtAt,
		floor = snapshot.floor,
		scanned = snapshot.scanned,
		rows = #snapshot.rowsU,
		displayCount = snapshot.displayCount,
	}
end

function RanksService.GetCachedName(userId)
	return nameCache[userId]
end

-- ==========================================
-- SNAPSHOT (reader)
-- ==========================================

-- Builds the in-memory snapshot and swaps it in atomically.
-- segments[i] matches manifest.segments[i]; order is DESCENDING by value.
local function applySnapshot(manifest, segments)
	local snap = newSnapshot()
	snap.seq = tonumber(manifest.seq) or 0
	snap.builtAt = tonumber(manifest.builtAt) or 0
	snap.floor = math.max(1, tonumber(manifest.floor) or 1)

	local rowsU, rowsV, rowsN, byId = snap.rowsU, snap.rowsV, snap.rowsN, snap.rankByUserId
	local tailV, tailAtOrAbove = snap.tailV, snap.tailAtOrAbove
	local newNames = {}
	local running = nil -- global entry count, starts once the count region begins

	for i, seg in ipairs(segments) do
		local kind = manifest.segments[i].kind
		if kind == "rows" then
			if running then
				warn("[RanksService] rows segment after a count segment in seq " .. snap.seq .. "; skipped")
				continue
			end
			local u, v, n = seg.u or {}, seg.v or {}, seg.n
			for j = 1, #u do
				local userId = u[j]
				-- A player whose score moved between two shard scans can appear twice: keep the first (higher).
				if byId[userId] ~= nil then continue end

				local idx = #rowsU + 1
				rowsU[idx], rowsV[idx] = userId, v[j]
				byId[userId] = idx

				local name = (n and n[j]) or ""
				if name == "" then name = nameCache[userId] or "" end
				rowsN[idx] = name
				if name ~= "" then newNames[userId] = name end
			end
		else
			running = running or #rowsU
			local hv, hc = seg.hv or {}, seg.hc or {}
			for j = 1, #hv do
				running += hc[j] or 0
				tailV[#tailV + 1] = hv[j]
				tailAtOrAbove[#tailAtOrAbove + 1] = running
			end
		end
	end

	snap.scanned = running or #rowsU
	snap.displayCount = math.min(#rowsU, Config.DisplayDepth)

	nameCache = newNames -- bounded: only names of the current rows region
	snapshot = snap

	ReplicatedValues.Set(ReplicatedStorage, "RanksTotal", snap.displayCount)
	ReplicatedValues.Set(ReplicatedStorage, "RanksVersion", snap.seq) -- clients invalidate their page cache on this
	for _, player in ipairs(Players:GetPlayers()) do
		RanksService.RefreshPlayerRank(player)
	end
end

local function loadSnapshotInternal()
	if not waitForBudget(Enum.DataStoreRequestType.StandardRead, READ_BUDGET_MAX_WAIT) then return false end
	local okM, manifest = pcall(function()
		return SnapshotStore:GetAsync(MANIFEST_KEY)
	end)
	if not okM then
		warn("[RanksService] Manifest read failed: " .. tostring(manifest))
		return false
	end
	if type(manifest) ~= "table" or type(manifest.segments) ~= "table" then return false end

	local seq = tonumber(manifest.seq) or 0
	if seq <= snapshot.seq then return false end

	-- Fetch EVERY segment before touching the live snapshot; any failure keeps the old one.
	local segments = table.create(#manifest.segments)
	for i, meta in ipairs(manifest.segments) do
		if not waitForBudget(Enum.DataStoreRequestType.StandardRead, READ_BUDGET_MAX_WAIT) then return false end
		local key = RanksService.SegmentKey(seq, meta.id, meta.attempt)
		local okS, seg = pcall(function()
			return SnapshotStore:GetAsync(key)
		end)
		if not okS or type(seg) ~= "table" or seg.seq ~= seq then
			warn("[RanksService] Segment " .. key .. " unavailable; keeping snapshot " .. snapshot.seq)
			return false
		end
		segments[i] = seg
		task.wait(SEGMENT_FETCH_SPACING)
	end

	if debugLocked then return false end
	applySnapshot(manifest, segments)
	return true
end

-- Loads the newest manifest if it changed. Returns true if a new snapshot went live.
function RanksService.LoadSnapshot()
	if loadingSnapshot or debugLocked then return false end
	loadingSnapshot = true
	local ok, changed = pcall(loadSnapshotInternal)
	loadingSnapshot = false
	if not ok then
		warn("[RanksService] LoadSnapshot error: " .. tostring(changed))
		return false
	end
	return changed
end

local function subscribeCommits()
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(TOPIC_COMMITTED, function(message)
			local seq = tonumber(message.Data)
			if seq and seq > snapshot.seq then
				task.delay(math.random() * COMMIT_LOAD_JITTER, RanksService.LoadSnapshot)
			end
		end)
	end)
	if not ok then
		warn("[RanksService] Commit subscription failed (poll fallback still active): " .. tostring(err))
	end
end

-- ==========================================
-- PAGE API
-- ==========================================
local function allowPageRequest(player)
	local now = os.clock()
	local bucket = pageBuckets[player]
	if not bucket then
		bucket = { tokens = PAGE_BURST, t = now }
		pageBuckets[player] = bucket
	end
	bucket.tokens = math.min(PAGE_BURST, bucket.tokens + (now - bucket.t) * PAGE_RATE)
	bucket.t = now
	if bucket.tokens < 1 then return false end
	bucket.tokens -= 1
	return true
end

-- Served entirely from memory. Parallel arrays keep the payload small.
local function getPage(startRank, endRank)
	local snap = snapshot
	local total = snap.displayCount
	-- One row past the list is served so the client can close the gap when the local player falls out.
	local maxRank = math.min(#snap.rowsU, total + 1)

	local from = math.max(1, math.floor(startRank))
	local to = math.min(math.floor(endRank), from + PAGE_MAX_SPAN - 1, maxRank)

	local u, v, n = {}, {}, {}
	for r = from, to do
		local i = r - from + 1
		u[i], v[i], n[i] = snap.rowsU[r], snap.rowsV[r], snap.rowsN[r]
	end
	return { version = snap.seq, total = total, from = from, u = u, v = v, n = n }
end

-- nil = rejected (bad args / rate limited). The client treats nil as a failed
-- fetch and retries later, so a throttled chunk is never cached as empty.
local function onPageRequest(player, startRank, endRank)
	if type(startRank) ~= "number" or type(endRank) ~= "number" then return nil end
	if startRank ~= startRank or endRank ~= endRank then return nil end -- NaN
	if not allowPageRequest(player) then return nil end
	return getPage(startRank, endRank)
end

-- ==========================================
-- PLAYER LIFECYCLE
-- ==========================================
local function onDataLoaded(player)
	local trophies = PlayerData.Get(player, "Trophies") or 0
	if trophies > (PlayerData.Get(player, "PeakTrophies") or 0) then
		PlayerData.Set(player, "PeakTrophies", trophies)
	end
	if trophies > 0 then
		dirtyPlayers[player] = true -- one write per session indexes players the store doesn't know yet
	end
	RanksService.RefreshPlayerRank(player)
end

-- Any change to Trophies (matches, admin commands, products) goes through here.
local function onTrophiesChanged(player)
	if PlayerData.Get(player, "DataLoaded") ~= true then
		return
	end -- ignore the initial load
	local trophies = PlayerData.Get(player, "Trophies") or 0
	if trophies > (PlayerData.Get(player, "PeakTrophies") or 0) then
		PlayerData.Set(player, "PeakTrophies", trophies)
	end
	dirtyPlayers[player] = true
	RanksService.RefreshPlayerRank(player)
end

local function setupPlayer(player)
	if playerConnections[player] then return end
	playerConnections[player] = {
		PlayerData.Observe(player, "Trophies", function()
			onTrophiesChanged(player)
		end),
		PlayerData.Observe(player, "DataLoaded", function()
		if PlayerData.Get(player, "DataLoaded") == true then
			onDataLoaded(player)
		end
		end),
	}
	if PlayerData.Get(player, "DataLoaded") == true then
		onDataLoaded(player)
	end
end

-- Runs right before PlayerDataService's final save (pre-leave hook), so a
-- leaver penalty is part of the saved data.
local function onPlayerLeaving(player)
	-- NOTE: on a server shutdown, PlayerRemoving can fire before BindToClose
	-- sets isShuttingDown; in that rare order a mid-match player still gets the penalty.
	if not isShuttingDown and LeagueConfig.PenalizeLeavers and PlayerData.Get(player, "IsOnArena") then
		local state = ReplicatedValues.GetString(ReplicatedStorage, "MatchState")
		if state == "Starting" or state == "Playing" then
			local size = ReplicatedValues.GetNumber(ReplicatedStorage, "MatchSize") or 0
			RanksService.ApplyMatchResult(player, size, size, ReplicatedValues.GetNumber(ReplicatedStorage, "MatchId")) -- last place
		end
	end

	if PlayerData.Get(player, "DataLoaded") == true then
		-- Capture now: the Player object is going away.
		local userId = player.UserId
		local trophies = PlayerData.Get(player, "Trophies") or 0
		task.spawn(function()
			writeTrophies(userId, trophies)
			lastWritten[userId] = nil
		end)
	end
end

local function cleanupPlayer(player)
	local connections = playerConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	playerConnections[player] = nil
	dirtyPlayers[player] = nil -- the leave hook already wrote the final value
	pageBuckets[player] = nil
end

local function onClose()
	isShuttingDown = true
	local pending = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerData.Get(player, "DataLoaded") == true then
			pending += 1
			local userId, trophies = player.UserId, PlayerData.Get(player, "Trophies") or 0
			task.spawn(function()
				writeTrophies(userId, trophies)
				pending -= 1
			end)
		end
	end
	local waited = 0
	while pending > 0 and waited < SHUTDOWN_FLUSH_TIMEOUT do
		task.wait(0.1)
		waited += 0.1
	end
end

-- ==========================================
-- DEBUG (Studio only)
-- ==========================================

-- Fills the snapshot with fake data so the UI can be tested at scale without
-- DataStores. Example: RanksService.DebugInjectSnapshot(50000, 40000)
function RanksService.DebugInjectSnapshot(rowCount, tailCount)
	if not RunService:IsStudio() then
		warn("[RanksService] DebugInjectSnapshot is Studio-only")
		return
	end
	rowCount = math.max(1, math.floor(rowCount or 50000))
	tailCount = math.max(0, math.floor(tailCount or 0))

	local seq = snapshot.seq + 1
	local tailTop = if tailCount > 0 then 200 else 0
	local topValue = 8000

	local u, v, n = table.create(rowCount), table.create(rowCount), table.create(rowCount)
	for i = 1, rowCount do
		u[i] = i -- low user ids mostly exist, so thumbnails render
		v[i] = tailTop + 1 + math.floor((topValue - tailTop - 1) * (1 - i / (rowCount + 1)) ^ 2)
		n[i] = "Player" .. i
	end

	local metas = { { id = 1, kind = "rows", lo = v[rowCount], count = rowCount, attempt = 1 } }
	local segments = { { seq = seq, id = 1, u = u, v = v, n = n } }

	if tailCount > 0 then
		local hv, hc = {}, {}
		local base, extra = tailCount // tailTop, tailCount % tailTop
		for value = tailTop, 1, -1 do
			local count = base + (if tailTop - value < extra then 1 else 0)
			if count > 0 then
				hv[#hv + 1], hc[#hc + 1] = value, count
			end
		end
		metas[2] = { id = 2, kind = "count", hi = tailTop, lo = 1, count = tailCount, attempt = 1 }
		segments[2] = { seq = seq, id = 2, hv = hv, hc = hc }
	end

	debugLocked = true
	applySnapshot({ seq = seq, builtAt = os.time(), floor = 1, segments = metas }, segments)
	print(string.format("[RanksService] Injected debug snapshot: %d rows, %d tail entries", rowCount, tailCount))
end

-- Lets the real reader load manifests again after a debug injection.
function RanksService.DebugUnlock()
	debugLocked = false
end

-- ==========================================
-- INIT
-- ==========================================
function RanksService.Init()
	if initialized then return end
	initialized = true

	ReplicatedValues.Set(ReplicatedStorage, "RanksVersion", 0)
	ReplicatedValues.Set(ReplicatedStorage, "RanksTotal", 0)

	if type(PlayerDataService.AddPreLeaveHook) == "function" then
		PlayerDataService.AddPreLeaveHook(onPlayerLeaving)
	else
		warn("[RanksService] PlayerDataService.AddPreLeaveHook missing: leaver penalties may not be saved.")
		Players.PlayerRemoving:Connect(onPlayerLeaving)
	end

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	RanksPageFunction.OnServerInvoke = onPageRequest

	task.spawn(subscribeCommits)

	-- Reader: load on boot, then poll (commits are also pushed via MessagingService).
	task.spawn(function()
		RanksService.LoadSnapshot()
		while true do
			task.wait(Config.ReadInterval + math.random() * READ_JITTER)
			RanksService.LoadSnapshot()
		end
	end)

	-- Ordered-store flush.
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			flushDirty()
		end
	end)

	game:BindToClose(onClose)
end

return RanksService
