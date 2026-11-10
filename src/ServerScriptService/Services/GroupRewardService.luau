--!strict
-- Grants eligible group rewards and reports actual coin and VIP bonus income.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Monetization = require(ServerScriptService.Services.AnalyticsService.Monetization)

local GroupRewardService = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClaimGroupRewardEvent = Events:WaitForChild("ClaimGroupRewardEvent")
local SpawnVisualCoinsEvent = Events:WaitForChild("SpawnVisualCoins")

local GroupService = game:GetService("GroupService")
	
local GROUP_ID = 33988452
local COIN_REWARD = 1000

local claiming: {[Player]: boolean} = {}

local CoinsUtil = require(ReplicatedStorage.Utils.CoinsUtil)

	
local function isPlayerInGroup(player: Player): boolean
	local ok, result = pcall(function()
		return player:IsInGroupAsync(GROUP_ID)
	end)
	if not ok then
		warn("[GroupRewardService] IsInGroupAsync failed for", player.Name, result)
		return false
	end
	return result
end

local function giveGroupReward(player: Player)
	local amount, balance, vipBonus = CoinsUtil:GiveCoins(player, COIN_REWARD)
	AnalyticsService.RecordEconomy(player, {
		Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins", Amount = amount, Balance = balance,
		TransactionType = "Gameplay", ItemSku = "GroupReward", Activity = "GroupReward", Context = "2xNotApplied",
	})
	AnalyticsService.RecordCustom(player, Monetization.VipBonus(player, vipBonus, "GroupReward", "2xNotApplied"))
	player:SetAttribute("GroupRewardClaimed", true)

	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		SpawnVisualCoinsEvent:FireAllClients(root.Position, player, 35, NumberRange.new(3, 5))
	end
	return amount
end

function GroupRewardService.Init()
	ClaimGroupRewardEvent.OnServerEvent:Connect(function(player)
		if player:GetAttribute("DataLoaded") ~= true then return end
		if player:GetAttribute("GroupRewardClaimed") or claiming[player] then return end

		-- IsInGroupAsync yields, so lock first to stop double-click exploits
		claiming[player] = true
		local inGroup = isPlayerInGroup(player)

		if player.Parent == Players and inGroup and not player:GetAttribute("GroupRewardClaimed") then
			local amount = giveGroupReward(player)
			ClaimGroupRewardEvent:FireClient(player, "Claimed", amount)
		elseif player.Parent == Players then
			ClaimGroupRewardEvent:FireClient(player, "NotInGroup")
		end
		claiming[player] = nil
	end)

	Players.PlayerRemoving:Connect(function(player)
		claiming[player] = nil
	end)
end

return GroupRewardService
