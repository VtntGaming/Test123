--!optimize 2
local RanksBuildService = {}
local initialized = false

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local LeagueConfig = require(SharedModules:WaitForChild("LeagueConfig"))

local RanksService = require(script.Parent:WaitForChild("RanksService"))

-- ==========================================
-- CONFIG
-- ==========================================
local Config = LeagueConfig.Leaderboard

local DISPLAY_DEPTH = Config.DisplayDepth or 10000
local RANK_DEPTH = math.max(Config.RankDepth or 100000, DISPLAY_DEPTH)
local DISPLAY_MARGIN = Config.DisplayMargin or 0.1
local PAGE_SIZE = 100                                         -- GetSortedAsync max page size
local ROWS_SHARD_SIZE = math.max(PAGE_SIZE, Config.RowsShardSize or 1000)
local COUNT_SHARD_SIZE = math.max(PAGE_SIZE, Config.CountShardSize or 5000)
local CAP_MULTIPLIER = Config.ShardCapMultiplier or 2         -- a planned shard this much over size splits itself
local BUILD_INTERVAL = Config.BuildInterval or 15 * 60        -- from last commit to next build
local BUILD_TIMEOUT = Config.BuildTimeout or 45 * 60          -- a Running build older than this is abandoned
local JOB_LEASE = Config.JobLease or 5 * 60                   -- queue invisibility + claim lease
local MIN_LIST_BUDGET = Config.MinListBudget or 10            -- only take a job when ~this many pages are affordable
local STORE_NAMES = Config.StoreNames ~= false
local NAME_FIELD = "DisplayName"                              -- or "Username"

local STATE_CHECK_INTERVAL = 60       -- election / active-build check, per server
local STATE_CHECK_JITTER = 30
local INITIAL_CHECK_DELAY = 20        -- let RanksService load the current snapshot first
local WORKER_IDLE_WAIT = 5            -- between empty queue reads while a build is active
local BUDGET_POLL = 2
local LEASE_RENEW_INTERVAL = 60       -- long scans on low-budget servers keep their claim
local FAILED_RETRY_DELAY = 5 * 60     -- a failed build is retried after this, not a full interval
local ADD_RETRY = 3
local NAME_BATCH = 100                -- ids per UserService call
local NAME_RETRY = 3
local NAME_DELAY = 1                  -- seconds between UserService calls
local NAME_CAP_PER_JOB = 1000         -- max new names resolved per job (the rest fill next build)
local DELETE_SPACING = 0.05
local RECORD_SIZE_WARN = 28 * 1024    -- MemoryStore values are capped at 32 KB

local STATE_KEY = "State"
local STATE_EXPIRATION = 45 * 24 * 3600 -- MemoryStore maximum; refreshed every build
local RECORD_EXPIRATION = BUILD_TIMEOUT * 2

local SUFFIX = RanksService.STORE_SUFFIX -- "_Studio" in Studio, like RanksService
local TOPIC_BUILD = "RanksBuild" .. SUFFIX
local VERBOSE = RunService:IsStudio() or Config.VerboseBuildLogs == true
local DEBUG_WORKERS = if RunService:IsStudio() then (Config.DebugWorkers or 0) else 0

-- ==========================================
-- STORES
-- ==========================================
local TrophiesStore = RanksService.TrophiesStore
local SnapshotStore = RanksService.SnapshotStore
local BuildMap = MemoryStoreService:GetHashMap(Config.BuildMapName .. SUFFIX)
local JobQueue = MemoryStoreService:GetQueue(Config.JobQueueName .. SUFFIX, JOB_LEASE)

-- ==========================================
-- STATE
-- ==========================================
local WORKER_ID = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)
local activeSeq = nil -- build this server is currently helping with (nil = idle)

-- ==========================================
-- HELPERS
-- ==========================================
local function log(message, ...)
	if VERBOSE then print("[RanksBuildService] " .. string.format(message, ...)) end
