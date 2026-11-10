--!strict
-- Registers coin-pack purchase and gift rules and applies the recipient's first-time bonus on delivery.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local AnalyticsService = require(Services.AnalyticsService)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Receipts = require(Services.PurchaseService.Receipts)
local Checkout = require(Services.PurchaseService.Checkout)
local Registry = require(Services.PurchaseService.ProductRegistry)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)

--// Properties
local Initialized = false
local MaxCoinPackValue = 0
local PurchaseRemote: RemoteEvent? = nil
local FeedbackRemote: RemoteEvent? = nil

--// Types
export type CoinPacks = {
	RequestPurchase: (player: Player, packKey: string) -> (boolean, string?),
	Setup: (self: CoinPacks, registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
	Start: (self: CoinPacks) -> (),
	Init: (registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
}

--// Service
local Service = {} :: CoinPacks

--// APIs
local function Ready(player: Player): boolean
	return player.Parent == Players and player:GetAttribute("DataLoaded") == true
end

local function Feedback(player: Player, status: string, packKey: string, amount: number?)
	if FeedbackRemote and Ready(player) then
		FeedbackRemote:FireClient(player, status, packKey, amount)
	end
end

-- Only prompts a configured developer product. Rewards come from receipt processing.
function Service.RequestPurchase(player, packKey)
	if type(packKey) ~= "string" then
		return false, "InvalidRequest"
	end
	local pack = ShopConfig.CoinPacks[packKey]
	if not pack or pack.ID <= 0 then
		return false, "Unavailable"
	end
	return Checkout.RequestSelf(player, pack.ID)
end

local Definition = {
	Apply = function(player: Player, reward: PurchaseTypes.Reward)
		local claimed = player:GetAttribute("FirstTimeCoinPack")
		local coins = player:GetAttribute("Coins")
		assert(
			type(claimed) == "string" and type(coins) == "number" and coins == coins and math.abs(coins) < math.huge,
			"Invalid coin pack profile"
		)
		local first = not table.find(string.split(claimed, ","), reward.Pack)
		local amount = if first then math.min(reward.Value * (1 + reward.Bonus), reward.Cap) else reward.Value
		assert(amount > 0 and amount < math.huge and coins + amount < math.huge, "Invalid coin grant")
		player:SetAttribute("Coins", math.round(coins + amount))
		if first then
			player:SetAttribute(
				"FirstTimeCoinPack",
				if claimed == "" then reward.Pack else claimed .. "," .. reward.Pack
			)
		end
		reward.Amount = amount
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins",
			Amount = math.round(coins + amount) - coins, Balance = math.round(coins + amount), TransactionType = "IAP",
			ItemSku = reward.Pack, Activity = "CoinPack",
		})
	end,
}

function Service:Setup(registerPurchase)
	local ids = {}
	for _, data in pairs(ShopConfig.CoinPacks) do
		assert(
			type(data.ID) == "number" and data.ID >= 0 and data.ID < math.huge and data.ID % 1 == 0,
			"Invalid coin pack developer product ID"
		)
		assert(type(data.Value) == "number" and data.Value > 0 and data.Value < math.huge, "Invalid coin pack value")
		MaxCoinPackValue = math.max(MaxCoinPackValue, data.Value)
		if data.ID > 0 then
			assert(not ids[data.ID], "Duplicate coin pack developer product ID")
			ids[data.ID] = true
		end
	end
	Receipts.Register("CoinPack", Definition)
	Registry.RegisterReward("CoinPack", Definition.Apply)
	local products = {}
	for coinpack, data in pairs(ShopConfig.CoinPacks) do
		if data.ID > 0 then
			products[data.ID] = { Pack = coinpack, Value = data.Value }
		end
	end
	Receipts.Products("CoinPack", products, registerPurchase, function(productId: number, product: any)
		Registry.Register(productId, {
			Kind = "CoinPack",
			Identity = product.Pack,
			Grant = Definition.Apply,
			RecoveryReward = function(player: Player)
				local live = ShopConfig.CoinPacks[product.Pack]
				if not live or live.ID ~= productId then return nil, "Unavailable" end
				return { Pack = product.Pack, Value = live.Value, Bonus = ShopConfig.FirstTimeBonus.CoinPack,
					Cap = MaxCoinPackValue }, nil
			end,
			Snapshot = function()
				local live = ShopConfig.CoinPacks[product.Pack]
				if not live or live.ID ~= productId then
					return nil, "Unavailable"
				end
				return {
					Pack = product.Pack,
					Value = product.Value,
					Bonus = ShopConfig.FirstTimeBonus.CoinPack,
					Cap = MaxCoinPackValue,
				}
			end,
		})
		return function(player: Player, receipt: PurchaseTypes.Receipt): boolean
			return Checkout.TryProcess(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end)
end

function Service:Start()
	if PurchaseRemote then
		PurchaseRemote.OnServerEvent:Connect(function(player, packKey)
			if type(packKey) ~= "string" then
				return
			end
			local success, reason = Service.RequestPurchase(player, packKey)
			Feedback(player, if success then "PromptOpen" else reason or "Unavailable", packKey)
		end)
	end
end

function Service.Init(registerPurchase)
	if Initialized then
		return
	end
	Service:Setup(registerPurchase)
	Service:Start()
	Initialized = true
end

return Service
