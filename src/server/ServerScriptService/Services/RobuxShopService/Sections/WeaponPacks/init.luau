--!strict
-- Publishes rotating weapon offers and grants full bundles for free claims, self purchases and gifts.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(Services.AnalyticsService)
local Economy = require(Services.AnalyticsService.Economy)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Data = require(Services.PlayerDataService)
local Runtime = require(Services.Helper.ShopRuntime)
local Receipts = require(Services.PurchaseService.Receipts)
local Checkout = require(Services.PurchaseService.Checkout)
local Registry = require(Services.PurchaseService.ProductRegistry)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local Rotation = require(script.WeaponPackRotation)

--// Properties
local Config = ShopConfig.WeaponPacks
local Initialized = false
local Cached: Rotation.Snapshot? = nil
local CachedSlot: number? = nil
local PublishedKey: string? = nil
local Connections: { [Player]: { PlayerData.Connection } } = {}
local NextRequest: { [Player]: number } = {}
local FreePending: { [Player]: { Index: number, Key: string } } = {}
local PurchaseRemote: RemoteEvent? = nil
local FeedbackRemote: RemoteEvent? = nil

--// Types
export type BundleReward = {
	Weapon: string,
	Index: number,
	RotationKey: string,
	Quantity: number,
	Limit: number,
	Used: number,
}
export type WeaponPacks = {
	Claim: (player: Player, index: number, key: string) -> (boolean, string?),
	RequestPurchase: (player: Player, index: number, key: string) -> (boolean, string?),
	Setup: (self: WeaponPacks, registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
	Start: (self: WeaponPacks) -> (),
	Init: (registerPurchase: PurchaseTypes.RegisterPurchase) -> (),
}

--// Service
local Service = {} :: WeaponPacks

--// APIs
local function Current(): Rotation.Snapshot?
	local slot = math.floor((os.time() - Config.StartAt) / Config.Duration)
	if CachedSlot ~= slot then
		Cached = Rotation.GetSnapshot(Config, WeaponConfig, os.time())
		CachedSlot = slot
	end
	return Cached
end

local function Counters(player: Player): any
	local private = Receipts.State(player)
	local state = private.WeaponPacks
	if type(state) ~= "table" or type(state.Counts) ~= "table" or type(state.RotationKey) ~= "string" then
		private.Quarantine.WeaponCounters = state
		state = { RotationKey = "", Counts = {} }
		private.WeaponPacks = state
	end
	for index = 1, #Config.List do
		local key = tostring(index)
		local value = state.Counts[key]
		if value ~= nil and (type(value) ~= "number" or value < 0 or value >= math.huge or value % 1 ~= 0) then
			private.Quarantine["Counter:" .. key] = value
			state.Counts[key] = nil
			Receipts.Dirty(player)
		end
	end
	local snapshot = Current()
	local key = if snapshot then snapshot.RotationKey else ""
	if state.RotationKey ~= key then
		state.RotationKey, state.Counts = key, {}
	end
	return state
end

local function SimpleCounters(player: Player): { RotationKey: string, Counts: { [string]: number } }
	local snapshot = Current()
	local key = if snapshot then snapshot.RotationKey else ""
	local ok, decoded =
		pcall(HttpService.JSONDecode, HttpService, PlayerData.Get(player, "SimpleWeaponPackPurchases") or "{}")
	local state = if ok and type(decoded) == "table" and decoded.RotationKey == key and type(decoded.Counts) == "table"
		then decoded else { RotationKey = key, Counts = {} }
	local private = Data.GetPurchaseState(player)
	local legacy = private.WeaponPacks
	for index = 1, #Config.List do
		local slot = tostring(index)
		local count = state.Counts[slot]
		if type(count) ~= "number" or count < 0 or count >= math.huge or count % 1 ~= 0 then count = 0 end
		local old = if legacy and legacy.RotationKey == key then legacy.Counts[slot] else nil
		if type(old) == "number" and old >= 0 and old < math.huge and old % 1 == 0 then count = math.max(count, old) end
		state.Counts[slot] = count
	end
	local encoded = HttpService:JSONEncode(state)
	if encoded ~= PlayerData.Get(player, "SimpleWeaponPackPurchases") then
		PlayerData.Set(player, "SimpleWeaponPackPurchases", encoded)
	end
	return state
end

local function Publish(player: Player, simple: boolean?)
	if not Runtime.Ready(player) then
		return
	end
	local snapshot = Current()
	local state = if simple or ShopConfig.CheckoutMode == "Simple" then SimpleCounters(player) else Counters(player)
	local offers = {}
	if snapshot then
		for _, offer in ipairs(snapshot.Offers) do
			local used = state.Counts[tostring(offer.Index)] or 0
			table.insert(
				offers,
				{ Index = offer.Index, Claimed = used, Remaining = math.max(0, offer.Quantity - used) }
			)
		end
	end
	PlayerData.Set(player,
		"WeaponPacks",
		HttpService:JSONEncode({
			RotationKey = if snapshot then snapshot.RotationKey else "",
			Offers = offers,
			PurchasePending = if ShopConfig.CheckoutMode == "Simple" then PlayerData.Get(player, "SimpleCheckoutPending") == true
				else PlayerData.Get(player, "ManagedCheckoutPending") == true,
			SavePending = FreePending[player] ~= nil,
		})
	)
end

local function SafePublish(player: Player)
	local ok, err = pcall(function()
		Publish(player)
		return true
	end)
	if not ok then
		warn("[WeaponPacks] Display recovery: " .. tostring(err))
	end
end

local function Selected(index: unknown, key: unknown): (Rotation.Offer?, string?)
	if type(index) ~= "number" or index % 1 ~= 0 or type(key) ~= "string" then
		return nil, "InvalidRequest"
	end
	local snapshot = Current()
	if not snapshot or snapshot.RotationKey ~= key then
		return nil, "OfferExpired"
	end
	local offer = snapshot.Offers[index]
	if not offer or not offer.Available then
		return nil, "Unavailable"
	end
	return offer, nil
end

local function GrantWeaponPack(player: Player, reward: PurchaseTypes.Reward, freeClaim: boolean)
	local weapons = PlayerData.Get(player, "OwnedWeapons")
	assert(type(weapons) == "string" and type(reward.Weapon) == "string", "Invalid weapon reward/inventory")
	-- Older saved rewards without a quantity represent one copy.
	local quantity = if reward.Quantity == nil then 1 else reward.Quantity
	assert(
		type(quantity) == "number" and quantity > 0 and quantity < math.huge and quantity % 1 == 0,
		"Invalid saved weapon quantity"
	)
	local copies: { string } = table.create(quantity, reward.Weapon)
	local bundle = table.concat(copies, ",")
	local state = Counters(player)
	if state.RotationKey == reward.RotationKey then
		local key = tostring(reward.Index)
		state.Counts[key] = (state.Counts[key] or 0) + quantity
	end
	PlayerData.Set(player, "OwnedWeapons", if weapons == "" then bundle else weapons .. "," .. bundle)
	AnalyticsService.RecordEconomy(player, {
		Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
		Amount = quantity, Balance = Economy.Total(Economy.ListCounts(weapons)) + quantity, TransactionType = if freeClaim then "Shop" else "IAP",
		ItemSku = reward.Weapon, Activity = "WeaponPack",
	})
	SafePublish(player)
end

local Definition = {
	Legacy = {
		Field = "Weapons",
		Validate = function(raw: any): boolean
			return type(raw) == "table" and type(raw.Weapon) == "string" and type(raw.ProductId) == "number"
		end,
		IsComplete = function(raw: any): boolean
			return true
		end,
		ProductId = function(raw: any): number
			return raw.ProductId
		end,
	},
	Apply = function(player: Player, reward: PurchaseTypes.Reward)
		GrantWeaponPack(player, reward, false)
	end,
}

local function RecoverFree(player: Player)
	Runtime.Schedule(player, "WeaponFreeSave", function()
		local done = Runtime.Run(player, "WeaponFree", function(token)
			local marker = FreePending[player]
			if not marker then
				return true, nil
			end
			if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "WeaponFree", token) then
				return false, "SavePending"
			end
			if FreePending[player] == marker then
				FreePending[player] = nil
			end
			SafePublish(player)
			return true, nil
		end)
		return done
	end)
