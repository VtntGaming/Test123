-- Owns player profile loading, session-safe saves and developer-requested profile resets.
local PlayerDataService = {}

-- ==========================================
-- SERVICES
-- ==========================================
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ChestInventory =
	require(game:GetService("ReplicatedStorage"):WaitForChild("SharedModules"):WaitForChild("ChestInventory"))

local PlayerDataStore = DataStoreService:GetDataStore("GameData_V1")
local AnalyticsService = require(game:GetService("ServerScriptService").Services.AnalyticsService) -- Adjust path if needed
-- Configure these before starting a server. Disabling bypasses cross-server locking,
-- including owner checks; local load/save coordination remains enabled.
-- MemoryStore errors/timeouts also bypass protection for the affected session.
local SESSION_LOCK_ENABLED = true
local SESSION_HEARTBEAT_SECONDS = 5
local SESSION_TIMEOUT_SECONDS = 15
local SESSION_REQUEST_SECONDS = 5
local AUTOSAVE_SECONDS = 30
local SHUTDOWN_SECONDS = 25
assert(SESSION_TIMEOUT_SECONDS > SESSION_HEARTBEAT_SECONDS + SESSION_REQUEST_SECONDS)
local SessionMap = if SESSION_LOCK_ENABLED
	then game:GetService("MemoryStoreService"):GetHashMap("GameData_V1_Sessions")
	else nil

-- ==========================================
-- STATE
-- ==========================================
local loadedPlayers = {}
local loadingPlayers = {}
local initialized = false
local preLeaveHooks = {}
--#region Save coordination and session ownership
-- Profile maps are server-local and keyed by numeric UserId. Finalizations use
-- Player instances so concurrent exit callbacks can await the same operation.
-- savingPlayers[userId] is the token owning the local write lock.
local savingPlayers = {}
-- closingPlayers[userId] = true once a final save begins; ongoing saves must stop.
local closingPlayers = {}
-- sessionOwners[userId] = owner token acquired when this player profile was loaded.
-- MemoryStore owns the short lease. DataStore owner tokens fence protected saves.
-- Fail-open sessions bypass both checks, accepting overlapping-session write risks.
local sessionOwners = {}
local sessionSequence = 0
local sessionId = if type(game.JobId) == "string" and game.JobId ~= ""
	then game.JobId
	else HttpService:GenerateGUID(false)
local privateShop = {}
local privateChests = {}
local writeSequences = {}
local sessionLocks = {}
local profilePlayers = {}
local finalizations = {}
local resettingPlayers = {}
local resetAllowanceGenerations = {}
local nextAutoSaves = {}
local shuttingDown = false
local shutdownDeadline = nil
--#endregion

-- ==========================================
-- DEFAULT SCHEMA
-- ==========================================
PlayerDataService.SessionAttributes = {
	IsOnArena = false,
	Lives = 3,
	IsAFK = RunService:IsStudio(),

	-- Stats da mostrare sul MatchSummary
	MatchKills = 0,
	MatchHits = 0,
	MatchStuds = 0,

	GlobalRank = 0, -- 0 = unranked / snapshot not loaded yet
	GlobalRankOverflow = false, -- deeper than the scanned depth → UI shows "100,000+"
	SnapshotRank = 0, -- player's row index in the loaded snapshot (0 = not in list)
	MatchId = 0, -- match this player was teleported into
	TrophyMatchId = 0, -- last match whose trophy result was applied (idempotency guard)
	MatchTrophyDelta = 0, -- +/- of the last match (popup / future MatchSummary)
}

