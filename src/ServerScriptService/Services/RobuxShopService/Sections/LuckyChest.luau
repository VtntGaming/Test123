--!strict
-- Registers unopened lucky chest purchases and gifts; variant weapon selection occurs when the chest opens.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PolicyService = game:GetService("PolicyService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local AnalyticsService = require(Services.AnalyticsService)
local Economy = require(Services.AnalyticsService.Economy)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Runtime = require(Services.Helper.ShopRuntime)
local Receipts = require(Services.PurchaseService.Receipts)
local Checkout = require(Services.PurchaseService.Checkout)
local Products = require(Services.PurchaseService.ProductRegistry)
local Registry = require(Services.Helper.ChestRewardRegistry)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local Catalog = require(ReplicatedStorage.SharedModules.ChestCatalog)
local Inventory = require(ReplicatedStorage.SharedModules.ChestInventory)

--// Properties
local Initialized = false
local Random = Random.new()
local Pools: { [string]: { string } } = {}
local Remote: RemoteEvent? = nil

--// Types
export type LuckyChest = {
	GetInfo: (group: string) -> any,
	RequestPurchase: (player: Player, group: string) -> (boolean, string?),
	Setup: (self: LuckyChest, registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
	Start: (self: LuckyChest) -> (),
	Init: (registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
}

--// Service
local Service = {} :: LuckyChest

--// APIs
local function Feedback(player: Player, action: string, payload: any)
	if Remote and Runtime.Ready(player) then
		Remote:FireClient(player, action, payload)
	end
end

local function Allowed(player: Player): (boolean, string?)
	local ok, policy = Runtime.Await(30, function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok or type(policy) ~= "table" or type(policy.ArePaidRandomItemsRestricted) ~= "boolean" then
		return false, "PolicyUnavailable"
	end
	if policy.ArePaidRandomItemsRestricted then
		return false, "PaidRandomItemsRestricted"
	end
	return true, nil
end

local function RollLucky(player: Player, info: any): string?
	local pool = Pools[info.Group]
	return if pool and #pool > 0 then pool[Random:NextInteger(1, #pool)] else nil
end

local Definition = {
	Apply = function(player: Player, reward: PurchaseTypes.Reward)
		local info = type(reward.ChestId) == "string" and Catalog.Get(reward.ChestId)
		assert(info and info.RewardKind == "LuckyVariant" and reward.Quantity == 1, "Invalid saved lucky chest")
		local owned = Inventory.Decode(player:GetAttribute("OwnedChests"))
		owned[reward.ChestId] = (owned[reward.ChestId] or 0) + reward.Quantity
		player:SetAttribute("OwnedChests", Inventory.Encode(owned))
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Chests",
			Amount = reward.Quantity, Balance = Economy.Total(owned), TransactionType = "IAP",
			ItemSku = reward.ChestId, Activity = "LuckyChest",
		})
	end,
}

function Service.GetInfo(group)
	local pack, pool = ShopConfig.LuckyChestPacks[group], Pools[group]
	if not pack or not pool then
		return nil
	end
	local outcomes = {}
	for _, weapon in ipairs(pool) do
		table.insert(outcomes, { Weapon = weapon, ChancePercent = 100 / #pool })
	end
	return {
		Group = group,
		ChestId = Catalog.LuckyId(group),
		ProductId = pack.ID,
		Price = pack.Price,
		Outcomes = outcomes,
	}
end

function Service.RequestPurchase(player, group)
	if type(group) ~= "string" then
		return false, "InvalidRequest"
	end
	local pack = ShopConfig.LuckyChestPacks[group]
	if not pack or pack.ID <= 0 then
		return false, "Unavailable"
	end
	return Checkout.RequestSelf(player, pack.ID)
end

function Service:Setup(registerPurchase)
	local ids, products = {}, {}
	for group, pack in pairs(ShopConfig.LuckyChestPacks) do
		local known = false
		for _, variants in pairs(WeaponConfig.RarityVariants) do
			if table.find(variants, group) then
				known = true
			end
		end
		assert(known, "Unknown lucky chest variant: " .. group)
		assert(
			type(pack.ID) == "number" and pack.ID >= 0 and pack.ID < math.huge and pack.ID % 1 == 0,
			"Invalid lucky chest ID"
		)
		local pool = {}
		for base in pairs(WeaponConfig.BaseWeapons) do
			table.insert(pool, base .. group)
		end
		table.sort(pool)
		assert(#pool > 0, "Empty lucky chest pool")
		Pools[group] = pool
		if pack.ID > 0 then
			assert(not ids[pack.ID], "Duplicate lucky chest ID")
			ids[pack.ID] = true
			products[pack.ID] = { Group = group }
		end
	end
	Registry.Register("LuckyVariant", RollLucky)
	Receipts.Register("LuckyChest", Definition)
	Products.RegisterReward("LuckyChest", Definition.Apply)
	Receipts.Products("LuckyChest", products, registerPurchase, function(productId: number, product: any)
		Products.Register(productId, {
			Kind = "LuckyChest",
			Identity = product.Group,
			Grant = Definition.Apply,
			SimplePolicy = Allowed,
			RecoveryReward = function(player: Player)
				local live = ShopConfig.LuckyChestPacks[product.Group]
				if not live or live.ID ~= productId or not Catalog.Get(Catalog.LuckyId(product.Group)) then
					return nil, "Unavailable"
				end
				local allowed, reason = Allowed(player)
				if not allowed then return nil, reason end
				return { ChestId = Catalog.LuckyId(product.Group), Quantity = 1 }, nil
			end,
			Snapshot = function(buyer, recipient)
				local live = ShopConfig.LuckyChestPacks[product.Group]
				if not live or live.ID ~= productId then
					return nil, "Unavailable"
				end
				if not Catalog.Get(Catalog.LuckyId(product.Group)) then
					return nil, "Unavailable"
				end
				local canBuy, reason = Allowed(buyer)
				if not canBuy then
					return nil, reason
				end
				if buyer ~= recipient then
					local canReceive, receiveReason = Allowed(recipient)
					if not canReceive then
						return nil, receiveReason
					end
				end
				return { ChestId = Catalog.LuckyId(product.Group), Quantity = 1 }
			end,
		})
		return function(player: Player, receipt: PurchaseTypes.Receipt): boolean
			return Checkout.TryProcess(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end)
	local events = ReplicatedStorage.Events
	local existing = events:FindFirstChild("LuckyChestEvent")
	if not existing then
		existing = Instance.new("RemoteEvent")
		existing.Name = "LuckyChestEvent"
		existing.Parent = events
	end
	assert(existing:IsA("RemoteEvent"), "LuckyChestEvent must be a RemoteEvent")
	Remote = existing
end

function Service:Start()
	assert(Remote, "LuckyChest.Setup must run before Start").OnServerEvent:Connect(function(player, action, value)
		if not Runtime.Ready(player) or type(value) ~= "string" or #value > 64 then
			return
		end
		if action == "Purchase" then
			local ok, opened, reason = pcall(Service.RequestPurchase, player, value)
			if not ok then
				warn("[LuckyChest] " .. tostring(opened))
			end
			Feedback(player, "Status", if not ok then "Unavailable" elseif opened then "PromptOpen" else reason)
		elseif action == "GetInfo" then
			Feedback(player, "Info", Service.GetInfo(value))
		end
	end)
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
