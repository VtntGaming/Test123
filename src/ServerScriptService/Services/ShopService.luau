--!native
--!optimize 2
-- Publishes normal chest-shop stock and handles chest purchases and paid restocking.
--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local Monetization = require(ServerScriptService.Services.AnalyticsService.Monetization)

local ShopService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChestConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ChestConfig"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ShopConfig"))
local ChestInventory = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ChestInventory"))

local Events = ReplicatedStorage.Events
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PurchaseService = require(script.Parent.PurchaseService)

export type StockOrigin = "Initial" | "Scheduled" | "Paid"
local StockOrigin: StockOrigin = "Initial"

function ShopService.GetStockOrigin(): StockOrigin
	return StockOrigin
end

local function generateStock(origin: StockOrigin): number
	local total = 0
	ReplicatedStorage:SetAttribute("NextRestockTime", os.time() + ChestConfig.RestockTimeSeconds)

	for name, data in pairs(ChestConfig.Chests) do
		local stock = 0
		if math.random(1, 100) <= data.ShopDropRate then stock = math.random(data.ShopAmountRate[1], data.ShopAmountRate[2]) end
		ReplicatedStorage:SetAttribute("Stock_" .. name, stock)
		total += stock
	end
	StockOrigin = origin
	return total
end

function ShopService.Init()
	generateStock("Initial")
	
	task.spawn(function()
		while task.wait(1) do
			if os.time() >= (ReplicatedStorage:GetAttribute("NextRestockTime") or 0) then generateStock("Scheduled") end
		end
	end)

	PurchaseService.Register(ShopConfig.Shop.DevProduct.Restock, function(player)
		local total = generateStock("Paid")
		AnalyticsService.RecordCustom(player, Monetization.Restock(player, ShopConfig.Shop.DevProduct.Restock, total))
		return true
	end, true) -- Restocking is handled directly in every checkout mode.

	for chestName, data in pairs(ChestConfig.Chests) do
		if data.ProductId then
			PurchaseService.Register(data.ProductId, function(player)
				local stock = ReplicatedStorage:GetAttribute("Stock_" .. chestName) or 0
				if stock > 0 then
					ReplicatedStorage:SetAttribute("Stock_" .. chestName, stock - 1)
				end

				local owned = ChestInventory.Decode(player:GetAttribute("OwnedChests"))
				owned[chestName] = (owned[chestName] or 0) + 1
				player:SetAttribute("OwnedChests", ChestInventory.Encode(owned))
				AnalyticsService.RecordEconomy(player, { Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Chests",
					Amount = 1, Balance = Economy.Total(owned), TransactionType = "IAP",
					ItemSku = chestName, Activity = "ChestPurchase" })
				return true
			end, true)
		end
	end
end

return ShopService