end

function Service.Claim(player, index, key)
	local done, reason = Runtime.Run(player, "WeaponFree", function(token)
		local previous = FreePending[player]
		if previous then
			if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "WeaponFree", token) then
				return false, "SavePending"
			end
			FreePending[player] = nil
			if previous.Index == index and previous.Key == key then
				return true, nil
			end
		end
		local offer, failure = Selected(index, key)
		if not offer then
			return false, failure
		end
		if offer.ProductId ~= -1 then
			return false, "NotFree"
		end
		local state = Counters(player)
		if (state.Counts[tostring(index)] or 0) >= offer.Quantity then
			return false, "SoldOut"
		end
		GrantWeaponPack(player, { Weapon = offer.Weapon, Index = index, RotationKey = key, Quantity = offer.Quantity }, true)
		local marker = { Index = index, Key = key }
		FreePending[player] = marker
		RecoverFree(player)
		local saved = Data.SavePlayer(player, true)
		if not Runtime.Valid(player, "WeaponFree", token) then
			return false, "TimedOut"
		end
		if saved and FreePending[player] == marker then
			FreePending[player] = nil
		end
		return saved, if saved then nil else "SavePending"
	end)
	SafePublish(player)
	return done, reason
end

function Service.RequestPurchase(player, index, key)
	local offer, reason = Selected(index, key)
	if not offer then
		return false, reason
	end
	if offer.ProductId <= 0 then
		return false, "NotPaid"
	end
	return Checkout.RequestSelf(player, offer.ProductId, { RotationKey = key })