PlayerDataService.DefaultAttributes = {
	-- Progression
	Level = 1,
	Experience = 0,
	-- Valute
	BagScore = 0,
	Coins = 0,
	Coins_Day = 0,
	Coins_Week = 0,
	Coins_Month = 0,
	-- Stats
	Kills = 0,
	Kills_Day = 0,
	Kills_Week = 0,
	Kills_Month = 0,
	Wins = 0,
	Wins_Day = 0,
	Wins_Week = 0,
	Wins_Month = 0,
	Deaths = 0,
	-- Ranking
	--RankPoints = 0,
	Trophies = 0,
	PeakTrophies = 0,
	-- Nuove stats aggiunte
	GamesPlayed = 0,
	PreferredWeapon = "Slap",
	PreferredAbility = "Dash",
	-- Varie
	Playtime = 0,
	LastDay = "",
	LastWeek = "",
	LastMonth = "",
	-- Inventario
	EquippedWeaponName = "Slap",
	EquippedBaseWeapon = "Slap",
	OwnedWeapons = "Slap,Bat,Chicken,Hammer,Stick",
	EquippedAbility = "Dash",
	OwnedAbilities = "Dash",
	OwnedChests = "{}",
	CarriedChests = "",
	RedeemedCodes = "",

	-- Social
	EarlyRewardClaimed = false,
	GroupRewardClaimed = false,

	-- Tutorial (TutorialService): true once the new-player tutorial was finished or skipped.
	TutorialCompleted = false,

	-- Daily rewards (DailyRewardService): days claimed in the current cycle (0..14) and the os.time() of the last claim.
	DailyRewardDay = 0,
	DailyRewardLastClaim = 0,

	-- Has x2 coin
	Has2xCoins = false,
	Has2xCoinsBuff = false,
	x2CoinBuffExpiredOn = 0,
	x2CoinBuffOfflineTimestamp = -1, -- to compensate when offline

	-- Robux shop
	FirstTimeCoinPack = "",
	SimpleWeaponPackPurchases = "{}", -- RotationKey + Counts; saved by the ordinary profile lifecycle.
	OneTimePasses = "", -- Comma-separated config keys of claimed passes.
	OneTimePacks = "", -- Comma-separated pack keys, LimitedItem rotation keys and LimitedItemReceipt:<PurchaseId>.
	ProcessedGiftReceipts = "{}", -- Saved atomically with gift rewards; JSON receipt-ID dictionary.
	PurchaseAllowanceGeneration = "", -- Empty preserves legacy quotas; explicit reset creates a fresh allowance namespace.
	-- [PurchaseId] = { ProductId, Group, Weapon, Claimed }; preserves pending reveals/replays.
	-- Purchase histories are loaded into __Shop, never replicated as attributes.

	DailyWins = 0,
	DailyWinsTimestamp = 0, -- Start of the current UTC calendar day.
	DailyWinsClaimed = false, -- Saved together with the granted chest inventory.
}

PlayerDataService.DefaultSettings = {
	Setting_SFXVolume = 50,
	Setting_MusicVolume = 50,
	Setting_PerformanceMode = false,
	Setting_AutoAim = true,
	Setting_InstantChestGamepass = true,
	--IsAFK = false,
	Hardware = "Mobile",
}

-- ==========================================
-- LEVEL & EXP LOGIC (NUOVO)
-- ==========================================

-- Calcola quanti EXP servono per passare al livello SUCCESSIVO
-- English: Calculate how much EXP is needed to reach the NEXT level.
function PlayerDataService.GetExpRequirement(currentLevel)
	local baseExp = 10
	local incrementPerLevel = 2
	return baseExp + ((currentLevel - 1) * incrementPerLevel)
end

-- Assegna EXP e calcola i level up automatici
function PlayerDataService.AddExperience(player, amount)
	if type(amount) ~= "number" or amount <= 0 then
		return
	end

	local currentLevel = player:GetAttribute("Level") or 1
	local currentExp = player:GetAttribute("Experience") or 0

	currentExp += amount

	local requiredExp = PlayerDataService.GetExpRequirement(currentLevel)

	-- Continua a salire di livello finché abbiamo abbastanza exp
	-- English: Keep leveling up as long as there is enough experience.
	-- (Utile nel caso in cui un player guadagni, ad esempio, 100 EXP in un colpo solo)
	-- English: Useful if a player earns, for example, 100 EXP at once.
	local leveledUp = false
	while currentExp >= requiredExp do
		currentExp -= requiredExp
		currentLevel += 1
		leveledUp = true
		requiredExp = PlayerDataService.GetExpRequirement(currentLevel)
	end

	-- Aggiorniamo gli attributi del player
	-- English: Update the player's attributes.
	player:SetAttribute("Level", currentLevel)
	player:SetAttribute("Experience", currentExp)

	-- Se è salito di livello, in futuro potrai aggiungere qui un suono, un VFX o un evento!
	-- English: If the player leveled up, a sound, VFX, or event can be added here in the future.
	if leveledUp then
		print(player.Name .. " è salito al livello " .. currentLevel .. "!")
	end
end

-- ==========================================
-- UTILS
-- ==========================================
local function isDynamicKey(key)
	return string.sub(key, 1, 5) == "UseW_" or string.sub(key, 1, 5) == "UseA_" or string.sub(key, 1, 6) == "Owned_"
end

local function getPlayerKey(player)
	return "Player_" .. player.UserId
end

-- A timed-out native request can still finish. Its transform must also check the
-- operation identity/deadline; bounding the caller's wait does not cancel I/O.
local function awaitResult(seconds, callback, shouldStop)
	local result
	local deadline = os.clock() + seconds
	task.spawn(function()
		result = table.pack(pcall(callback))
	end)
	while result == nil and os.clock() < deadline and (not shouldStop or not shouldStop()) do
		task.wait(0.05)
	end
	if result == nil then
		return false, "TimedOut"
	end
	return table.unpack(result, 1, result.n)
