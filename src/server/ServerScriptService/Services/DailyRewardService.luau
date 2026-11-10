-- DailyRewardService (SERVER)
-- Daily reward calendar, MaxDays long (no streak: nothing is ever lost by skipping days). Rewards live in DailyRewardConfig.
--
-- Persistent state (player attributes, saved by PlayerDataService.DefaultAttributes):
--   DailyRewardDay        days claimed in the current cycle (0..MaxDays, clamped if the config gets shorter)
--   DailyRewardLastClaim  os.time() of the last claim (0 = never)
--
-- A claim changes the reward AND both attributes in one block with no yields, so they are always saved
-- together by the profile snapshot (a crash before the save rolls back the claim and the reward together).
--
-- Client protocol (Events.DailyRewardRemote):
--   client -> server: "Claim" | "RequestState"
--   server -> client: "State", { claimed, nextDay, canClaim, secondsLeft, completed }
--                     "Claimed", { day, name, rewardType }

local DailyRewardService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local Events = ReplicatedStorage:WaitForChild("Events")
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local Config = require(SharedModules:WaitForChild("DailyRewardConfig"))
local ChestInventory = require(SharedModules:WaitForChild("ChestInventory"))
local WeaponsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons")

local Services = ServerScriptService:WaitForChild("Services")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(Services.AnalyticsService)
local Economy = require(Services.AnalyticsService.Economy)
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))
local Runtime = require(Services:WaitForChild("Helper"):WaitForChild("ShopRuntime"))
local PurchaseService = require(Services:WaitForChild("PurchaseService"))

local Remote = Events:FindFirstChild("DailyRewardRemote")
if not Remote then
	Remote = Instance.new("RemoteEvent")
	Remote.Name = "DailyRewardRemote"
	Remote.Parent = Events
end
local SpawnVisualCoinsEvent = Events:FindFirstChild("SpawnVisualCoins")

-- Same store/topic ChestService uses to count how many copies of each weapon exist.
local WeaponDS = DataStoreService:GetDataStore("ExistingWeapons_V1")

local MAX_DAYS = Config.MaxDays
local initialized = false

-- ==========================================
-- PROGRESS HELPERS
-- ==========================================
local function getProgress(player: Player): (number, number)
	local claimed = tonumber(PlayerData.Get(player, "DailyRewardDay")) or 0
	local last = tonumber(PlayerData.Get(player, "DailyRewardLastClaim")) or 0
	claimed = math.clamp(math.floor(claimed), 0, MAX_DAYS)
	if last < 0 or last ~= last then last = 0 end
	return claimed, last
end

local function secondsUntilNextClaim(last: number, now: number): number
	if last == 0 then return 0 end
	-- clamp so a corrupted/future timestamp can never lock a player out for more than one cooldown
	return math.clamp(Config.ClaimCooldown - (now - last), 0, Config.ClaimCooldown)
end

-- Starts a fresh cycle once the last day was claimed and its cooldown ran out (only when looping).
local function normalize(player: Player)
	local claimed, last = getProgress(player)
	if Config.LoopAfterLastDay and claimed >= MAX_DAYS and secondsUntilNextClaim(last, os.time()) == 0 then
		PlayerData.Set(player, "DailyRewardDay", 0)
	end
end

local function buildState(player: Player)
	normalize(player)
	local claimed, last = getProgress(player)
	local completed = claimed >= MAX_DAYS and not Config.LoopAfterLastDay
	local secondsLeft = if completed then 0 else secondsUntilNextClaim(last, os.time())
	return {
		claimed = claimed,
		nextDay = math.min(claimed + 1, MAX_DAYS),
		canClaim = (not completed) and secondsLeft == 0,
		secondsLeft = secondsLeft,
		completed = completed,
	}
end

local function sendState(player: Player)
	if not Runtime.Ready(player) then return end
	Remote:FireClient(player, "State", buildState(player))
end

-- ==========================================
-- GRANTING
-- ==========================================
-- Count the weapon as existing (keeps WeaponConfig.RarityLimits accurate), exactly like ChestService does.
local function reserveWeapon(weaponName: string)
	ReplicatedValues.Set(
		ReplicatedStorage,
		"Existing_" .. weaponName,
		(ReplicatedValues.GetNumber(ReplicatedStorage, "Existing_" .. weaponName) or 0) + 1
	)
	task.spawn(function()
		pcall(function() WeaponDS:IncrementAsync("Existing_" .. weaponName, 1) end)
		pcall(function() MessagingService:PublishAsync("WeaponFound", { wName = weaponName, jobId = game.JobId }) end)
	end)
end

