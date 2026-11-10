--!strict
-- Grants the early-player coin reward and records its actual economy source.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)

local Service = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local BadgeService = game:GetService("BadgeService")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClaimEarlyRewardEvent = Events:WaitForChild("ClaimEarlyReward")
local SpawnVisualCoinsEvent = Events:WaitForChild("SpawnVisualCoins")
local PlayerData = require(ReplicatedStorage.PlayerData)
local CoinsUtil = require(ReplicatedStorage.Utils.CoinsUtil)

-- ==========================================
-- VARIABLES & CONFIG
-- ==========================================
local BADGE_ID = 3065472685541776
local COIN_REWARD = 1000
local WINS_REQUIRED = 10
local Chest: Model
-- ==========================================
local CoinsUtil = require(ReplicatedStorage.Utils.CoinsUtil)

-- INTERNAL FUNCTIONS
-- ==========================================
local function awardBadge(player: Player, badgeId: number)
	-- Fetch badge information
	local success, badgeInfo = pcall(function()
		return BadgeService:GetBadgeInfoAsync(badgeId)
	end)

	if success then
		-- Confirm that badge can be awarded
		if badgeInfo.IsEnabled then
			-- Award badge
			local awarded, errorMessage = pcall(BadgeService.AwardBadgeAsync, BadgeService, player.UserId, badgeId)
			if not awarded then
				warn("Error while awarding badge:", errorMessage)
			else
				print(`Early player badge awarded for {player.Name}`)
			end
		end
	else
		warn("Error while fetching badge info: " .. tostring(badgeInfo))
	end
end

local function reward(player: Player)
	local currentCoins = (PlayerData.Get(player, "Coins") or 0) :: number
	PlayerData.Set(player, "Coins", math.round(currentCoins + COIN_REWARD))
	AnalyticsService.RecordEconomy(player, {
		Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = math.round(currentCoins + COIN_REWARD) - currentCoins, Balance = math.round(currentCoins + COIN_REWARD),
		TransactionType = "Gameplay", ItemSku = "EarlyPlayerReward", Activity = "EarlyPlayerReward", Context = "NotApplicable",
	})
	awardBadge(player,BADGE_ID)
	SpawnVisualCoinsEvent:FireAllClients(Chest:GetPivot().Position, player, 35, NumberRange.new(3,5)) 
end
-- ==========================================
-- INIT
-- ==========================================
function Service.Init()
	Chest = CollectionService:GetTagged("EarlyRewardChest")[1] :: Model
	if not Chest then
		warn(`Early reward chest not found`)
		return
	end
	ClaimEarlyRewardEvent.OnServerEvent:Connect(function(player: Player)
		local claimed = PlayerData.Get(player, "EarlyRewardClaimed")
		if claimed then return end
		local wins = PlayerData.Get(player, "Wins") :: number
		if wins < WINS_REQUIRED then return end
		PlayerData.Set(player, "EarlyRewardClaimed", true)
		local success,result = pcall(function(...) 
			reward(player)
		end)
		ClaimEarlyRewardEvent:FireClient(player,false)
		if not success then
			warn(result)
			PlayerData.Set(player, "EarlyRewardClaimed", false)
			return
		end
	end)
end

return Service