end

local function loadValid(player, token)
	return not shuttingDown
		and player.Parent == Players
		and loadingPlayers[player.UserId] == token
		and os.clock() < token.Deadline
end

-- Fail-open is sticky until this player leaves. Re-enabling checks halfway through
-- an unprotected session could revoke it after another server was allowed to load.
local function bypassSession(state)
	if state.Bypassed or not state.Active then
		return
	end
	state.Bypassed = true
	warn("[PlayerDataService] MemoryStore unavailable; session protection disabled for this player until they leave.")
end

local function sessionValid(userId, owner)
	if not SESSION_LOCK_ENABLED then
		return true
	end
	local state = sessionLocks[userId]
	if not state or state.Owner ~= owner or not state.Active then
		return false
	end
	if not state.Bypassed and os.clock() >= state.Deadline then
		bypassSession(state)
	end
	return true
end

local function protectionEnabled(userId, owner)
	return SESSION_LOCK_ENABLED and sessionValid(userId, owner) and not sessionLocks[userId].Bypassed
end

local function loseSession(player, state)
	if not state or sessionLocks[player.UserId] ~= state or not state.Active or state.Bypassed then
		return
	end
	state.Active = false
	player:SetAttribute("DataLoaded", false)
	if player.Parent == Players then
		player:Kick("Your data session moved to another server. Please rejoin.")
	end
end

local function renewSession(player, state)
	state.Busy = true
	local started = os.clock()
	local deadline = math.min(started + SESSION_REQUEST_SECONDS, state.Deadline)
	local occupied = false
	local success, result = awaitResult(math.max(0, deadline - started), function()
		return SessionMap:UpdateAsync(getPlayerKey(player), function(current)
			if not protectionEnabled(player.UserId, state.Owner) or os.clock() >= deadline then
				return nil
			end
			occupied = type(current) == "table" and current.Id ~= state.Owner and not current.Released
			if occupied then
				return nil
			end
			return { Id = state.Owner }
		end, SESSION_TIMEOUT_SECONDS)
	end)
	state.Busy = false
	if not sessionValid(player.UserId, state.Owner) or state.Bypassed then
		return
	end
	if not success then
		bypassSession(state)
	elseif occupied then
		-- A successful response confirming a different owner isn't an outage.
		loseSession(player, state)
	elseif type(result) == "table" and result.Id == state.Owner and not result.Released then
		state.Deadline = started + SESSION_TIMEOUT_SECONDS
		state.NextHeartbeat = os.clock() + SESSION_HEARTBEAT_SECONDS
	else
		bypassSession(state)
	end
end

local function acquireSession(player, owner, token)
	if not SESSION_LOCK_ENABLED then
		return true
	end
	local state = { Owner = owner, Active = true, Deadline = math.huge, Bypassed = false, Busy = false, NextHeartbeat = math.huge }
	sessionLocks[player.UserId] = state
	local started = os.clock()
	local deadline = math.min(started + SESSION_REQUEST_SECONDS, token.Deadline)
	local occupied = false
	local success, result = awaitResult(deadline - started, function()
		return SessionMap:UpdateAsync(getPlayerKey(player), function(current)
			if not loadValid(player, token) or not state.Active or state.Bypassed or os.clock() >= deadline then
				return nil
			end
			occupied = type(current) == "table" and not current.Released and current.Id ~= owner
			if occupied then
				return nil
			end
			return { Id = owner }
		end, SESSION_TIMEOUT_SECONDS)
	end, function()
		return not loadValid(player, token)
	end)
	if not loadValid(player, token) then
		return false
	end
	if not success then
		bypassSession(state)
	elseif occupied then
		return false, "Your data is already open in another server. Please try again shortly."
	elseif type(result) == "table" and result.Id == owner and not result.Released then
		state.Deadline = started + SESSION_TIMEOUT_SECONDS
		state.NextHeartbeat = os.clock() + SESSION_HEARTBEAT_SECONDS
	else
		bypassSession(state)
	end
	if not state.Bypassed then
		task.spawn(function()
			while sessionLocks[player.UserId] == state and state.Active and not state.Bypassed do
				if os.clock() >= state.Deadline then
					bypassSession(state)
				elseif not state.Busy and os.clock() >= state.NextHeartbeat then
					task.spawn(renewSession, player, state)
				end
				task.wait(0.5)
			end
		end)
	end
	return true
end

