--!strict
-- Registers the starter bundle and applies its saved rewards through purchase receipt recovery.
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(ServerScriptService.Services.AnalyticsService)
local Economy = require(ServerScriptService.Services.AnalyticsService.Economy)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local ChestInventory = require(ReplicatedStorage.SharedModules.ChestInventory)
local Runtime = require(ServerScriptService.Services.Helper.ShopRuntime)
local Receipts = require(ServerScriptService.Services.PurchaseService.Receipts)
local Checkout = require(ServerScriptService.Services.PurchaseService.Checkout)
local Registry = require(ServerScriptService.Services.PurchaseService.ProductRegistry)
local module = {}
local initialized = false
local nextRequest: { [Player]: number } = {}
local prompting: { [Player]: any } = {}
local awaitingReceipt: { [Player]: boolean } = {}
local simplePrompting: { [Player]: boolean } = {}
local PurchaseRemote: RemoteEvent? = nil
local FeedbackRemote: RemoteEvent? = nil
local pack = ShopConfig.StarterLegendaryPack
-- Keep using OneTimePacks for compatibility, but store a stable config key,
-- so changing the developer product ID cannot grant the same bundle again.
local CLAIM_KEY = "StarterLegendaryPack"

local function feedback(player: Player, status: string, requestId: string?)
	if FeedbackRemote and player.Parent == Players then
		FeedbackRemote:FireClient(player, status, requestId)
	end
end

function module.RequestPurchase(player: Player): (boolean, string?)
	if player.Parent ~= Players or PlayerData.Get(player, "DataLoaded") ~= true then
		return false, "DataNotLoaded"
	end
	if pack.ID <= 0 then
		return false, "Unavailable"
	end
	if PlayerData.Get(player, "SimpleCheckoutPending") == true then
		return false, "PurchasePending"
	end
	if ShopConfig.CheckoutMode == "Simple" then
		simplePrompting[player] = true
		local opened, reason = Checkout.RequestSelf(player, pack.ID)
		if not opened then simplePrompting[player] = nil end
		return opened, reason
	end
	local claimed = PlayerData.Get(player, "OneTimePacks")
	if type(claimed) ~= "string" then
		return false, "DataNotLoaded"
	end
	if table.find(string.split(claimed, ","), CLAIM_KEY) then
		return false, "AlreadyClaimed"
	end
	if awaitingReceipt[player] or PlayerData.Get(player, "ManagedCheckoutPending") == true then
		return false, "PurchasePending"
	end
	if os.clock() < (nextRequest[player] or 0) then
		return false, "RateLimited"
	end
	nextRequest[player] = os.clock() + 1
	local token = Runtime.Begin(player, "StarterPrompt", 120)
	if not token then
		return false, "PurchasePending"
	end
	prompting[player] = token
	local ok = Runtime.Await(30, function()
		MarketplaceService:PromptProductPurchase(player, pack.ID)
	end)
	if not Runtime.Valid(player, "StarterPrompt", token) then
		return false, "TimedOut"
	end
	if not ok then
		Runtime.Finish(player, "StarterPrompt", token)
		prompting[player] = nil
		return false, "PromptFailed"
	end
	return true, nil
end

local function grantPack(player: Player, rewards: any, honorPaid: boolean?): boolean
	if player.Parent ~= Players or PlayerData.Get(player, "DataLoaded") ~= true then
		return false
	end
	local claimed = PlayerData.Get(player, "OneTimePacks")
	assert(type(claimed) == "string", "Missing one-time pack claim data")

	local alreadyClaimed = table.find(string.split(claimed, ","), CLAIM_KEY) ~= nil
	if honorPaid or not alreadyClaimed then
		local weapons = PlayerData.Get(player, "OwnedWeapons")
		local abilities = PlayerData.Get(player, "OwnedAbilities")
		local coins = PlayerData.Get(player, "Coins")
		assert(type(weapons) == "string" and type(abilities) == "string", "Missing pack inventory data")
		assert(type(coins) == "number" and coins == coins and math.abs(coins) < math.huge, "Invalid pack coin balance")
		local chests = ChestInventory.Decode(PlayerData.Get(player, "OwnedChests"))
		local oldCoins = coins
		local oldWeapons = Economy.ListCounts(weapons)
		local oldAbilities = Economy.ListCounts(abilities)
		local oldChests = table.clone(chests)

		-- Prepare everything before writing attributes. The grant never yields, so
		-- overlapping receipt retries cannot interleave rewards or save a partial bundle.
		for _, reward in ipairs(rewards) do
			local item = reward.Item :: string
			local quantity = reward.Quantity :: number
			if reward.Type == "Weapon" then
				for _ = 1, quantity do
					weapons = if weapons == "" then item else weapons .. "," .. item
				end
			elseif reward.Type == "Ability" then
				if not table.find(string.split(abilities, ","), item) then
					abilities = if abilities == "" then item else abilities .. "," .. item
				end
			elseif reward.Type == "Chest" then
				chests[item] = (chests[item] or 0) + quantity
			elseif reward.Type == "Coin" then
				coins += quantity
			else
				error("Unknown pack reward type: " .. tostring(reward.Type))
			end
		end
		local encodedChests = ChestInventory.Encode(chests)
		PlayerData.Set(player, "OwnedWeapons", weapons)
		if abilities ~= PlayerData.Get(player, "OwnedAbilities") then
			PlayerData.Set(player, "OwnedAbilities", abilities)
		end
		PlayerData.Set(player, "OwnedChests", encodedChests)
		PlayerData.Set(player, "Coins", math.round(coins))
		if not alreadyClaimed then
			PlayerData.Set(player, "OneTimePacks", if claimed == "" then CLAIM_KEY else claimed .. "," .. CLAIM_KEY)
		end
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins",
			Amount = math.round(coins) - oldCoins, Balance = math.round(coins), TransactionType = "IAP",
			ItemSku = CLAIM_KEY, Activity = "StarterPack",
		})
		for _, input in Economy.InventoryChanges("Weapons", oldWeapons, Economy.ListCounts(weapons), "IAP", "StarterPack") do
			AnalyticsService.RecordEconomy(player, input)
		end
		for _, input in Economy.InventoryChanges("Abilities", oldAbilities, Economy.ListCounts(abilities), "IAP", "StarterPack") do
			AnalyticsService.RecordEconomy(player, input)
		end
		for _, input in Economy.InventoryChanges("Chests", oldChests, chests, "IAP", "StarterPack") do
			AnalyticsService.RecordEconomy(player, input)
		end
	end

	-- Already persisted claims acknowledge repeat receipts without granting anything.
	return true