end

local function Refresh()
	-- Schedule FIRST: errors cannot kill the global timer.
	task.delay(1, Refresh)
	local ok, err = pcall(function()
		local snapshot = Current()
		local key = if snapshot then snapshot.RotationKey else ""
		if PublishedKey ~= key then
			ReplicatedValues.Set(ReplicatedStorage,
				"WeaponPacks",
				HttpService:JSONEncode(snapshot or {
					RotationKey = "",
					StartsAt = Config.StartAt,
					EndsAt = 0,
					Offers = {},
				})
			)
			ReplicatedValues.Set(ReplicatedStorage,
				"WeaponPacksNextRefreshTime",
				if snapshot then snapshot.EndsAt else Config.StartAt
			)
			ReplicatedValues.Set(ReplicatedStorage, "WeaponPacksRotationKey", key)
			PublishedKey = key
			for _, player in ipairs(Players:GetPlayers()) do
				SafePublish(player)
			end
		end
	end)
	if not ok then
		warn("[WeaponPacks] Refresh will retry: " .. tostring(err))
	end
end

function Service:Setup(registerPurchase)
	Rotation.Validate(Config, WeaponConfig)
	Receipts.Register("WeaponPack", Definition)
	Registry.RegisterReward("WeaponPack", Definition.Apply)
	local products = {}
	for index, entry in ipairs(Config.List) do
		if entry.ID > 0 then
			products[entry.ID] = { Index = index, Entry = entry }
		end
	end
	for id, entry in pairs(Config.RetiredProducts or {}) do
		products[id] = entry
	end
	Receipts.Products("WeaponPack", products, registerPurchase, function(productId: number, product: any)
		Registry.Register(productId, {
			Kind = "WeaponPack",
			Identity = tostring(product.Index),
			Grant = Definition.Apply,
			SimpleSnapshot = function(buyer, recipient, context)
				local snapshot = Current()
				local offer = snapshot and snapshot.Offers[product.Index]
				if not snapshot or not offer or not offer.Available or offer.ProductId ~= productId then return nil, "Unavailable" end
				if context.RotationKey and context.RotationKey ~= snapshot.RotationKey then return nil, "OfferExpired" end
				local used = SimpleCounters(recipient).Counts[tostring(product.Index)] or 0
				if used > 0 then return nil, "SoldOut" end
				return { Weapon = offer.Weapon, Index = product.Index, RotationKey = snapshot.RotationKey,
					Quantity = offer.Quantity, Limit = offer.Quantity, Used = used }, nil
			end,
			SimpleGrant = function(player, reward)
			local weapons = PlayerData.Get(player, "OwnedWeapons")
				local quantity = reward.Quantity or 1
				assert(type(weapons) == "string" and type(reward.Weapon) == "string"
					and type(quantity) == "number" and quantity > 0 and quantity < math.huge and quantity % 1 == 0,
					"Invalid Simple weapon bundle")
				local bundle = table.concat(table.create(quantity, reward.Weapon), ",")
				local state = SimpleCounters(player)
				if state.RotationKey == reward.RotationKey then
					local slot = tostring(reward.Index)
					state.Counts[slot] = (state.Counts[slot] or 0) + quantity
					-- Mirror only in memory so switching back does not reopen the offer.
					local private = Data.GetPurchaseState(player)
					private.WeaponPacks = { RotationKey = state.RotationKey, Counts = table.clone(state.Counts) }
				end
				local encoded = HttpService:JSONEncode(state)
			PlayerData.Set(player, "OwnedWeapons", if weapons == "" then bundle else weapons .. "," .. bundle)
			PlayerData.Set(player, "SimpleWeaponPackPurchases", encoded)
				AnalyticsService.RecordEconomy(player, {
					Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Weapons",
					Amount = quantity, Balance = Economy.Total(Economy.ListCounts(weapons)) + quantity, TransactionType = "IAP",
					ItemSku = reward.Weapon, Activity = "WeaponPack",
				})
				Publish(player, true)
			end,
			RecoveryReward = function(player: Player)
				local snapshot = Current()
				local offer = snapshot and snapshot.Offers[product.Index]
				if not snapshot or not offer or offer.ProductId ~= productId then return nil, "Unavailable" end
				return { Weapon = offer.Weapon, Index = product.Index, RotationKey = snapshot.RotationKey,
					Quantity = offer.Quantity, Limit = offer.Quantity, Used = 0 }, nil
			end,
			Snapshot = function(
				buyer: Player,
				recipient: Player,
				context: { RotationKey: string? }
			): (BundleReward?, string?)
				local snapshot = Current()
				if not snapshot then
					return nil, "Unavailable"
				end
				local offer = snapshot.Offers[product.Index]
				if not offer or offer.ProductId ~= productId then
					return nil, "Unavailable"
				end
				if context.RotationKey and context.RotationKey ~= snapshot.RotationKey then
					return nil, "OfferExpired"
				end
				local state = Counters(recipient)
				local used = state.Counts[tostring(product.Index)] or 0
				if used > 0 then
					return nil, "SoldOut"
				end
				return {
					Weapon = offer.Weapon,
					Index = product.Index,
					RotationKey = snapshot.RotationKey,
					Quantity = offer.Quantity,
					Limit = offer.Quantity,
					Used = used,
				},
					nil
			end,
			Reservation = function(recipient: Player, reward: BundleReward)
				return {
					Key = reward.RotationKey .. ":" .. reward.Index,
					Limit = reward.Limit,
					Used = reward.Used,
					Amount = reward.Quantity,
				}
			end,
		})
		return function(player: Player, receipt: PurchaseTypes.Receipt): boolean
			return Checkout.TryProcess(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end)
	if not PurchaseRemote then
		local events = ReplicatedStorage.Events
		local remote = events:FindFirstChild("WeaponPackEvent")
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name, remote.Parent = "WeaponPackEvent", events
		end
		assert(remote:IsA("RemoteEvent"), "WeaponPackEvent must be a RemoteEvent")
		PurchaseRemote = remote
	end
	if not FeedbackRemote then
		local events = ReplicatedStorage.Events
		local remote = events:FindFirstChild("WeaponPackFeedbackEvent")
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name, remote.Parent = "WeaponPackFeedbackEvent", events
		end
		assert(remote:IsA("RemoteEvent"), "WeaponPackFeedbackEvent must be a RemoteEvent")
		FeedbackRemote = remote
	end
end

function Service:Start()
	local function feedback(player: Player, status: string)
		if FeedbackRemote and player.Parent == Players then
			FeedbackRemote:FireClient(player, status)
		end
	end
	if PurchaseRemote then
		PurchaseRemote.OnServerEvent:Connect(function(player, index, key)
			if not Runtime.Ready(player) then
				feedback(player, "DataNotLoaded")
				return
			end
			if os.clock() < (NextRequest[player] or 0) then
				feedback(player, "RateLimited")
				return
			end
			NextRequest[player] = os.clock() + 1
			local offer = Selected(index, key)
			local success, reason
			if offer and offer.ProductId == -1 then
				success, reason = Service.Claim(player, index, key)
			else
				success, reason = Service.RequestPurchase(player, index, key)
			end
			local status = if success
				then (if offer and offer.ProductId == -1 then "Claimed" else "PromptOpen")
				else reason or "Unavailable"
			feedback(player, status)
		end)
	end
	local function watch(player: Player)
		Connections[player] = {
			PlayerData.Observe(player, "DataLoaded", function()
				SafePublish(player)
			end),
			PlayerData.Observe(player, "ManagedCheckoutPending", function()
				SafePublish(player)
			end),
			PlayerData.Observe(player, "SimpleCheckoutPending", function()
				SafePublish(player)
			end),
		}
		SafePublish(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		for _, connection in ipairs(Connections[player] or {}) do
			connection:Disconnect()
		end
		Connections[player], FreePending[player], NextRequest[player] = nil, nil, nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	Initialized = true
	Refresh()
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
