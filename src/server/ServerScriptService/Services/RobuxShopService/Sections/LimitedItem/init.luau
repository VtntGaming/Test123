--!strict
-- Publishes rotating limited offers and registers saved weapon rewards and recipient entitlement checks.

--// Services
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local PurchaseTypes = require(ServerScriptService.Services.PurchaseService.Types)
local Runtime = require(ServerScriptService.Services.Helper.ShopRuntime)
local Receipts = require(ServerScriptService.Services.PurchaseService.Receipts)
local Checkout = require(ServerScriptService.Services.PurchaseService.Checkout)
local Registry = require(ServerScriptService.Services.PurchaseService.ProductRegistry)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local LimitedItemRotation = require(script.LimitedItemRotation)

--// Properties
local Initialized = false
local Pack = ShopConfig.StarterLegendaryPack
local Limited = ShopConfig.LimitedItem
local PurchaseRemote: RemoteEvent? = nil
local FeedbackRemote: RemoteEvent? = nil

--// Types
export type LimitedItem = {
	RequestPurchase: (player: Player, rotationKey: string) -> (boolean, string?),
	Setup: (self: LimitedItem, registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
	Start: (self: LimitedItem) -> (),
	Init: (registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
}

--// Service
local Service = {} :: LimitedItem

--// APIs
local function Feedback(player: Player, status: string, item: string?)
	if FeedbackRemote and player.Parent == Players then
		FeedbackRemote:FireClient(player, status, item)
	end
end

function Service.RequestPurchase(player, rotationKey)
	local offer = Limited and LimitedItemRotation.GetOffer(Limited, os.time())
	if type(rotationKey) ~= "string" or not offer or offer.Key ~= rotationKey then
		return false, "OfferExpired"
	end
	if offer.Entry.ID <= 0 then
		return false, "Unavailable"
	end
	return Checkout.RequestSelf(player, offer.Entry.ID, { RotationKey = rotationKey })
end

-- Inputs: loaded recipient/buyer Player, weapon name, captured offer RotationKey.
-- Returns true if one weapon copy + claim marker were added; false if already claimed.
-- Duplicate ownership of the weapon is allowed; only the rotation key blocks a grant.
-- No yields or saving. Caller must save the attributes before acknowledging payment.
local function ClaimLimited(player: Player, item: string, rotationKey: string, honorPaid: boolean?): boolean
	local claimed = PlayerData.Get(player, "OneTimePacks")
	local weapons = PlayerData.Get(player, "OwnedWeapons")
	assert(type(claimed) == "string" and type(weapons) == "string", "Missing limited item data")
	local alreadyClaimed = table.find(string.split(claimed, ","), rotationKey) ~= nil
	if alreadyClaimed and not honorPaid then
		return false
	end
	PlayerData.Set(player, "OwnedWeapons", if weapons == "" then item else weapons .. "," .. item)
	AnalyticsService.RecordEconomy(player, {
		Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
		Amount = 1, Balance = Economy.Total(Economy.ListCounts(weapons)) + 1, TransactionType = "IAP",
		ItemSku = item, Activity = "LimitedItem",
	})
	if not alreadyClaimed then
		PlayerData.Set(player, "OneTimePacks", if claimed == "" then rotationKey else claimed .. "," .. rotationKey)
	end
	return true
end

-- Paid delivery is coordinated with the durable receipt ledger.
local Definition = {
	Legacy = {
		Field = "Limited",
		Validate = function(raw: any): boolean
			return raw == true
		end,
		IsComplete = function(raw: any): boolean
			return true
		end,
		ProductId = function(raw: any): number
			return 0
		end,
	},
	Apply = function(player: Player, reward: PurchaseTypes.Reward)
		if reward.RotationKey then
			ClaimLimited(player, reward.Item, reward.RotationKey, reward.HonorPaid == true)
		else
		local weapons = PlayerData.Get(player, "OwnedWeapons")
			assert(type(weapons) == "string", "Missing weapon inventory")
		PlayerData.Set(player, "OwnedWeapons", if weapons == "" then reward.Item else weapons .. "," .. reward.Item)
			AnalyticsService.RecordEconomy(player, {
				Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
				Amount = 1, Balance = Economy.Total(Economy.ListCounts(weapons)) + 1, TransactionType = "IAP",
				ItemSku = reward.Item, Activity = "LimitedItem",
			})
		end
	end,
}

-- Keep only currently reachable limited rotation keys; receipt replay lives in the ledger.
local function PruneClaims(player: Player)
	if not Runtime.Ready(player) then
		return
	end
	local claimed = PlayerData.Get(player, "OneTimePacks")
	if type(claimed) ~= "string" then
		return
	end
	local keep, result = {}, {}
	for _, entry in ipairs(Limited.List) do
		local offer = LimitedItemRotation.GetLatestOffer(Limited, entry.Item, os.time())
		if offer then
			keep[offer.Key] = true
		end
	end
	for _, key in ipairs(string.split(claimed, ",")) do
		if key ~= "" and (not string.match(key, "^LimitedItem:") or keep[key]) then
			table.insert(result, key)
		end
	end
	local updated = table.concat(result, ",")
	if updated ~= claimed then
		PlayerData.Set(player, "OneTimePacks", updated)
		if ShopConfig.CheckoutMode ~= "Simple" then Receipts.Dirty(player) end
	end
end

-- Last published rotation key; nil forces the first publication, even before launch.
local PublishedKey: string? = nil
-- No inputs/return. Publishes current offer attributes and schedules the next check.
-- Recomputes from server time/config; no current-weapon DataStore record is required.
local function RefreshLimitedItem()
	-- Keep scheduling even if a display/config operation fails below.
	task.delay(1, function()
		local ok, err = pcall(RefreshLimitedItem)
		if not ok then
			warn("[LimitedItem] Refresh will retry: " .. tostring(err))
		end
	end)
	local now = os.time()
	local offer = LimitedItemRotation.GetOffer(Limited, now)
	local key = if offer then offer.Key else ""
	local nextRefresh = if offer then offer.EndsAt else Limited.StartAt
	if PublishedKey ~= key then
		local entry = if offer then offer.Entry else nil
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemName", if entry then entry.Item else "")
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemImage", if entry then entry.Image else "")
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemRobux", if entry then entry.Robux or 0 else 0)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemProductId", if entry then entry.ID else 0)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemGiftProductId", if entry then entry.ID else 0)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemGiftAvailable", entry ~= nil and entry.ID > 0)
		ReplicatedValues.Set(
			ReplicatedStorage,
			"LimitedItemStartsAt",
			if offer then offer.StartsAt else Limited.StartAt
		)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemEndsAt", if offer then offer.EndsAt else 0)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemNextRefreshTime", nextRefresh)
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemAvailable", entry ~= nil and entry.ID > 0)
		-- Published last: clients can watch this key, then read a complete offer snapshot.
		-- The same key in player.OneTimePacks means this rotation has been purchased.
		ReplicatedValues.Set(ReplicatedStorage, "LimitedItemRotationKey", key)
		PublishedKey = key
		for _, player in ipairs(Players:GetPlayers()) do
			pcall(PruneClaims, player)
		end
	end
	-- Re-evaluate the clock periodically as well as exactly at the next boundary.
	return true