local function releaseSession(player, owner, deadline)
	local state = sessionLocks[player.UserId]
	if not SESSION_LOCK_ENABLED or not state or state.Owner ~= owner then
		return
	end
	state.Active = false -- Also prevents an in-flight heartbeat from resurrecting this lease.
	if state.Bypassed then
		-- Stop making requests after an outage; any old heartbeat expires naturally.
		sessionLocks[player.UserId] = nil
		return
	end
	deadline = math.min(deadline or math.huge, os.clock() + SESSION_REQUEST_SECONDS)
	if os.clock() < deadline then
		awaitResult(deadline - os.clock(), function()
			return SessionMap:UpdateAsync(getPlayerKey(player), function(current)
				if os.clock() >= deadline or type(current) ~= "table" or current.Id ~= owner then
					return nil
				end
				-- Returning nil cancels UpdateAsync; it doesn't delete the key. An atomic
				-- released marker permits immediate takeover and expires after one second.
				-- Never use GetAsync + RemoveAsync: that could delete a newer owner's lock.
				return { Id = owner, Released = true }
			end, 1)
		end)
	end
	if sessionLocks[player.UserId] == state then
		sessionLocks[player.UserId] = nil
	end
end

local function checkTimeResets(savedData)
	local currentDay = os.date("!%Y_%j")
	local currentWeek = os.date("!%Y_%W")
	local currentMonth = os.date("!%Y_%m")

	if savedData.LastDay ~= currentDay then
		savedData.Wins_Day, savedData.Kills_Day, savedData.Coins_Day = 0, 0, 0
		savedData.LastDay = currentDay
	end

	if savedData.LastWeek ~= currentWeek then
		savedData.Wins_Week, savedData.Kills_Week, savedData.Coins_Week = 0, 0, 0
		savedData.LastWeek = currentWeek
	end

	if savedData.LastMonth ~= currentMonth then
		savedData.Wins_Month, savedData.Kills_Month, savedData.Coins_Month = 0, 0, 0
		savedData.LastMonth = currentMonth
	end
end

local function decodeLegacy(value, state, field)
	if value == nil then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, value)
	if ok and type(decoded) == "table" then
		return decoded
	end
	state.Quarantine[field] = value
	return {}
end

local function loadShop(savedData)
	local state = savedData.__Shop
	local malformed = if state ~= nil and type(state) ~= "table" then state else nil
	if type(state) ~= "table" then
		state = {}
	end
	if type(state.Quarantine) ~= "table" then
		state.Quarantine = {}
	end
	if malformed ~= nil then
		state.Quarantine.Shop = malformed
	end
	for _, key in ipairs({ "Journal", "Legacy", "Recovery" }) do
		if type(state[key]) ~= "table" then
			if state[key] ~= nil then
				state.Quarantine[key] = state[key]
			end
			state[key] = {}
		end
	end
	if type(savedData.OneTimePacks) ~= "string" then
		if savedData.OneTimePacks ~= nil then
			state.Quarantine.OneTimePacks = savedData.OneTimePacks
		end
		savedData.OneTimePacks = ""
	end
	if type(state.WeaponPacks) ~= "table" then
		state.WeaponPacks = { RotationKey = "", Counts = {} }
	end
	if type(state.WeaponPacks.RotationKey) ~= "string" then
		state.WeaponPacks.RotationKey = ""
	end
	if type(state.WeaponPacks.Counts) ~= "table" then
		state.WeaponPacks.Counts = {}
	end
	for index, count in pairs(state.WeaponPacks.Counts) do
		if type(index) ~= "string" or type(count) ~= "number" or count < 0 or count >= math.huge or count % 1 ~= 0 then
			state.WeaponPacks.Counts[index] = nil
		end
	end
	if not state.Migrated then
		local weapons = decodeLegacy(savedData.WeaponPackData, state, "WeaponPackData")
		state.Legacy.Weapons = if type(weapons.Receipts) == "table" then weapons.Receipts else {}
		state.Legacy.Limited = {}
		if type(weapons.RotationKey) == "string" and type(weapons.Counts) == "table" then
			state.WeaponPacks = { RotationKey = weapons.RotationKey, Counts = weapons.Counts }
		end
		-- Keep legacy deduplication evidence privately until each ledger import succeeds.
		local claims = {}
		for _, key in ipairs(string.split(savedData.OneTimePacks or "", ",")) do
			local id = string.match(key, "^LimitedItemReceipt:(.+)$")
			if id then
				state.Legacy.Limited[id] = true
			elseif key ~= "" then
				table.insert(claims, key)
			end
		end
		savedData.OneTimePacks = table.concat(claims, ",")
		state.Migrated = true
	end
	-- Repair only purchase metadata. Inventory/progression and durable ledger records
	-- are never reset because a shop field is malformed.
	for _, field in ipairs({ "Weapons", "Limited" }) do
		if type(state.Legacy[field]) ~= "table" then
			if state.Legacy[field] ~= nil then
				state.Quarantine["Legacy:" .. field] = state.Legacy[field]
			end
			state.Legacy[field] = {}
		end
	end
	for index, count in pairs(state.WeaponPacks.Counts) do
		if type(index) ~= "string" or type(count) ~= "number" or count < 0 or count >= math.huge or count % 1 ~= 0 then
			state.Quarantine["Counter:" .. tostring(index)] = count
			state.WeaponPacks.Counts[index] = nil
		end
	end
	for id, entry in pairs(state.Journal) do
		if
			type(id) ~= "string"
			or type(entry) ~= "table"
			or type(entry.Kind) ~= "string"
			or type(entry.Reward) ~= "table"
			or (entry.Stage ~= "Complete" and entry.Stage ~= "Entitled")
		then
			state.Quarantine["Journal:" .. tostring(id)] = entry
			if type(id) == "string" and #id > 0 and #id <= 47 then
				state.Recovery[id] = true
			end
			state.Journal[id] = nil
		end
	end
	return state
