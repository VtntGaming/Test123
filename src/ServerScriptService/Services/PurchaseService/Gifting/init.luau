--!strict
-- Delivers paid gift inbox entries through product-owned grants and saves recipient deduplication markers.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PurchaseTypes = require(Services.PurchaseService.Types)
local Data = require(Services.PlayerDataService)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Checkout = require(Services.PurchaseService.Checkout)
local Checkouts = require(Services.PurchaseService.Checkout.Store)
local Inbox = require(Services.PurchaseService.Gifting.Store)
local GiftConfig = require(ReplicatedStorage.SharedModules.GiftConfig)
local Simple = require(Services.PurchaseService.Simple)

--// Properties
local Initialized = false
local Delivering: { [number]: boolean } = {}
local Connections: { [Player]: RBXScriptConnection } = {}

--// Types
export type Gifting = {
	IsGiftProduct: (productId: number) -> boolean,
	RequestGift: (buyer: Player, recipient: unknown, productId: number, context: unknown?) -> (boolean, string?),
	TryProcess: (receipt: PurchaseTypes.Receipt) -> PurchaseTypes.Decision?,
	DeliverRecipient: (player: Player) -> (),
	Setup: (self: Gifting) -> (),
	Start: (self: Gifting) -> (),
	Init: () -> (),
}

--// Service
local GiftService = {} :: Gifting

--// APIs
local function Ready(player: Player)
	return player and player.Parent == Players and player:GetAttribute("DataLoaded") == true
end

local function GrantAttribute(player: Player, reward: PurchaseTypes.Reward)
	player:SetAttribute(reward.Attribute, true)
end

function GiftService.IsGiftProduct(productId)
	local definition = Registry.Get(productId)
	return definition ~= nil and definition.GiftAllowed ~= false
end

function GiftService.RequestGift(buyer, recipient, productId, context)
	return Checkout.RequestGift(buyer, recipient, productId, context)
end

-- Compatibility entry point; PurchaseService routes all managed receipts via CheckoutService.
function GiftService.TryProcess(receipt)
	return Checkout.TryProcess(receipt)
end

local function DeliverOne(player: Player, intent: PurchaseTypes.Intent)
	if intent.Strategy == "Simple" then
		return Simple.Deliver(player, intent)
	end
	if not Ready(player) then
		return false
	end
	local receipt = Checkouts.GetReceipt(assert(intent.PurchaseId))
	if receipt and receipt.Delivered then
		intent.Delivered = true
	end
	if not intent.Delivered then
		local encoded = player:GetAttribute("ProcessedGiftReceipts")
		assert(type(encoded) == "string", "Missing gift receipt history")
		local processed = Http:JSONDecode(encoded)
		assert(type(processed) == "table", "Invalid gift receipt history")
		if not processed[intent.PurchaseId] then
			local grant = assert(Registry.GetGrant(intent.Reward.Kind), "Gift reward handler not ready")
			-- Reward mutation and deduplication marker must not yield.
			grant(player, intent.Reward)
			processed[intent.PurchaseId] = true
			player:SetAttribute("ProcessedGiftReceipts", Http:JSONEncode(processed))
		end
		if not Data.SavePlayer(player, true) then
			return false
		end
		Inbox.Delivered(intent)
	end
	Checkouts.CommitReservation(intent)
	Checkouts.MarkDelivered(intent)
	-- Receipt.Delivered is durable before removing the profile deduplication marker.
	local encoded = player:GetAttribute("ProcessedGiftReceipts")
	assert(type(encoded) == "string", "Missing gift receipt history")
	local processed = Http:JSONDecode(encoded)
	if processed[intent.PurchaseId] then
		processed[intent.PurchaseId] = nil
		player:SetAttribute("ProcessedGiftReceipts", Http:JSONEncode(processed))
		if not Data.SavePlayer(player, true) then
			return false
		end
	end
	Inbox.Finalize(intent)
	Checkout.Notify(intent, "Delivered", intent.Reward.Amount)
	return true
end

function GiftService.DeliverRecipient(player)
	if not Ready(player) or Delivering[player.UserId] then
		return
	end
	Delivering[player.UserId] = true
	local ok, err = pcall(function()
		for _, intent in pairs(Inbox.GetInbox(player.UserId)) do
			if not Ready(player) then
				return true
			end
			do -- Also compact legacy finalized entries after confirming durable delivery.
				local delivered, deliveryError = pcall(DeliverOne, player, intent)
				if not delivered then
					warn(
						"[GiftService] Gift "
							.. tostring(intent.PurchaseId)
							.. " will retry: "
							.. tostring(deliveryError)
					)
				end
			end
		end
		return true
	end)
	Delivering[player.UserId] = nil
	if not ok then
		warn("[GiftService] Delivery will retry: " .. tostring(err))
	end
end

local function Watch(player: Player)
	if Connections[player] then
		return
	end
	local function deliver()
		if Ready(player) then
			task.spawn(GiftService.DeliverRecipient, player)
		end
	end
	Connections[player] = player:GetAttributeChangedSignal("DataLoaded"):Connect(deliver)
	deliver()
end

function GiftService:Setup()
	for productId, info in pairs(GiftConfig) do
		assert(
			type(info.Attribute) == "string"
				and (
					type(Data.DefaultAttributes[info.Attribute]) == "boolean"
					or string.sub(info.Attribute, 1, 6) == "Owned_"
				),
			"Gift attributes must be persistent flags"
		)
		Registry.Register(productId, {
			Kind = "Attribute",
			Identity = info.Attribute,
			SelfAllowed = false,
			Grant = GrantAttribute,
			SimpleRecovery = function()
				return { Attribute = info.Attribute }, nil
			end,
			Snapshot = function(buyer, recipient)
				if recipient:GetAttribute(info.Attribute) == true then
					return nil, "AlreadyOwned"
				end
				return { Attribute = info.Attribute }
			end,
			Reservation = function()
				return { Key = "Attribute:" .. info.Attribute, Limit = 1, Used = 0 }
			end,
		})
	end
end

function GiftService:Start()
	Checkout.Init()
	Checkout.OnGiftQueued(function(intent)
		local recipient = Players:GetPlayerByUserId(intent.RecipientId)
		if Ready(recipient) then
			GiftService.DeliverRecipient(recipient)
		end
	end)
	ReplicatedStorage.Events.PendingGiftEvent.OnServerEvent:Connect(GiftService.RequestGift)
	Players.PlayerAdded:Connect(Watch)
	Players.PlayerRemoving:Connect(function(player)
		if Connections[player] then
			Connections[player]:Disconnect()
		end
		Connections[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		Watch(player)
	end
	task.spawn(function()
		while task.wait(30) do
			for _, player in ipairs(Players:GetPlayers()) do
				if Ready(player) then
					task.spawn(GiftService.DeliverRecipient, player)
				end
			end
		end
	end)
end

function GiftService.Init()
	if Initialized then
		return
	end
	GiftService:Setup()
	GiftService:Start()
	Initialized = true
end

return GiftService