end

-- Input: PurchaseService.Register(productId, handler(player, receipt) -> boolean).
-- Returns nothing; registers direct purchases, starts refresh, and connects cleanup once.
-- Self/gift capabilities are registered with the shared product registry.
function Service:Setup(registerPurchase)
	Receipts.Register("LimitedItem", Definition)
	Registry.RegisterReward("LimitedItem", Definition.Apply)
	if Limited then
		LimitedItemRotation.Validate(Limited)
		local products = {}
		for _, entry in ipairs(Limited.List) do
			local info = WeaponConfig.GetWeaponInfo(entry.Item)
			if entry.Item ~= "HammerKaido" then -- KAIDO SPECIAL
				assert(
					info and (info.Variant == "None" or table.find(WeaponConfig.RarityVariants[info.Rarity], info.Variant)),
					"Unknown limited weapon: " .. entry.Item
				)
			end
			if entry.ID > 0 then
				assert(entry.ID ~= Pack.ID, "Limited product ID conflicts with starter pack")
				products[entry.ID] = { Item = entry.Item }
			end
		end
		Receipts.Products("LimitedItem", products, registerPurchase, function(productId: number, product: any)
			Registry.Register(productId, {
				Kind = "LimitedItem",
				Identity = product.Item,
				Grant = Definition.Apply,
				SimpleGrant = function(player: Player, reward: PurchaseTypes.Reward)
					if reward.RotationKey then
						ClaimLimited(player, reward.Item, reward.RotationKey, true)
					else
						Definition.Apply(player, reward)
					end
				end,
				RecoveryReward = function(player: Player)
					for _, entry in ipairs(Limited.List) do
						if entry.ID == productId and entry.Item == product.Item then
							-- Product IDs keep their weapon identity even outside its sale rotation.
							return { Item = product.Item }, nil
						end
					end
					return nil, "Unavailable"
				end,
				Snapshot = function(buyer, recipient, context)
					local offer = LimitedItemRotation.GetOffer(Limited, os.time())
					if not offer or offer.Entry.ID ~= productId or offer.Entry.Item ~= product.Item then
						return nil, "OfferExpired"
					end
					if context.RotationKey and context.RotationKey ~= offer.Key then
						return nil, "OfferExpired"
					end
				local claimed = PlayerData.Get(recipient, "OneTimePacks")
					if type(claimed) ~= "string" then
						return nil, "DataNotLoaded"
					end
					if table.find(string.split(claimed, ","), offer.Key) then
						return nil, "AlreadyClaimed"
					end
					return { Item = product.Item, RotationKey = offer.Key }
				end,
				Reservation = function(recipient, reward)
					return { Key = reward.RotationKey, Limit = 1, Used = 0 }
				end,
			})
			return function(player: Player, receipt: PurchaseTypes.Receipt): boolean
				return Checkout.TryProcess(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end)
	end
end

function Service:Start()
	if Limited then
		local ok, err = pcall(RefreshLimitedItem)
		if not ok then
			warn("[LimitedItem] Initial publication will retry: " .. tostring(err))
		end
	end
	if PurchaseRemote then
		PurchaseRemote.OnServerEvent:Connect(function(player, rotationKey)
			local opened, reason = Service.RequestPurchase(player, rotationKey)
			Feedback(player, if opened then "PromptOpen" else reason or "Unavailable")
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