end

local definition = {
	Apply = function(player: Player, reward: any)
		assert(grantPack(player, reward.Rewards), "Starter profile is unavailable")
	end,
}

function module.Init(registerPurchase: (number, (Player, any) -> boolean) -> ())
	if initialized then
		return
	end
	local events = ReplicatedStorage.Events
	for _, name in ipairs({ "StarterPackPurchaseEvent", "StarterPackFeedbackEvent" }) do
		local remote = events:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name, remote.Parent = name, events
		end
		assert(remote:IsA("RemoteEvent"), name .. " must be a RemoteEvent")
		if name == "StarterPackPurchaseEvent" then
			PurchaseRemote = remote
		else
			FeedbackRemote = remote
		end
	end
	Receipts.Register("StarterPack", definition)
	local products = {}
	if type(pack.ID) == "number" and pack.ID > 0 and pack.ID < math.huge and pack.ID % 1 == 0 then
		products[pack.ID] = { Rewards = pack.Rewards }
	end
	Receipts.Products("StarterPack", products, registerPurchase, function(productId: number, product: any)
		Registry.Register(productId, {
			Kind = "StarterPack", Identity = CLAIM_KEY, SimpleOnly = true, GiftAllowed = false,
			Grant = definition.Apply,
			SimpleGrant = function(player, reward)
				assert(grantPack(player, reward.Rewards, true), "Starter profile is unavailable")
			end,
			Snapshot = function(buyer)
				if productId ~= pack.ID then return nil, "Unavailable" end
			local claims = PlayerData.Get(buyer, "OneTimePacks")
				if type(claims) ~= "string" then return nil, "DataNotLoaded" end
				if table.find(string.split(claims, ","), CLAIM_KEY) then return nil, "AlreadyClaimed" end
				return { Rewards = pack.Rewards }, nil
			end,
			SimpleRecovery = function()
				if productId ~= pack.ID then return nil, "Unavailable" end
				return { Rewards = pack.Rewards }, nil
			end,
		})
		return function(player: Player, receipt: any): boolean
			assert(receipt.ProductId == productId, "Starter receipt mismatch")
			local granted = Receipts.Process(player, receipt, "StarterPack", function()
				return product
			end)
			if granted then
				awaitingReceipt[player] = nil
			end
			feedback(player, if granted then "Purchased" else "SavePending")
			return granted
		end
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local player = Players:GetPlayerByUserId(userId)
		if player and productId == pack.ID and simplePrompting[player] then
			simplePrompting[player] = nil
			return
		end
		if player and productId == pack.ID then
			if prompting[player] then
				Runtime.Finish(player, "StarterPrompt", prompting[player])
			end
			prompting[player] = nil
			if not purchased then
				feedback(player, "Cancelled")
			elseif not table.find(string.split((PlayerData.Get(player, "OneTimePacks") :: string?) or "", ","), CLAIM_KEY) then
				-- Payment completion is only a pending marker; receipts still own delivery.
				awaitingReceipt[player] = true
			end
		end
	end)
	if PurchaseRemote then
		PurchaseRemote.OnServerEvent:Connect(function(player, requestId)
			if type(requestId) ~= "string" or #requestId > 64 then
				return
			end
			local opened, reason = module.RequestPurchase(player)
			feedback(player, if opened then "PromptOpen" else reason or "Unavailable", requestId)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		nextRequest[player], prompting[player] = nil, nil
		awaitingReceipt[player] = nil
		simplePrompting[player] = nil
	end)
	initialized = true
end

return module
