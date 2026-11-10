--!strict
-- Manages gift checkout UI and displays confirmed incoming gifts through the shop celebration.

--// Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local Notification = require(ReplicatedStorage.Utils.NotificationUtil)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local PlayerCard = require(script.PlayerCard)
local UIInteractionController = require(script.Parent.UIInteractionController)
local ShopEffectController = require(script.Parent.ShopEffectController)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainGui = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local GiftPlayersFrame = MainGui:WaitForChild("GiftPlayersFrame")
local ScrollingFrame = GiftPlayersFrame:WaitForChild("ScrollingFrame")
local Template = ScrollingFrame:WaitForChild("Template")
local PendingGiftRemote = ReplicatedStorage.Events.PendingGiftEvent
local ReceivedGifts: { [string]: boolean } = {}

--// Properties
local Messages: { [string]: string } = {
	InvalidRecipient = "That player is no longer ready to receive a gift.",
	InvalidRequest = "This gift request is invalid.",
	NotGiftable = "This item cannot be gifted.",
	AlreadyOwned = "That player already owns this pass.",
	AlreadyClaimed = "That player already claimed this offer.",
	RecipientLimitReached = "That player's remaining allowance is already claimed or reserved.",
	SoldOut = "That player has no remaining allowance for this offer.",
	OfferExpired = "The offer changed. Please select it again.",
	PurchasePending = "Finish your current checkout before starting another.",
	RateLimited = "Please wait a moment before trying again.",
	StorageUnavailable = "Checkout could not be saved. Please try again.",
	OwnershipUnavailable = "Pass ownership is still being checked. Please try again.",
	PolicyUnavailable = "Purchase eligibility could not be checked.",
	PaidRandomItemsRestricted = "This purchase is unavailable for the buyer or recipient.",
	PromptFailed = "The purchase prompt could not be confirmed. Your checkout is kept pending.",
	Unavailable = "This offer is unavailable.",
	PlayerLeft = "A player left before checkout could open.",
	BuyerLeft = "Checkout could not open.",
	DataNotLoaded = "That player's data is still loading. Please try again.",
}

--// Types
export type PurchaseContext = {
	RotationKey: string?,
}

type ServerResult = {
	ClientRequestId: string?,
	Status: string?,
}

export type GiftController = {
	IsInit: boolean,
	IsOpen: boolean,
	Started: boolean,
	ProductId: number?,
	Context: PurchaseContext,
	Sending: string?,
	Requests: { [string]: string },
	PlayerCards: { PlayerCard.PlayerCard },
	Init: () -> (),
	Setup: (self: GiftController) -> (),
	Start: (self: GiftController) -> (),
	Refresh: (self: GiftController) -> (),
	Open: (self: GiftController, productId: number, offerContext: PurchaseContext?) -> (),
	Close: (self: GiftController) -> (),
	SendGift: (self: GiftController, playerName: string) -> (),
}

--// Controller
local Controller = {
	IsInit = false,
	IsOpen = false,
	Started = false,
	ProductId = nil :: number?,
	Context = {} :: PurchaseContext,
	Sending = nil :: string?,
	Requests = {} :: { [string]: string },
	PlayerCards = {} :: { PlayerCard.PlayerCard },
} :: GiftController

--// APIs
function Controller:Refresh()
	for _, card in ipairs(self.PlayerCards) do
		card:Destroy()
	end
	table.clear(self.PlayerCards)

	if not self.IsOpen then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local card = PlayerCard.new(player, ScrollingFrame, Template)
			card.Activated:Connect(function(playerName)
				self:SendGift(playerName)
			end)
			table.insert(self.PlayerCards, card)
		end
	end
end

function Controller:Setup()
	Template.Visible = false
end