end

local function loadChests(savedData)
	local state = savedData.__Chests
	if state == nil then state = {} end
	if type(state) ~= "table" then
		return { Quarantined = state, RecoveryRequired = true }
	end
	local pending = state.Pending
	if pending ~= nil then
		-- Never discard an unreadable paid opening and overwrite it with an empty state.
		local valid = type(pending) == "table" and type(pending.Id) == "string" and pending.Id ~= ""
			and type(pending.ChestId) == "string" and pending.ChestId ~= ""
			and type(pending.Weapon) == "string" and pending.Weapon ~= ""
			and type(pending.ClaimAt) == "number" and pending.ClaimAt == pending.ClaimAt
			and math.abs(pending.ClaimAt) < math.huge and type(pending.Granted) == "boolean"
		if not valid then
			state.Quarantined = pending
			state.Pending = nil
			state.RecoveryRequired = true
		end
	end
	return state
end

function PlayerDataService.GetChestState(player)
	assert(loadedPlayers[player.UserId] and privateChests[player.UserId], "Chest profile is not loaded")
	return privateChests[player.UserId]
end

function PlayerDataService.GetPurchaseState(player)
	assert(loadedPlayers[player.UserId] and privateShop[player.UserId], "Purchase profile is not loaded")
	return privateShop[player.UserId]
end