end

local function recordKey(seq)
	return "Build_" .. seq
end

local function shardSize(kind)
	return if kind == "rows" then ROWS_SHARD_SIZE else COUNT_SHARD_SIZE
end

-- Cap for a chain shard: stop near the end of its region instead of overshooting by a full shard.
local function chainCap(kind, est, rowsTarget)
	local limit = if kind == "rows" then rowsTarget else RANK_DEPTH
	return math.clamp(limit - est, PAGE_SIZE, shardSize(kind))
end

local function waitForBudget(requestType)
	while DataStoreService:GetRequestBudgetForRequestType(requestType) < 1 do
		task.wait(BUDGET_POLL)
	end
end

local function listBudget()
	return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.OrderedList)
end

local function publish(topic, seq)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(topic, seq)
	end)
	if not ok then log("Publish %s failed: %s", topic, tostring(err)) end
end

local function segmentKeys(manifest)
	local keys = {}
	if type(manifest) == "table" and type(manifest.segments) == "table" then
		for _, s in ipairs(manifest.segments) do
			table.insert(keys, RanksService.SegmentKey(manifest.seq, s.id, s.attempt))
		end
	end
	return keys
end

local function deleteKeys(keys)
	if type(keys) ~= "table" then return end
	for _, key in ipairs(keys) do
		waitForBudget(Enum.DataStoreRequestType.StandardRemove)
		pcall(function()
			SnapshotStore:RemoveAsync(key)
		end)
		task.wait(DELETE_SPACING)
	end
end

-- ==========================================
-- QUEUE
-- ==========================================
local function enqueueJob(seq, id)
	for attempt = 1, ADD_RETRY do
		local ok, err = pcall(function()
			JobQueue:AddAsync({ seq = seq, id = id }, BUILD_TIMEOUT)
		end)
		if ok then return true end
		warn(string.format("[RanksBuildService] Enqueue %d/%d failed (attempt %d): %s", seq, id, attempt, tostring(err)))
		task.wait(attempt)
	end
	return false -- the shard stays Queued; the build times out and is retried
end

local function removeJob(readId)
	if not readId then return end
	pcall(function()
		JobQueue:RemoveAsync(readId)
	end)
end

-- ==========================================
-- BUILD STATE (MemoryStore HashMap)
-- ==========================================

-- Due when there's no state, a Running build timed out, or the interval since the last commit passed.
local function isDue(state, now)
	if type(state) ~= "table" then return true end
	if state.phase == "Running" then
		return now - (state.startedAt or 0) >= BUILD_TIMEOUT
	end
	return now - (state.committedAt or 0) >= BUILD_INTERVAL
end

-- Atomic election. Returns the new state if THIS server won.
local function tryStartBuild()
	local now = os.time()
	local snapshotSeq = RanksService.GetSnapshotSeq()
	local won = nil
	local ok, err = pcall(function()
		won = BuildMap:UpdateAsync(STATE_KEY, function(old)
			if not isDue(old, now) then return nil end
			old = old or {}
			return {
				seq = math.max(old.seq or 0, snapshotSeq) + 1,
				phase = "Running",
				startedAt = now,
				owner = WORKER_ID,
				committedAt = old.committedAt,
			}
		end, STATE_EXPIRATION)
	end)
	if not ok then
		log("Election failed: %s", tostring(err))
		return nil
	end
	if type(won) == "table" and won.owner == WORKER_ID and won.startedAt == now then return won end
	return nil
end

-- Marks the build finished. A failed build may be retried after FAILED_RETRY_DELAY.
-- liveSeq: manifest seq seen at commit time, so the next build is guaranteed newer.
local function finishState(seq, committed, liveSeq)
	local now = os.time()
	pcall(function()
		BuildMap:UpdateAsync(STATE_KEY, function(old)
			old = old or {}
			if (old.seq or 0) > seq then return nil end -- a newer build owns the state now
			return {
				seq = math.max(old.seq or 0, seq, liveSeq or 0),
				phase = "Idle",
				startedAt = old.startedAt,
				committedAt = if committed then now else now - BUILD_INTERVAL + FAILED_RETRY_DELAY,
			}
		end, STATE_EXPIRATION)
	end)