function Controller:Start()
	if self.Started then
		return
	end
	self.Started = true

	GiftPlayersFrame.ExitButton.Activated:Connect(function()
		self:Close()
	end)

	Players.PlayerAdded:Connect(function()
		if self.IsOpen then
			self:Refresh()
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		for index = #self.PlayerCards, 1, -1 do
			local card = self.PlayerCards[index]
			if card.Player == player then
				card:Destroy()
				table.remove(self.PlayerCards, index)
			end
		end
	end)

	PendingGiftRemote.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then
			return
		end
		-- Incoming gifts are independent of this player's outgoing checkout requests.
		if result.Status == "Received" then
			if type(result.RequestId) ~= "string" or type(result.Description) ~= "string" then
				return
			end
			if ReceivedGifts[result.RequestId] then
				return
			end
			ReceivedGifts[result.RequestId] = true
			ShopEffectController:ShowEffect("GIFT RECEIVED!", result.Description)
			return
		end

		local serverResult = result :: ServerResult
		local token = serverResult.ClientRequestId
		local status = serverResult.Status
		if type(token) ~= "string" or type(status) ~= "string" then
			return
		end
		local finalRelease = status == "CheckoutReleased" and type(result.Details) == "table" and result.Details.Final == true
		if not self.Requests[token] or (self.Requests[token] == status and not finalRelease) then
			return
		end

		self.Requests[token] = status
		if self.Sending == token and status == "PromptOpen" then
			self:Close()
		end

		local rejected = status ~= "PromptOpen"
			and status ~= "SavePending"
			and status ~= "CheckoutReleased"
			and status ~= "Queued"
			and status ~= "Delivered"
			and status ~= "Cancelled"
		if status == "Queued" or status == "Delivered" or status == "Cancelled" or status == "CheckoutReleased" or rejected then
			if self.Sending == token then
				self.Sending = nil
			end
		end

		if status == "SavePending" then
			Notification.Show("Info", "Your gift is pending recovery. Please wait; do not buy it again.")
		elseif status == "Queued" then
			Notification.Show("Info", "Gift paid and safely queued for delivery.")
		elseif status == "Delivered" then
			Notification.Show("Success", "Your gift was delivered!")
		elseif status == "Cancelled" then
			Notification.Show("Info", "Gift purchase cancelled.")
		elseif Messages[status] then
			Notification.Show("Warning", Messages[status])
		elseif rejected then
			Notification.Show("Warning", "This gift could not be started. Please try again.")
		end

		if status == "Delivered" or status == "Cancelled" or finalRelease or rejected then
			self.Requests[token] = nil
		end
	end)
end

function Controller:Open(productId: number, offerContext: PurchaseContext?)
	if self.Sending or PlayerData.Get(LocalPlayer, "SimpleCheckoutPending") == true
		or (RobuxShopConfig.CheckoutMode ~= "Simple" and PlayerData.Get(LocalPlayer, "ManagedCheckoutPending") == true) then
		Notification.Show("Warning", Messages.PurchasePending)
		return
	end

	assert(productId > 0, "Gift product ID must be positive")
	self.ProductId = productId
	self.Context = offerContext or {}
	self.IsOpen = true
	self:Refresh()
	UIInteractionController.ToggleFrame(GiftPlayersFrame, true)
end

function Controller:Close()
	self.IsOpen = false
	self.ProductId = nil
	self.Context = {}
	self:Refresh()
	UIInteractionController.ToggleFrame(GiftPlayersFrame, false)
end

function Controller:SendGift(playerName: string)
	local productId = self.ProductId
	if self.Sending or not productId then
		return
	end

	local recipient = Players:FindFirstChild(playerName)
	if not recipient or not recipient:IsA("Player") or PlayerData.Get(recipient, "DataLoaded") ~= true then
		Notification.Show("Warning", Messages.InvalidRecipient)
		return
	end

	local requestId = HttpService:GenerateGUID(false)
	self.Sending = requestId
	self.Requests[requestId] = "Requested"
	PendingGiftRemote:FireServer(recipient, productId, {
		ClientRequestId = requestId,
		RotationKey = self.Context.RotationKey,
	})
end

function Controller.Init()
	if Controller.IsInit then
		return
	end
	Controller.IsInit = true
	Controller:Setup()
	Controller:Start()
end

return Controller