-- ==========================================
-- LOGIC
-- ==========================================
-- Input: Player joining this server. Returns nothing; publishes DataLoaded on success.
-- Claim the MemoryStore lease, or fail open on service errors. DataStore installs
-- an owner fence only while session protection remains enabled for this player.
function PlayerDataService.InitializePlayer(player)
	if profilePlayers[player.UserId] and profilePlayers[player.UserId] ~= player then
		player:Kick("Your previous data session is still closing. Please try again shortly.")
		return
	end
	if shuttingDown or loadedPlayers[player.UserId] or loadingPlayers[player.UserId] then
		return
	end
	local token = { Deadline = os.clock() + 150 }
	loadingPlayers[player.UserId] = token
	profilePlayers[player.UserId] = player
	sessionSequence += 1
	local owner = sessionId .. ":" .. sessionSequence
	player:SetAttribute("DataLoaded", false)
	local acquired, reason = acquireSession(player, owner, token)
	local savedData
	while acquired and loadValid(player, token) and sessionValid(player.UserId, owner) do
		local attemptDeadline = math.min(os.clock() + 30, token.Deadline)
		local attemptActive = true
		local success, result = awaitResult(attemptDeadline - os.clock(), function()
			return PlayerDataStore:UpdateAsync(getPlayerKey(player), function(data)
				if
					not attemptActive
					or os.clock() >= attemptDeadline
					or not loadValid(player, token)
					or not sessionValid(player.UserId, owner)
				then
					return nil
				end
				data = data or {}
				-- Admission comes only from MemoryStore. Existing durable leases from
				-- older builds are replaced; no DataStore fallback lease is maintained.
				data.__Session = if protectionEnabled(player.UserId, owner)
					then { Id = owner, Protocol = "MemoryStore" }
					else nil
				local revision = data.__WriteRevision
				if type(revision) ~= "number" or revision < 0 or revision >= math.huge or revision % 1 ~= 0 then
					data.__WriteRevision = 0
				end
				return data
			end)
		end, function()
			return not loadValid(player, token)
		end)
		attemptActive = false
		if success and result then
			savedData = result
			break
		end
		if loadValid(player, token) and sessionValid(player.UserId, owner) then
			task.wait(5)
		end
	end
	local valid = loadValid(player, token) and sessionValid(player.UserId, owner)
	loadingPlayers[player.UserId] = nil
	if not valid then
		savedData = nil
	end
	if not savedData then
		releaseSession(player, owner, shutdownDeadline)
		profilePlayers[player.UserId] = nil
		if player.Parent == Players then
			player:Kick(reason or "Your data could not be loaded safely yet. Please rejoin.")
		end
		return
	end
	closingPlayers[player.UserId] = nil
	sessionOwners[player.UserId] = owner
	writeSequences[player.UserId] = savedData.__WriteRevision or 0
	local published, publishError = pcall(function()
		privateShop[player.UserId] = loadShop(savedData)
		privateChests[player.UserId] = loadChests(savedData)
		player:SetAttribute("ChestRecoveryRequired", privateChests[player.UserId].RecoveryRequired == true)

		savedData = savedData or {}
		-- Convert repeated chest names from older saves before publishing attributes.
		savedData.OwnedChests = ChestInventory.Encode(ChestInventory.Decode(savedData.OwnedChests))
		savedData.EquippedWeaponName = savedData.EquippedWeaponName or savedData.EquippedBaseWeapon or "Slap"
		checkTimeResets(savedData)
		local playtime = savedData.Playtime
		if type(playtime) ~= "number" or playtime ~= playtime or playtime < 0 or playtime >= math.huge then
			savedData.Playtime = PlayerDataService.DefaultAttributes.Playtime
		end

		-- Carica Default + Attributi Dinamici (UseW_ / UseA_)
		for attrName, defValue in pairs(PlayerDataService.DefaultAttributes) do
			player:SetAttribute(attrName, savedData[attrName] ~= nil and savedData[attrName] or defValue)
		end
		for key, val in pairs(savedData) do
			if isDynamicKey(key) then
				player:SetAttribute(key, val)
			end
		end

		for settingName, defValue in pairs(PlayerDataService.DefaultSettings) do
			local currentSetting = savedData[settingName]
			
			if savedData[settingName] == nil then
				currentSetting = defValue
			end
			
			player:SetAttribute(settingName, currentSetting)
		end
		
		for attrName, defValue in pairs(PlayerDataService.SessionAttributes) do
			player:SetAttribute(attrName, defValue)
		end
	end)
	if not published then
		privateChests[player.UserId] = nil
		privateShop[player.UserId], sessionOwners[player.UserId], profilePlayers[player.UserId] = nil, nil, nil
		releaseSession(player, owner, shutdownDeadline)
		warn("[PlayerDataService] Profile publication failed: " .. tostring(publishError))
		player:Kick("Your data could not be opened safely. Please rejoin to retry.")
		return
	end
	loadedPlayers[player.UserId] = true
	nextAutoSaves[player.UserId] = os.clock() + AUTOSAVE_SECONDS
	player:SetAttribute("DataLoaded", true)
end