end

-- ==========================================
-- PLANNING (coordinator)
-- ==========================================
local function newShard(id, hi, lo, kind, est, cap, chain)
	return { id = id, hi = hi, lo = lo, kind = kind, est = est, cap = cap, chain = chain, status = "Queued", attempt = 0 }
end

-- Cuts the board into shards of ~equal row counts using the previous snapshot as quantiles.
-- Shards are contiguous trophy ranges, top-down: [c1, inf), [c2, c1-1], ..., then a final
-- "chain" shard that scans the rest and splits itself until RankDepth.
-- With no previous snapshot, the plan is a single chain shard (first build is sequential,
-- but each link can still run on a different server).
local function planShards()
	local rowsTarget = math.ceil(DISPLAY_DEPTH * (1 + DISPLAY_MARGIN))
	local shards = {}
	local rank, hi = 0, nil

	if RanksService.GetSnapshotSeq() > 0 then
		while rank < RANK_DEPTH do
			local kind = if rank < rowsTarget then "rows" else "count"
			local size = shardSize(kind)
			local cutRank = math.min(rank + size, RANK_DEPTH)
			local cutValue = RanksService.ValueAtRank(cutRank)
			if not cutValue or cutValue < 1 then break end -- past the previous scan
			if hi == nil or cutValue <= hi then -- skip cuts inside one huge tie group
				table.insert(shards, newShard(#shards + 1, hi, cutValue, kind, rank, size * CAP_MULTIPLIER, false))
				hi = cutValue - 1
			end
			rank = cutRank
			if hi and hi < 1 then break end
		end
	end

	if hi == nil or hi >= 1 then
		local kind = if rank < rowsTarget then "rows" else "count"
		table.insert(shards, newShard(#shards + 1, hi, 1, kind, rank, chainCap(kind, rank, rowsTarget), true))
	end
	return shards, rowsTarget
end

local function startBuild(state)
	RanksService.LoadSnapshot() -- plan from the newest manifest (one read when unchanged)
	local shards, rowsTarget = planShards()
	local record = { seq = state.seq, nextId = #shards + 1, rowsTarget = rowsTarget, shards = shards }

	local okSize, json = pcall(function() return HttpService:JSONEncode(record) end)
	if okSize and #json > RECORD_SIZE_WARN then
		warn(string.format("[RanksBuildService] Build record is %d bytes (MemoryStore cap 32 KB): raise RowsShardSize/CountShardSize", #json))
	end

	BuildMap:SetAsync(recordKey(state.seq), record, RECORD_EXPIRATION)
	local queued = 0
	for _, shard in ipairs(shards) do
		if enqueueJob(state.seq, shard.id) then queued += 1 end
	end
	activeSeq = math.max(activeSeq or 0, state.seq)
	publish(TOPIC_BUILD, state.seq)
	log("Build %d started: %d shards (%d queued), planned from snapshot %d", state.seq, #shards, queued, RanksService.GetSnapshotSeq())
end

local function checkState()
	local ok, state = pcall(function()
		return BuildMap:GetAsync(STATE_KEY)
	end)
	if not ok then
		log("State read failed: %s", tostring(state))
		return
	end

	local now = os.time()
	if not isDue(state, now) then
		if type(state) == "table" and state.phase == "Running" then
			activeSeq = math.max(activeSeq or 0, state.seq or 0)
		else
			activeSeq = nil
		end
		return
	end

	activeSeq = nil
	local won = tryStartBuild()
	if won then
		local okStart, err = pcall(startBuild, won)
		if not okStart then
			warn("[RanksBuildService] Starting build " .. won.seq .. " failed: " .. tostring(err))
			finishState(won.seq, false)
		end
	end
end

-- ==========================================
-- COMMIT (last worker to finish)
-- ==========================================
local function validateCoverage(shards)
	if #shards == 0 then return false, "no shards" end
	if shards[1].hi ~= nil then return false, "top shard is not open-ended" end
	local seenCount = false
	for i, s in ipairs(shards) do
		if s.status ~= "Done" or type(s.count) ~= "number" or type(s.attempt) ~= "number" then
			return false, "shard " .. tostring(s.id) .. " is not done"
		end
		if i > 1 and s.hi ~= shards[i - 1].lo - 1 then
			return false, string.format("gap/overlap between shards %d and %d", shards[i - 1].id, s.id)
		end
		if s.kind == "count" then
			seenCount = true
		elseif seenCount then
			return false, "rows shard " .. s.id .. " below a count shard"
		end
	end
	if shards[#shards].lo < 1 then return false, "floor below 1" end
	return true, nil
end

local function commitBuild(seq)
	local rec = nil
	for attempt = 1, 3 do
		local okR, value = pcall(function()
			return BuildMap:GetAsync(recordKey(seq))
		end)
		if okR then
			rec = value
			break
		end
		task.wait(attempt * 2)
	end
	if type(rec) ~= "table" or type(rec.shards) ~= "table" then
		warn("[RanksBuildService] Commit " .. seq .. ": build record unavailable; the build will time out and rerun")
		return
	end

	local shards = table.clone(rec.shards)
	table.sort(shards, function(a, b)
		return (a.hi or math.huge) > (b.hi or math.huge)
	end)
	local valid, reason = validateCoverage(shards)
	if not valid then
		warn("[RanksBuildService] Build " .. seq .. " rejected: " .. reason)
		finishState(seq, false)
		return
	end

	local segments, scanned = table.create(#shards), 0
	for i, s in ipairs(shards) do
		segments[i] = { id = s.id, attempt = s.attempt, kind = s.kind, hi = s.hi, lo = s.lo, count = s.count }
		scanned += s.count
	end
	local manifest = {
		seq = seq,
		builtAt = os.time(),
		floor = shards[#shards].lo,
		scanned = scanned,
		segments = segments,
	}

	local committed, liveSeq, toDelete = false, 0, nil
	waitForBudget(Enum.DataStoreRequestType.StandardWrite)
	local okM, errM = pcall(function()
		SnapshotStore:UpdateAsync(RanksService.MANIFEST_KEY, function(old)
			committed, toDelete = false, nil
			liveSeq = if type(old) == "table" then (tonumber(old.seq) or 0) else 0
			if liveSeq >= seq then return nil end -- never go backwards (late commit of an abandoned build)
			-- The live build's segments are retired now and deleted by the NEXT commit,
			-- so no reader still loading them loses them.
			manifest.retired = if type(old) == "table" then segmentKeys(old) else nil
			toDelete = if type(old) == "table" then old.retired else nil
			committed = true
			return manifest
		end)
	end)
	if not okM then
		warn("[RanksBuildService] Manifest write failed for build " .. seq .. ": " .. tostring(errM))
		finishState(seq, false)
		return
	end
	if not committed then
		warn(string.format("[RanksBuildService] Build %d is not newer than the live manifest (%d); skipped", seq, liveSeq))
		finishState(seq, false, liveSeq)
		return
	end

	finishState(seq, true)
	publish(RanksService.TOPIC_COMMITTED, seq)
	RanksService.LoadSnapshot()
	log("Build %d committed: %d segments, %d entries counted, floor %d", seq, #segments, scanned, manifest.floor)

	deleteKeys(toDelete)
	pcall(function()
		BuildMap:RemoveAsync(recordKey(seq))
	end)
end

-- ==========================================
-- WORKER
-- ==========================================

-- Claims a shard with a lease. Returns ("claimed", claim), ("gone", nil) or (nil, nil) if
-- another live worker holds it (or MemoryStore failed): then the queue item just reappears.
local function claimShard(workerId, job)
	local now = os.time()
	local outcome, claim = nil, nil
	local ok, err = pcall(function()
		BuildMap:UpdateAsync(recordKey(job.seq), function(rec)
			outcome, claim = nil, nil
			local s = type(rec) == "table" and type(rec.shards) == "table" and rec.shards[job.id]
			if not s or s.status == "Done" then
				outcome = "gone"
				return nil
			end
			if s.status == "Running" and (s.leaseUntil or 0) > now and s.owner ~= workerId then
				return nil
			end
			s.status, s.owner, s.leaseUntil = "Running", workerId, now + JOB_LEASE
			s.attempt = (s.attempt or 0) + 1
			outcome = "claimed"
			claim = { spec = table.clone(s), attempt = s.attempt, rowsTarget = rec.rowsTarget }
			return rec
		end, RECORD_EXPIRATION)
	end)
	if not ok then
		log("Claim %d/%d failed: %s", job.seq, job.id, tostring(err))
		return nil, nil
	end
	return outcome, claim
end

-- Extends our lease. False only when someone else provably owns the shard now.
local function renewLease(workerId, seq, id, attempt)
	local kept = false
	local ok = pcall(function()
		BuildMap:UpdateAsync(recordKey(seq), function(rec)
			kept = false
			local s = type(rec) == "table" and type(rec.shards) == "table" and rec.shards[id]
			if not s or s.status ~= "Running" or s.owner ~= workerId or s.attempt ~= attempt then return nil end
			s.leaseUntil = os.time() + JOB_LEASE
			kept = true
			return rec
		end, RECORD_EXPIRATION)
	end)
	return (not ok) or kept -- a failed call isn't proof we lost it
end

-- Scans [spec.lo, spec.hi] top-down. If the shard outgrows spec.cap it stops on a value
-- boundary (a tie group never spans two shards) and returns cut: values <= cut are left
-- for a continuation shard.
local function scanShard(spec, keepLease)
	local u, v = {}, {}
	waitForBudget(Enum.DataStoreRequestType.OrderedList)
	local pages = TrophiesStore:GetSortedAsync(false, PAGE_SIZE, spec.lo, spec.hi)
	while true do
		for _, entry in ipairs(pages:GetCurrentPage()) do
			local userId, value = tonumber(entry.key), tonumber(entry.value)
			if userId and userId > 0 and value then
				u[#u + 1], v[#v + 1] = userId, value
			end
		end
		if #v >= spec.cap and v[#v] ~= v[1] then
			local cut = v[#v]
			while v[#v] == cut do
				u[#u], v[#v] = nil, nil
			end
			return u, v, cut
		end
		if pages.IsFinished then return u, v, nil end
		keepLease()
		waitForBudget(Enum.DataStoreRequestType.OrderedList)
		pages:AdvanceToNextPageAsync()
	end
end

local function fetchUserInfos(ids)
	local delay = NAME_DELAY
	for attempt = 1, NAME_RETRY do
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(ids)
		end)
		if ok and type(infos) == "table" then return infos end
		log("Name batch attempt %d failed: %s", attempt, tostring(infos))
		task.wait(delay)
		delay *= 2
	end
	return nil
end

-- Names carried forward from the loaded snapshot, then online players, then UserService
-- (throttled and capped per job; unresolved names are retried by the next build).
local function resolveNames(u, keepLease)
	local n = table.create(#u, "")
	local missing, indexOf = {}, {}
	for i, userId in ipairs(u) do
		local name = RanksService.GetCachedName(userId)
		if not name or name == "" then
			local player = Players:GetPlayerByUserId(userId)
			name = player and player.DisplayName
		end
		if name and name ~= "" then
			n[i] = name
		else
			table.insert(missing, userId)
			indexOf[userId] = i
		end
	end

	local resolved = 0
	for start = 1, #missing, NAME_BATCH do
		if resolved >= NAME_CAP_PER_JOB then break end
		local batch = table.move(missing, start, math.min(start + NAME_BATCH - 1, #missing), 1, {})
		local infos = fetchUserInfos(batch)
		if infos then
			for _, info in ipairs(infos) do
				local i = indexOf[info.Id]
				if i then
					n[i] = info[NAME_FIELD] or info.Username or ""
					resolved += 1
				end
			end
		end
		keepLease()
		task.wait(NAME_DELAY)
	end
	return n
end

local function histogram(values)
	local hv, hc = {}, {}
	for _, value in ipairs(values) do
		if hv[#hv] == value then
			hc[#hc] += 1
		else
			hv[#hv + 1], hc[#hc + 1] = value, 1
		end
	end
	return hv, hc
end

local function runShard(workerId, seq, spec, attempt, rowsTarget)
	local lastRenew = os.clock()
	local function keepLease()
		if os.clock() - lastRenew < LEASE_RENEW_INTERVAL then return end
		lastRenew = os.clock()
		if not renewLease(workerId, seq, spec.id, attempt) then error("lease lost", 0) end
	end

	local u, v, cut = scanShard(spec, keepLease)
	local result = { count = #v, lo = spec.lo, continuation = nil }

	if cut then
		result.lo = cut + 1
		local nextEst = (spec.est or 0) + #v
		local chainDone = spec.chain and nextEst >= RANK_DEPTH -- this becomes the floor
		if not chainDone then
			local kind = spec.kind
			if spec.chain and kind == "rows" and nextEst >= rowsTarget then kind = "count" end
			result.continuation = {
				hi = cut,
				lo = spec.lo,
				kind = kind,
				est = nextEst,
				chain = spec.chain,
				cap = if spec.chain then chainCap(kind, nextEst, rowsTarget) else shardSize(kind) * CAP_MULTIPLIER,
			}
		end
	end

	local payload
	if spec.kind == "rows" then
		payload = { seq = seq, id = spec.id, u = u, v = v }
		if STORE_NAMES then payload.n = resolveNames(u, keepLease) end
	else
		local hv, hc = histogram(v)
		payload = { seq = seq, id = spec.id, hv = hv, hc = hc }
	end

	keepLease()
	waitForBudget(Enum.DataStoreRequestType.StandardWrite)
	-- The attempt is part of the key: a slow duplicate can never overwrite the winning attempt.
	SnapshotStore:SetAsync(RanksService.SegmentKey(seq, spec.id, attempt), payload)
	return result
end

-- Marks the shard Done (if we still own it), registers any continuation, and elects the
-- committer: the worker whose update completes the last shard.
local function finishShard(workerId, job, attempt, result)
	local accepted, commit, continuation = false, false, nil
	local ok, err = pcall(function()
		BuildMap:UpdateAsync(recordKey(job.seq), function(rec)
			accepted, commit, continuation = false, false, nil
			local s = type(rec) == "table" and type(rec.shards) == "table" and rec.shards[job.id]
			if not s or s.status ~= "Running" or s.owner ~= workerId or s.attempt ~= attempt then return nil end

			s.status, s.count, s.lo = "Done", result.count, result.lo
			s.owner, s.leaseUntil = nil, nil
			if result.continuation then
				local c = table.clone(result.continuation)
				c.id, c.status, c.attempt = rec.nextId, "Queued", 0
				rec.shards[rec.nextId] = c
				rec.nextId += 1
				continuation = c
			end

			local allDone = true
			for _, other in ipairs(rec.shards) do
				if other.status ~= "Done" then
					allDone = false
					break
				end
			end
			if allDone and not rec.committer then
				rec.committer = workerId
				commit = true
			end
			accepted = true
			return rec
		end, RECORD_EXPIRATION)
	end)
	if not ok then
		log("Finish %d/%d failed: %s", job.seq, job.id, tostring(err))
		return false, false, nil
	end
	return accepted, commit, continuation
end

local function processJob(workerId, job, readId)
	if type(job) ~= "table" or type(job.seq) ~= "number" or type(job.id) ~= "number" then
		removeJob(readId)
		return
	end
	if activeSeq and job.seq < activeSeq then
		removeJob(readId) -- left over from an abandoned build
		return
	end

	local outcome, claim = claimShard(workerId, job)
	if outcome == "gone" then
		removeJob(readId)
		return
	end
	if outcome ~= "claimed" then return end

	local ok, result = pcall(runShard, workerId, job.seq, claim.spec, claim.attempt, claim.rowsTarget)
	if not ok then
		-- The lease expires and the queue item reappears for another worker.
		warn(string.format("[RanksBuildService] Shard %d/%d attempt %d failed: %s", job.seq, job.id, claim.attempt, tostring(result)))
		return
	end

	local accepted, commit, continuation = finishShard(workerId, job, claim.attempt, result)
	if not accepted then return end -- our lease was taken over; the other attempt wins

	if continuation then enqueueJob(job.seq, continuation.id) end
	removeJob(readId)
	log("Shard %d/%d (%s) done by %s: %d rows%s", job.seq, job.id, claim.spec.kind, workerId,
		result.count, if continuation then (" -> split, continuation " .. continuation.id) else "")

	if commit then commitBuild(job.seq) end
end

local function workerLoop(workerId)
	while true do
		if not activeSeq then
			task.wait(1)
			continue
		end
		if listBudget() < MIN_LIST_BUDGET then
			task.wait(BUDGET_POLL) -- busy servers have more budget and naturally take more jobs
			continue
		end

		local ok, items, readId = pcall(function()
			return JobQueue:ReadAsync(1, false, 0)
		end)
		if not ok then
			log("Queue read failed: %s", tostring(items))
			task.wait(WORKER_IDLE_WAIT)
			continue
		end
		if type(items) ~= "table" or #items == 0 then
			task.wait(WORKER_IDLE_WAIT)
			continue
		end

		local okJob, err = pcall(processJob, workerId, items[1], readId)
		if not okJob then
			warn("[RanksBuildService] Job error: " .. tostring(err))
		end
	end
end

local function subscribeBuildSignals()
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(TOPIC_BUILD, function(message)
			local seq = tonumber(message.Data)
			if seq then activeSeq = math.max(activeSeq or 0, seq) end
		end)
	end)
	if not ok then log("Build signal subscription failed (state polling still active): %s", tostring(err)) end
end

-- ==========================================
-- PUBLIC
-- ==========================================

-- Starts a new build at the next state check (admin / testing). A running build is abandoned.
function RanksBuildService.ForceBuild()
	pcall(function()
		BuildMap:UpdateAsync(STATE_KEY, function(old)
			old = old or {}
			if old.phase == "Running" then old.startedAt = 0 else old.committedAt = 0 end
			return old
		end, STATE_EXPIRATION)
	end)
	task.spawn(checkState)
end

function RanksBuildService.GetActiveSeq()
	return activeSeq
end

-- ==========================================
-- INIT
-- ==========================================
function RanksBuildService.Init()
	if initialized then return end
	initialized = true

	task.spawn(subscribeBuildSignals)

	-- Election + active-build discovery (every server).
	task.spawn(function()
		task.wait(INITIAL_CHECK_DELAY)
		while true do
			checkState()
			task.wait(STATE_CHECK_INTERVAL + math.random() * STATE_CHECK_JITTER)
		end
	end)

	-- Worker (every server). In Studio, DebugWorkers adds extra workers with their own ids
	-- so claims, leases, splits and commits can be exercised from a single server.
	task.spawn(workerLoop, WORKER_ID)
	for i = 1, DEBUG_WORKERS do
		task.spawn(workerLoop, WORKER_ID .. "#" .. i)
	end
end

return RanksBuildService