-- Must not yield: the attributes it sets are saved together with the claim state.
local function grantReward(player: Player, reward, day: number, skipCooldown: boolean): (boolean, string?)
	local transactionType = if skipCooldown then "IAP" else "TimedReward"
	local activity = if skipCooldown then "DailySkip" else "DailyClaim"
	if reward.Type == "Coins" then
		-- Raw coins on purpose (no 2x / VIP multiplier) so the player gets exactly the number the card shows.
		local coins = PlayerData.Get(player, "Coins")
		coins = if type(coins) == "number" then coins else 0
		PlayerData.Set(player, "Coins", math.round(coins + reward.Amount))
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins",
			Amount = math.round(coins + reward.Amount) - coins, Balance = math.round(coins + reward.Amount),
			TransactionType = transactionType, ItemSku = "DailyReward:" .. tostring(day), Activity = activity })

	elseif reward.Type == "Chest" then
		local ok, owned = pcall(ChestInventory.Decode, PlayerData.Get(player, "OwnedChests"))
		if not ok then return false, "BadChestInventory" end
		owned[reward.Item] = (owned[reward.Item] or 0) + reward.Quantity
		local encodedOk, encoded = pcall(ChestInventory.Encode, owned)
		if not encodedOk then return false, "BadChestInventory" end
		PlayerData.Set(player, "OwnedChests", encoded)
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Chests",
			Amount = reward.Quantity, Balance = Economy.Total(owned), TransactionType = transactionType,
			ItemSku = reward.Item, Activity = activity })

	elseif reward.Type == "Weapon" then
		if not WeaponsFolder:FindFirstChild(reward.Item) then return false, "MissingWeaponModel" end -- never give a weapon without a model
		local weapons = PlayerData.Get(player, "OwnedWeapons")
		if type(weapons) ~= "string" then return false, "MissingWeaponInventory" end
		PlayerData.Set(player, "OwnedWeapons", if weapons == "" then reward.Item else weapons .. "," .. reward.Item)
		AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
			Amount = 1, Balance = Economy.Total(Economy.ListCounts(weapons)) + 1, TransactionType = transactionType,
			ItemSku = reward.Item, Activity = activity })
		reserveWeapon(reward.Item)
	elseif reward.Type == "Buff" then
		if reward.Item == "x2Coin" then
			PlayerData.Set(player, "x2CoinBuffExpiredOn", os.time() + reward.Amount)
		end
	else
		return false, "UnknownRewardType"
	end
	return true, nil
end

-- ==========================================
-- CLAIM
-- ==========================================
-- skipCooldown = true is used by the "skip daily" Developer Product: it claims the next day right now.
local function performClaim(player: Player, skipCooldown: boolean): (boolean, string?)
	local claimedDay: number? = nil
	local claimedReward = nil

	local success, reason = Runtime.Run(player, "DailyRewardClaim", function(_token)
		normalize(player)
		local claimed, last = getProgress(player)
		if claimed >= MAX_DAYS then return false, "Completed" end
		if not skipCooldown and secondsUntilNextClaim(last, os.time()) > 0 then return false, "Cooldown" end

		local day = claimed + 1
		local reward = Config.Rewards[day]
		if not reward then return false, "NoReward" end

		-- No yields from here to the end of the block.
		local granted, err = grantReward(player, reward, day, skipCooldown)
		if not granted then
			warn(("[DailyRewardService] Day %d reward failed for %s: %s"):format(day, player.Name, tostring(err)))
			return false, err
		end
		PlayerData.Set(player, "DailyRewardDay", day)
		PlayerData.Set(player, "DailyRewardLastClaim", os.time())

		claimedDay, claimedReward = day, reward
		return true, nil
	end)

	if success and claimedDay and claimedReward then
		Remote:FireClient(player, "Claimed", { day = claimedDay, name = claimedReward.Name, rewardType = claimedReward.Type })

		if claimedReward.Type == "Coins" and SpawnVisualCoinsEvent then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				SpawnVisualCoinsEvent:FireAllClients(root.Position, player, 35, NumberRange.new(3, 5))
			end
		end

		-- Persist soon; failed saves are retried with backoff (one job per player, replaced on repeat).
		Runtime.Schedule(player, "DailyRewardSave", function()
			return PlayerDataService.SavePlayer(player, true)
		end)
	elseif reason ~= "Busy" and reason ~= "Cooldown" and reason ~= "Completed" then
		warn(("[DailyRewardService] Claim refused for %s: %s"):format(player.Name, tostring(reason)))
	end

	sendState(player) -- always resync the UI, accepted or not
	return success == true and claimedDay ~= nil, reason
end

local function handleClaim(player: Player)
	performClaim(player, false)
end

-- Developer Product receipt: true = settled, false = Roblox retries later (the player already paid).
local function handleSkipPurchase(player: Player): boolean
	local ok, reason = performClaim(player, true)
	if ok then return true end
	if reason == "Completed" then
		return true -- nothing left to give; never loop on a receipt that can't succeed
	end
	warn(("[DailyRewardService] Skip purchase not applied for %s (%s), will retry"):format(player.Name, tostring(reason)))
	return false
end

-- ==========================================
-- INIT
-- ==========================================
local function watchPlayer(player: Player)
	task.spawn(function()
		while player.Parent == Players and PlayerData.Get(player, "DataLoaded") ~= true do
			PlayerData.WaitForChange(player, "DataLoaded")
		end
		if player.Parent ~= Players then return end
		sendState(player)
	end)
end

local function validateConfig()
	for day, reward in ipairs(Config.Rewards) do
		if reward.Type == "Weapon" and not WeaponsFolder:FindFirstChild(reward.Item) then
			warn(("[DailyRewardService] Day %d gives '%s' but Assets.Weapons has no model with that name — the claim will be refused!"):format(day, reward.Item))
		end
	end
end

function DailyRewardService.Init()
	if initialized then return end
	initialized = true

	validateConfig()

	if Config.SkipDailyProductId ~= 0 then
		-- directReceipt = true: the skip is prompted straight from the client (not through the managed Checkout flow),
		-- so settle its receipt with our handler instead of waiting on Checkout's DataStore routing, which never matches it.
		PurchaseService.Register(Config.SkipDailyProductId, handleSkipPurchase, true)
	end
	Remote.OnServerEvent:Connect(function(player: Player, action: unknown)
		if not Runtime.Ready(player) then return end
		if action == "Claim" then
			handleClaim(player)
		elseif action == "RequestState" then
			sendState(player)
		end
	end)

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return DailyRewardService