-- Runs synchronously right before the final save on PlayerRemoving (not on BindToClose:
-- a server shutdown is not the player's fault).
function PlayerDataService.AddPreLeaveHook(callback)
	table.insert(preLeaveHooks, callback)
end

-- Saving uses a service-local lock, independent of shop activity tokens and their
-- PlayerRemoving cleanup. All waits share the operation/shutdown deadline.
local function saveOnce(player, isAutoSave, releaseOnly, deadline)
	local userId = player.UserId
	local resetting = resettingPlayers[player] == true
	if resetting then
		releaseOnly = false -- An explicit reset must persist even in Studio.
	end
	local owner = sessionOwners[userId]
	local function available()
		return loadedPlayers[userId]
			and profilePlayers[userId] == player
			and sessionOwners[userId] == owner
			and sessionValid(userId, owner)
			and (not isAutoSave or (not closingPlayers[userId] and player.Parent == Players))
			and os.clock() < math.min(deadline, shutdownDeadline or math.huge)
	end
	if not available() then
		return false
	end
	while savingPlayers[userId] do
		if not available() then
			return false
		end
		task.wait(0.05)
	end
	if not available() then
		return false
	end
	local token = {}
	savingPlayers[userId] = token
	local function valid()
		return savingPlayers[userId] == token and available()
	end
	writeSequences[userId] = (writeSequences[userId] or 0) + 1
	local revision = writeSequences[userId]
	local dataToSave = {}
	local captured, captureError = pcall(function()
		if releaseOnly then
			return -- Studio release doesn't depend on serializing gameplay/shop state.
		end
		if resetting then
			for attrName, defaultValue in pairs(PlayerDataService.DefaultAttributes) do
				dataToSave[attrName] = defaultValue
			end
			for settingName, defaultValue in pairs(PlayerDataService.DefaultSettings) do
				dataToSave[settingName] = defaultValue
			end
			dataToSave.__Shop = loadShop({})
			dataToSave.PurchaseAllowanceGeneration = assert(resetAllowanceGenerations[player], "Missing reset allowance generation")
			dataToSave.__Chests = {}
			dataToSave.__WriteRevision = revision
			return -- Omit all saved dynamic attributes and old private profile state.
		end
		for attrName in pairs(PlayerDataService.DefaultAttributes) do
			dataToSave[attrName] = player:GetAttribute(attrName)
		end
		for settingName in pairs(PlayerDataService.DefaultSettings) do
			dataToSave[settingName] = player:GetAttribute(settingName)
		end
		dataToSave.__Shop = HttpService:JSONDecode(HttpService:JSONEncode(privateShop[userId]))
		dataToSave.__Chests = HttpService:JSONDecode(HttpService:JSONEncode(privateChests[userId]))
		dataToSave.__WriteRevision = revision
		for attr, val in pairs(player:GetAttributes()) do
			if isDynamicKey(attr) then
				dataToSave[attr] = val
			end
		end
	end)
	if not captured then
		savingPlayers[userId] = nil
		warn("[PlayerDataService] Snapshot will retry: " .. tostring(captureError))
		return false
	end

	local lostOwnership = false
	local remaining = math.max(0, math.min(deadline, shutdownDeadline or math.huge) - os.clock())
	local success, saved = awaitResult(remaining, function()
		return PlayerDataStore:UpdateAsync(getPlayerKey(player), function(current)
			if not valid() then
				return nil
			end
			local protected = protectionEnabled(userId, owner)
			if protected then
				if not current or not current.__Session or current.__Session.Id ~= owner then
					lostOwnership = true
					return nil
				end
				if (current.__WriteRevision or 0) >= revision then
					return nil
				end
			else
				-- Both explicit disable and outage fail-open allow concurrent sessions.
				revision = math.max(revision, (current and current.__WriteRevision or 0) + 1)
			end
			if releaseOnly then
				current = current or {}
				current.__Session = nil
				current.__WriteRevision = revision
				return current
			end
			dataToSave.__WriteRevision = revision
			dataToSave.__Session = if protected and isAutoSave then { Id = owner, Protocol = "MemoryStore" } else nil
			return dataToSave
		end)
	end, function()
		return not valid()
	end)
	local current = valid()
	if savingPlayers[userId] == token then
		savingPlayers[userId] = nil
	end
	if lostOwnership and protectionEnabled(userId, owner) then
		local state = sessionLocks[userId]
		if state and state.Owner == owner then
			loseSession(player, state)
		end
	end
	return success and current and saved ~= nil
end

-- true = ongoing save; false/nil = one coordinated final save with bounded retries.
-- releaseOnly preserves stored gameplay data (used when stopping Studio).
-- Callers such as GiftService may confirm rewards only after this returns true.
function PlayerDataService.SavePlayer(player, isAutoSave, releaseOnly)
	local userId = player.UserId
	if isAutoSave then
		return saveOnce(player, true, false, os.clock() + 30)
	end
	local existing = finalizations[player]
	if existing then
		while not existing.Done and os.clock() < math.min(existing.Deadline, shutdownDeadline or math.huge) do
			task.wait(0.05)
		end
		return existing.Success == true
	end
	if not loadedPlayers[userId] or profilePlayers[userId] ~= player then
		return false
	end
	local operation = { Deadline = os.clock() + SHUTDOWN_SECONDS, Done = false, Success = false }
	finalizations[player] = operation
	closingPlayers[userId] = true
	player:SetAttribute("DataLoaded", false)
	local owner = sessionOwners[userId]
	repeat
		local deadline = math.min(operation.Deadline, shutdownDeadline or math.huge)
		-- A brief per-attempt budget leaves room for retries before shutdown ends.
		operation.Success = saveOnce(player, false, releaseOnly, math.min(deadline, os.clock() + 8))
		if operation.Success or not sessionValid(userId, owner) or os.clock() >= deadline then
			break
		end
		task.wait(0.25)
	until os.clock() >= math.min(operation.Deadline, shutdownDeadline or math.huge)

	if operation.Success then
		-- Release only AFTER the final durable write; keep heartbeating during saving.
		releaseSession(player, owner, math.min(operation.Deadline, shutdownDeadline or math.huge))
	else
		-- Never release ownership early after an unconfirmed final save.
		-- The MemoryStore lease expires on its own; there is no durable fallback.
		local state = sessionLocks[userId]
		if state and state.Owner == owner then
			state.Active = false
			sessionLocks[userId] = nil
		end
		warn("[PlayerDataService] Final save was not confirmed for " .. tostring(userId))
	end
	if sessionOwners[userId] == owner then
		privateChests[userId] = nil
		loadedPlayers[userId], sessionOwners[userId], privateShop[userId] = nil, nil, nil
		writeSequences[userId], closingPlayers[userId], profilePlayers[userId], nextAutoSaves[userId] =
			nil, nil, nil, nil
	end
	operation.Done = true
	finalizations[player] = nil
	return operation.Success
end

-- Replaces only this loaded player's profile. Finalization fences old saves and releases the session.
function PlayerDataService.ResetPlayerData(player: Player): (boolean, string?)
	local userId = player.UserId
	if shuttingDown or closingPlayers[userId] or resettingPlayers[player] then
		return false, "ProfileBusy"
	end
	if player.Parent ~= Players or profilePlayers[userId] ~= player or player:GetAttribute("DataLoaded") ~= true then
		return false, "DataNotLoaded"
	end
	resettingPlayers[player] = true
	resetAllowanceGenerations[player] = HttpService:GenerateGUID(false)
	local saved = PlayerDataService.SavePlayer(player, false)
	if saved then
		player:Kick("Your player data has been reset. Rejoin to start fresh.")
		return true, nil
	end
	player:Kick("Your data reset could not be confirmed. Rejoin and check your data before retrying.")
	return false, "SaveNotConfirmed"
end

function PlayerDataService.GrantAbility(player, abilityName)
	if type(abilityName) ~= "string" or abilityName == "" then
		return false
	end
	local owned = player:GetAttribute("OwnedAbilities") or ""
	for _, entry in string.split(owned, ",") do
		if entry == abilityName then
			return false
		end
	end
	player:SetAttribute("OwnedAbilities", owned == "" and abilityName or (owned .. "," .. abilityName))
	return true
end

-- ==========================================
-- INIT
-- ==========================================
function PlayerDataService.Init()
	if initialized then
		return
	end
	initialized = true
	Players.PlayerAdded:Connect(PlayerDataService.InitializePlayer)
	Players.PlayerRemoving:Connect(function(player)
		local loading = loadingPlayers[player.UserId]
		if loading then
			loading.Deadline = 0
		end
		if not shuttingDown and not resettingPlayers[player] then
			for _, hook in ipairs(preLeaveHooks) do
				local ok, err = pcall(hook, player)
				if not ok then
					warn("[PlayerDataService] PreLeave hook failed: " .. tostring(err))
				end
			end
		end
		-- Both exit paths share the finalization and keep the profile until it finishes.
		PlayerDataService.SavePlayer(player, false, false)
		resettingPlayers[player] = nil
		resetAllowanceGenerations[player] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(PlayerDataService.InitializePlayer, player)
	end

	task.spawn(function()
		while not shuttingDown do
			task.wait(1)
			for userId in pairs(loadedPlayers) do
				local ok, err = pcall(function()
					local player = profilePlayers[userId]
					if player and player.Parent == Players and player:GetAttribute("DataLoaded") then
						if not sessionValid(userId, sessionOwners[userId]) then
							loseSession(player, sessionLocks[userId])
						else
							-- Find this existing code block:
							local playtime = player:GetAttribute("Playtime")
							if type(playtime) ~= "number" or playtime ~= playtime or playtime < 0 or playtime >= math.huge then
								playtime = 0
							end
							local newPlaytime = playtime + 1
							player:SetAttribute("Playtime", newPlaytime)

							-- ADD THIS LINE to send it to AnalyticsService:
							AnalyticsService.RecordPlaytime(player, newPlaytime)

							if os.clock() >= (nextAutoSaves[userId] or math.huge) then
								nextAutoSaves[userId] = math.huge
								task.spawn(function()
									local saveOk, saved = pcall(PlayerDataService.SavePlayer, player, true)
									if loadedPlayers[userId] and not closingPlayers[userId] then
										nextAutoSaves[userId] = os.clock()
											+ (if saveOk and saved then AUTOSAVE_SECONDS else 5)
									end
								end)
							end
						end
					end
				end)
				if not ok then
					warn("[PlayerDataService] Player tick failed: " .. tostring(err))
				end
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		shutdownDeadline = os.clock() + SHUTDOWN_SECONDS
		-- profilePlayers also includes departed players whose final saves are running.
		for userId, player in pairs(profilePlayers) do
			for _, hook in ipairs(preLeaveHooks) do
				local ok, err = pcall(hook, player)
				if not ok then
					warn("[PlayerDataService] PreLeave hook failed: " .. tostring(err))
				end
			end
			if loadedPlayers[userId] then
				task.spawn(PlayerDataService.SavePlayer, player, false, false)
			end
		end
		while os.clock() < shutdownDeadline do
			if next(profilePlayers) == nil and next(loadingPlayers) == nil then
				break
			end
			task.wait(0.05)
		end
	end)
end

return PlayerDataService
