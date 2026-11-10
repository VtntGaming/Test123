--!strict
-- Coordinates prompt-first or durable checkouts, immutable receipt routing, and recovery.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Http = game:GetService("HttpService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Store = require(Services.PurchaseService.Checkout.Store)
local Inbox = require(Services.PurchaseService.Gifting.Store)
local Receipts = require(Services.PurchaseService.Receipts)
local Runtime = require(Services.Helper.ShopRuntime)
local Config = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local Fast = require(Services.PurchaseService.Checkout.Fast)
local Recovery = require(Services.PurchaseService.Checkout.Recovery)
local Simple = require(Services.PurchaseService.Simple)

--// Properties
local Initialized = false
local Requesting: { [number]: boolean } = {}
local CreatingDrafts: { [number]: string } = {}
local ObservingReceipts: { [number]: number } = {}
local UnresolvedObservations: {
	[number]: { [string]: { Receipt: PurchaseTypes.Receipt, ExcludedRequestId: string? } },
} =
	{}
local Prompts: { [number]: PurchaseTypes.Intent } = {}
local NextRequest: { [number]: number } = {}
local Connections: { [Player]: PlayerData.Connection } = {}
local RecoveredPending: { [number]: PurchaseTypes.Intent? } = {}
local StateVersions: { [number]: number } = {}
local SelfRemote: RemoteEvent? = nil
local GiftRemote: RemoteEvent? = nil
local GiftQueued: ((PurchaseTypes.Intent) -> ())? = nil
local MAX_UNRESOLVED_OBSERVATIONS = 2048
local UnresolvedCount = 0
local PendingReceipts: { [string]: { Receipt: PurchaseTypes.Receipt, NextAttempt: number } } = {}
local ProcessingReceipts: { [string]: boolean } = {}
local PendingCount = 0
local RecoverBuyer: (Player, boolean?) -> PurchaseTypes.Intent?

--// Types
export type Checkout = {
	OnGiftQueued: (callback: (PurchaseTypes.Intent) -> ()) -> (),
	Notify: (intent: PurchaseTypes.Notification, status: string, details: unknown?) -> (),
	RequestSelf: (buyer: Player, productId: number, clientContext: unknown?) -> (boolean, string?),
	RequestGift: (buyer: Player, recipient: unknown, productId: number, clientContext: unknown?) -> (boolean, string?),
	TryProcess: (receipt: PurchaseTypes.Receipt) -> PurchaseTypes.Decision?,
	ResumePending: (buyer: Player) -> (boolean, string?),
	Setup: (self: Checkout) -> (),
	Start: (self: Checkout) -> (),
	Init: () -> (),
}

--// Service
local Checkout = {} :: Checkout

--// APIs
function Checkout.OnGiftQueued(callback)
	assert(not GiftQueued or GiftQueued == callback, "Gift queue listener already registered")
	GiftQueued = callback
end

local function Ready(player: Player)
	return player and player.Parent == Players and PlayerData.Get(player, "DataLoaded") == true
end

local function PositiveId(id: unknown)
	return type(id) == "number" and id > 0 and id < math.huge and id % 1 == 0
end

local function HasReceiptObservation(buyerId: number)
	return ObservingReceipts[buyerId] ~= nil or UnresolvedObservations[buyerId] ~= nil
end

local function Context(value: unknown): PurchaseTypes.Context?
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil
	end
	local entries = value :: { [string]: unknown }
	local result: { [string]: string } = {}
	for _, key in ipairs({ "ClientRequestId", "RotationKey" }) do
		if entries[key] ~= nil then
			local entry = entries[key]
			if type(entry) ~= "string" or #entry > 128 then
				return nil
			end
			result[key] = entry
		end
	end
	return { ClientRequestId = result.ClientRequestId, RotationKey = result.RotationKey }
end

local function Changed(buyerId: number)
	StateVersions[buyerId] = (StateVersions[buyerId] or 0) + 1
end

local function RefreshFlags(buyer: Player)
	if buyer.Parent ~= Players then
		return
	end
	local buyerId = buyer.UserId
	local pending = Prompts[buyerId] or Fast.Current(buyerId) or RecoveredPending[buyerId]
	local resumable = pending ~= nil
		and pending.Prompted
		and not pending.PaymentReported
		and not pending.PurchaseId
		and Prompts[buyerId] == nil
	PlayerData.Set(buyer, "ManagedCheckoutPending", pending ~= nil)
	PlayerData.Set(buyer, "CheckoutResumeAvailable", resumable)
	PlayerData.Set(buyer, "PendingCheckoutProductId", if pending then pending.ProductId else nil)
	PlayerData.Set(buyer, "PendingCheckoutRecipientId", if pending then pending.RecipientId else nil)
	local reward = pending and pending.Reward
	PlayerData.Set(buyer,
		"PendingCheckoutDescription",
		if reward
			then tostring(
				reward.Item
					or reward.Weapon
					or reward.Pack
					or reward.ChestId
					or reward.PassName
					or reward.Ability
					or "purchase"
			)
			else nil
	)
end

local function DescribeGift(reward: PurchaseTypes.Reward?): string
	if not reward then
		return "a gift"
	end
	if reward.Kind == "CoinPack" then
		local amount = reward.Amount
		if type(amount) == "number" then
			return tostring(math.round(amount)) .. " Coins"
		end
		return tostring(reward.Value) .. " Coin Pack"
	elseif reward.Kind == "WeaponPack" then
		return tostring(reward.Quantity or 1) .. "x " .. tostring(reward.Weapon)
	elseif reward.Kind == "LimitedItem" then
		return tostring(reward.Item)
	elseif reward.Kind == "LuckyChest" then
		local name = string.gsub(tostring(reward.ChestId), "^LuckyChest:", "")
		return tostring(reward.Quantity or 1) .. "x " .. name .. " Chest"
	elseif reward.Kind == "Pass" then
		return tostring(reward.PassName) .. " Pass"
	elseif reward.Kind == "Attribute" then
		local name = string.gsub(tostring(reward.Attribute), "^Owned_", "")
		return (string.gsub(name, "_", " "))
	end
	return tostring(reward.Item or reward.Weapon or reward.ChestId or reward.PassName or "a gift")
end

function Checkout.Notify(intent, status, details)
	local simple = intent.Strategy == "Simple"
	if not simple and status == "Delivered" then
		Fast.Delivered(intent)
	end
	if not simple and (status == "Cancelled" or status == "CheckoutReleased") then
		Changed(intent.BuyerId)
		local prompt = Prompts[intent.BuyerId]
		if prompt and prompt.RequestId == intent.RequestId then
			Prompts[intent.BuyerId] = nil
		end
		local recovered = RecoveredPending[intent.BuyerId]
		if recovered and recovered.RequestId == intent.RequestId then
			RecoveredPending[intent.BuyerId] = nil
		end
	end
	-- Recipient feedback must also work when the buyer has left or is in another server.
	if intent.Mode == "Gift" and status == "Delivered" and intent.RecipientId and GiftRemote then
		local recipient = Players:GetPlayerByUserId(intent.RecipientId)
		if recipient then
			GiftRemote:FireClient(recipient, {
				Status = "Received",
				RequestId = intent.RequestId,
				Description = DescribeGift(intent.Reward),
			})
		end
	end
	local buyer = Players:GetPlayerByUserId(intent.BuyerId)
	if not buyer then
		return
	end
	if not simple and (status == "Cancelled" or status == "CheckoutReleased") then
		RefreshFlags(buyer)
		Runtime.Schedule(buyer, "CheckoutRecovery", function()
			RecoverBuyer(buyer)
			return not Requesting[buyer.UserId]
		end)
	end
	local remote = if intent.Mode == "Self" then SelfRemote else GiftRemote
	if remote then
		remote:FireClient(buyer, {
			ClientRequestId = intent.ClientRequestId,
			RequestId = intent.RequestId,
			ProductId = intent.ProductId,
			RecipientId = intent.RecipientId,
			Status = status,
			Details = details,
		})
	end
	if intent.Mode ~= "Self" then
		PlayerData.Set(buyer, "GiftRequestStatus", status)
	end
end

local function CleanupCancelled(intent: PurchaseTypes.Intent)
	if intent.Strategy ~= "Fast" then
		Store.Release(intent)
	end
	Store.CleanCancelled(intent)
end

local function Cancel(intent: PurchaseTypes.Intent)
	if intent.Strategy == "Fast" then
		return Store.CancelFast(intent)
	end
	if not Store.Cancel(intent.BuyerId, intent.RequestId) then
		return false
	end
	CleanupCancelled(intent)
	return true
end

RecoverBuyer = function(buyer: Player, requestPreflight: boolean?)
	local version = StateVersions[buyer.UserId]
	-- A cached pre-settlement record must not recreate a gate after another server closed it.
	local record = Store.GetBuyer(buyer.UserId, true)
	-- A draft is not abandoned while its creation/reservation write is still running.
	-- Check after the read: a request may have started while GetBuyer yielded.
	if Requesting[buyer.UserId] and not requestPreflight then
		return record.Active
	end
	if version ~= StateVersions[buyer.UserId] then
		return Prompts[buyer.UserId] or Fast.Current(buyer.UserId) or RecoveredPending[buyer.UserId]
	end
	local runtime = Fast.Current(buyer.UserId)
	if
		runtime
		and not Prompts[buyer.UserId]
		and (
			(record.FastClosed and record.FastClosed[runtime.RequestId])
			or (record.RecoveryPending and record.RecoveryPending[runtime.RequestId])
		)
	then
		Fast.Retire(runtime, record.FastClosed ~= nil and record.FastClosed[runtime.RequestId] ~= nil)
		version = StateVersions[buyer.UserId]
	end
	for _, intent in pairs(record.Cancelled or {}) do
		local ok = pcall(CleanupCancelled, intent)
		if not ok then
			Runtime.Schedule(buyer, "CheckoutCancelled:" .. intent.RequestId, function()
				CleanupCancelled(intent)
				return true
			end)
		end
	end
	local active = record.Active
	-- Resume one unpaid selection at a time; never hide recovery just because several survived a crash.
	for _, candidate in pairs(record.FastPending or {}) do
		if
			not candidate.PaymentReported
			and not candidate.PurchaseId
			and (
				not active
				or candidate.CreatedAt < active.CreatedAt
				or (candidate.CreatedAt == active.CreatedAt and candidate.RequestId < active.RequestId)
			)
		then
			active = candidate
		end
	end
	if active then
		local receipt = active.PurchaseId and Store.GetReceipt(active.PurchaseId)
		if receipt and receipt.Complete then
			Store.Complete(receipt)
			active = nil
		elseif not active.Prompted and not active.PurchaseId and Cancel(active) then
			active = nil
		end
	end
	if version ~= StateVersions[buyer.UserId] then
		return Prompts[buyer.UserId] or Fast.Current(buyer.UserId) or RecoveredPending[buyer.UserId]
	end
	if buyer.Parent == Players then
		RecoveredPending[buyer.UserId] = active
		RefreshFlags(buyer)
	end
	return active
end

function Checkout.ResumePending(buyer)
	if not Ready(buyer) or HasReceiptObservation(buyer.UserId) or Requesting[buyer.UserId] or Prompts[buyer.UserId] then
		return false, "PurchasePending"
	end
	if os.clock() < (NextRequest[buyer.UserId] or 0) then
		return false, "RateLimited"
	end
	NextRequest[buyer.UserId] = os.clock() + 1
	Requesting[buyer.UserId] = true
	Changed(buyer.UserId)
	local ok, opened, reason = pcall(function()
		local cached = Fast.Current(buyer.UserId) or RecoveredPending[buyer.UserId]
		local active = if cached and cached.Strategy == "Fast"
			then cached
			elseif Config.CheckoutMode == "Fast" and not cached then nil
			else RecoverBuyer(buyer, true)
		if not active or not active.Prompted or active.PaymentReported or active.PurchaseId then
			return false, "Unavailable"
		end
		if not Ready(buyer) then
			return false, "PlayerLeft"
		end
		-- Reuse the saved selection/reservation. Never substitute the current rotating offer.
		if active.Strategy == "Fast" and not Fast.Current(buyer.UserId) then
			local registered = Fast.Register(active)
			if not registered then
				return false, "PurchasePending"
			end
		end
		Prompts[buyer.UserId] = active
		Changed(buyer.UserId)
		MarketplaceService:PromptProductPurchase(buyer, active.ProductId)
		PlayerData.Set(buyer, "CheckoutResumeAvailable", false)
		return true, "PromptOpen"
	end)
	Requesting[buyer.UserId] = nil
	if not ok then
		Prompts[buyer.UserId] = nil
		RefreshFlags(buyer)
		return false, "PromptFailed"
	end
	return opened, reason
end

local function Request(
	buyer: Player,
	recipient: Player,
	productId: number,
	clientContext: PurchaseTypes.Context,
	mode: PurchaseTypes.Mode,
	fastEnabled: boolean
): (boolean, string?)
	if not Ready(buyer) or not Ready(recipient) or (mode == "Gift" and buyer == recipient) then
		return false, "InvalidRecipient"
	end
	local definition = Registry.Get(productId)
	if
		not definition
		or definition.SimpleOnly == true
		or (mode == "Self" and definition.SelfAllowed == false)
		or (mode == "Gift" and definition.GiftAllowed == false)
	then
		return false, "NotGiftable"
	end
	if
		Prompts[buyer.UserId]
		or Fast.Current(buyer.UserId)
		or (fastEnabled and PlayerData.Get(buyer, "ManagedCheckoutPending") == true)
		or (not fastEnabled and not Store.IsBuyerIdle(buyer.UserId) and RecoverBuyer(buyer, true))
	then
		return false, "PurchasePending"
	end
	local reward, reason = definition.Snapshot(buyer, recipient, clientContext, mode)
	if not reward then
		return false, reason or "Unavailable"
	end
	if HasReceiptObservation(buyer.UserId) then
		return false, "PurchasePending"
	end
	reward.Kind = definition.Kind
	if fastEnabled then
		reward.HonorPaid = true
	end
	local reservation = definition.Reservation and definition.Reservation(recipient, reward)
	if reservation then
		local amount = if reservation.Amount == nil then 1 else reservation.Amount
		assert(
			type(reservation.Key) == "string"
				and type(reservation.Limit) == "number"
				and reservation.Limit > 0
				and reservation.Limit < math.huge
				and reservation.Limit % 1 == 0
				and type(reservation.Used) == "number"
				and reservation.Used >= 0
				and reservation.Used < math.huge
				and reservation.Used % 1 == 0
				and type(amount) == "number"
				and amount > 0
				and amount < math.huge
				and amount % 1 == 0,
			"Invalid product reservation"
		)
		local generation = PlayerData.Get(recipient, "PurchaseAllowanceGeneration")
		if type(generation) == "string" and generation ~= "" then
			-- Reset only future allowances. Saved intents retain their original reservation and receipt evidence.
			reservation = table.clone(reservation)
			reservation.Key = reservation.Key .. ":Profile:" .. generation
		end
	end
	local intent: PurchaseTypes.Intent = {
		RequestId = Http:GenerateGUID(false),
		BuyerId = buyer.UserId,
		RecipientId = recipient.UserId,
		ProductId = productId,
		Mode = mode,
		Reward = reward,
		Reservation = reservation,
		ClientRequestId = clientContext.ClientRequestId,
		CreatedAt = os.time(),
		-- Fast selections are immediately prompt-ready. Durable quota purchases
		-- retain their draft -> reserve -> prompted sequence before opening Roblox UI.
		Prompted = fastEnabled or reservation == nil,
		Strategy = if fastEnabled then "Fast" else nil,
	}
	CreatingDrafts[buyer.UserId] = intent.RequestId
	if fastEnabled then
		local registered, rejected = Fast.Register(intent)
		if not registered then
			return false, rejected
		end
	elseif not Store.Begin(intent) then
		-- An idle cache hint may be stale. The atomic write remains authoritative;
		-- recover the original checkout instead of replacing its recipient/reward.
		RecoverBuyer(buyer, true)
		return false, "PurchasePending"
	end
	PlayerData.Set(buyer, "ManagedCheckoutPending", true)
	if not fastEnabled and not Store.Reserve(intent) then
		Cancel(intent)
		PlayerData.Set(buyer, "ManagedCheckoutPending", false)
		return false, "RecipientLimitReached"
	end
	if not Ready(buyer) or not Ready(recipient) then
		if fastEnabled then
			Fast.Cancel(intent)
		else
			Cancel(intent)
		end
		if buyer.Parent == Players then
			PlayerData.Set(buyer, "ManagedCheckoutPending", false)
		end
		return false, "PlayerLeft"
	end
	if not intent.Prompted and not Store.MarkPrompted(intent) then
		return false, "PurchasePending"
	end
	if not Ready(buyer) then
		Cancel(intent)
		return false, "BuyerLeft"
	end
	Prompts[buyer.UserId] = intent
	if mode == "Gift" then
		PlayerData.Set(buyer, "PendingGiftRecipientId", recipient.UserId)
		PlayerData.Set(buyer, "PendingGiftProductId", productId)
	end
	local ok, err = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, buyer, productId)
	if fastEnabled then
		Fast.Queue(intent)
	end
	if not ok then
		-- Opening may have reached Roblox: retain intent instead of guessing payment outcome.
		warn("[Checkout] Prompt uncertain: " .. tostring(err))
		Prompts[buyer.UserId] = nil
		Runtime.Schedule(buyer, "CheckoutRecovery", function()
			RecoverBuyer(buyer)
			return true
		end)
		return false, "PromptFailed"
	end
	Checkout.Notify(intent, "PromptOpen")
	return true, "PromptOpen"
end

local function RequestProtected(
	buyer: Player,
	recipient: Player,
	productId: number,
	rawContext: unknown,
	mode: PurchaseTypes.Mode
): (boolean, string?)
	local clientContext = Context(rawContext)
	local failure = {
		BuyerId = buyer.UserId,
		RecipientId = recipient and recipient.UserId,
		ProductId = productId,
		Mode = mode,
		ClientRequestId = clientContext and clientContext.ClientRequestId,
	}
	local function reject(reason: string)
		Checkout.Notify(failure, reason)
		return false, reason
	end
	if not PositiveId(productId) or not clientContext then
		return reject("InvalidRequest")
	end
	if Requesting[buyer.UserId] or HasReceiptObservation(buyer.UserId) then
		return reject("PurchasePending")
	end
	if os.clock() < (NextRequest[buyer.UserId] or 0) then
		return reject("RateLimited")
	end
	NextRequest[buyer.UserId] = os.clock() + 1
	Requesting[buyer.UserId] = true
	Changed(buyer.UserId)
	local fastEnabled = Config.CheckoutMode == "Fast"
	local ok, success, reason = pcall(Request, buyer, recipient, productId, clientContext, mode, fastEnabled)
	Requesting[buyer.UserId] = nil
	CreatingDrafts[buyer.UserId] = nil
	if not ok then
		warn("[Checkout] Request failed: " .. tostring(success))
		Runtime.Schedule(buyer, "CheckoutRecovery", function()
			RecoverBuyer(buyer)
			return not Requesting[buyer.UserId]
		end)
		return reject("StorageUnavailable")
	end
	if not success then
		Checkout.Notify(failure, reason or "Unavailable")
	end
	return success, reason
end

local function RejectSimplePrompt(buyer: Player, productId: number, rawContext: unknown, mode: PurchaseTypes.Mode): (boolean, string?)
	local parsed = Context(rawContext)
	Checkout.Notify({ BuyerId = buyer.UserId, ProductId = productId, Mode = mode, Strategy = "Simple",
		ClientRequestId = parsed and parsed.ClientRequestId }, "PurchasePending")
	return false, "PurchasePending"
end

function Checkout.RequestSelf(buyer, productId, clientContext)
	if PlayerData.Get(buyer, "SimpleCheckoutPending") == true then
		return RejectSimplePrompt(buyer, productId, clientContext, "Self")
	end
	if Config.CheckoutMode == "Simple" then
		if Prompts[buyer.UserId] then return RejectSimplePrompt(buyer, productId, clientContext, "Self") end
		return Simple.Request(buyer, buyer, productId, clientContext, "Self")
	end
	return RequestProtected(buyer, buyer, productId, clientContext, "Self")
end

function Checkout.RequestGift(buyer, recipient, productId, clientContext)
	if PlayerData.Get(buyer, "SimpleCheckoutPending") == true then
		return RejectSimplePrompt(buyer, productId, clientContext, "Gift")
	end
	if typeof(recipient) ~= "Instance" or not recipient:IsA("Player") then
		local safeContext = Context(clientContext)
		Checkout.Notify(
			{ BuyerId = buyer.UserId, Mode = "Gift", ClientRequestId = safeContext and safeContext.ClientRequestId },
			"InvalidRecipient"
		)
		return false, "InvalidRecipient"
	end
	if Config.CheckoutMode == "Simple" then
		if Prompts[buyer.UserId] then return RejectSimplePrompt(buyer, productId, clientContext, "Gift") end
		return Simple.Request(buyer, recipient, productId, clientContext, "Gift")
	end
	return RequestProtected(buyer, recipient, productId, clientContext, "Gift")
end

local function ObserveReceipt(receipt: PurchaseTypes.Receipt): PurchaseTypes.Intent?
	local buyerId = receipt.PlayerId
	if
		not (UnresolvedObservations[buyerId] and UnresolvedObservations[buyerId][receipt.PurchaseId])
		and UnresolvedCount >= MAX_UNRESOLVED_OBSERVATIONS
	then
		-- Fail closed rather than retaining unbounded state or guessing a route. Existing work still drains.
		error("Checkout observation capacity reached; receipt will retry")
	end
	ObservingReceipts[buyerId] = (ObservingReceipts[buyerId] or 0) + 1
	-- A receipt first seen before a draft reaches its prompt cannot pay for that draft,
	-- even if MarkPrompted finishes while the receipt's storage lookup is yielding.
	local pending = UnresolvedObservations[buyerId] or {}
	UnresolvedObservations[buyerId] = pending
	local observation = pending[receipt.PurchaseId]
	if not observation then
		observation = {
			Receipt = receipt,
			ExcludedRequestId = if not Prompts[buyerId] then CreatingDrafts[buyerId] else nil,
		}
		pending[receipt.PurchaseId] = observation
		UnresolvedCount += 1
	end
	local ok, result = pcall(function()
		return Fast.Run(buyerId, function()
			return Store.GetReceipt(receipt.PurchaseId)
				or Store.Bind(receipt, observation.ExcludedRequestId, Fast.Current(buyerId))
		end)
	end)
	local remaining = assert(ObservingReceipts[buyerId], "Missing receipt observation fence") - 1
	if remaining > 0 then
		ObservingReceipts[buyerId] = remaining
	else
		ObservingReceipts[buyerId] = nil
	end
	if not ok then
		-- Keep the fence until routing has been durably observed, including after errors.
		local buyer = Players:GetPlayerByUserId(buyerId)
		if Ready(buyer) then
			Runtime.Schedule(buyer, "CheckoutObservation:" .. receipt.PurchaseId, function()
				ObserveReceipt(receipt)
				return true
			end)
		end
		error(result)
	end
	if pending[receipt.PurchaseId] == observation then
		pending[receipt.PurchaseId] = nil
		UnresolvedCount -= 1
	end
	if not next(pending) and UnresolvedObservations[buyerId] == pending then
		UnresolvedObservations[buyerId] = nil
	end
	return result
end

local function Process(receipt: PurchaseTypes.Receipt): PurchaseTypes.Decision?
	local definition = Registry.Get(receipt.ProductId)
	if definition and definition.SimpleOnly then definition = nil end
	assert(type(receipt.PurchaseId) == "string" and receipt.PurchaseId ~= "", "Missing PurchaseId")
	-- Observe routing even before product registration. Bind records unmatched receipts
	-- durably so a retry cannot attach them to a checkout created in the meantime.
	local observed = ObserveReceipt(receipt)
	if not definition and not observed then
		return nil -- Preserve unrelated product handlers after recording this observation.
	end
	local intent: PurchaseTypes.Intent
	if observed then
		intent = observed
	else
		local replacement = Recovery.Resolve(receipt)
		if not replacement then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		intent = Store.Replace(receipt, replacement)
	end
	if intent.Strategy == "Simple" then
		return Simple.TryProcess(receipt)
	end
	assert(intent.BuyerId == receipt.PlayerId and intent.ProductId == receipt.ProductId, "Checkout receipt mismatch")
	for _, original in pairs(intent.Reconciled or {}) do
		Fast.Retire(original, true)
		if not intent.Complete then
			CleanupCancelled(original)
		end
	end
	if not intent.Complete then
		if intent.Mode == "Self" then
			local buyer = Players:GetPlayerByUserId(intent.BuyerId)
			if
				not Ready(buyer)
				or not Receipts.Process(buyer, receipt, intent.Reward.Kind, function()
					return intent.Reward
				end)
			then
				Checkout.Notify(intent, "SavePending")
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			Store.CommitReservation(intent)
		else
			if intent.Strategy == "Fast" then
				Fast.Paid(intent)
			end
			Inbox.Enqueue(intent)
		end
	end
	Store.Complete(intent)
	Changed(intent.BuyerId)
	local recovered = RecoveredPending[intent.BuyerId]
	if recovered and recovered.RequestId == intent.RequestId then
		RecoveredPending[intent.BuyerId] = nil
	end
	if intent.Strategy == "Fast" then
		Fast.Finish(intent)
	end
	local buyer = Players:GetPlayerByUserId(intent.BuyerId)
	if buyer then
		RefreshFlags(buyer)
		if not Prompts[intent.BuyerId] and not Fast.Current(intent.BuyerId) then
			PlayerData.Set(buyer, "PendingGiftRecipientId", nil)
			PlayerData.Set(buyer, "PendingGiftProductId", nil)
		end
	end
	Checkout.Notify(
		intent,
		if intent.Replacement
			then "ReplacementDelivered"
			elseif intent.Mode == "Self" then "Purchased"
			elseif intent.Delivered then "Delivered"
			else "Queued",
		if intent.Replacement then intent.Reward else nil
	)
	if intent.Mode ~= "Self" and GiftQueued then
		task.spawn(GiftQueued, intent)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Checkout.TryProcess(receipt)
	if Config.CheckoutMode == "Simple" or Simple.HasBuyer(receipt.PlayerId) or Simple.HasReceipt(receipt.PurchaseId) then
		local decision = Simple.TryProcess(receipt)
		if decision then return decision end
	end
	local purchaseId = receipt.PurchaseId
	if ProcessingReceipts[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	ProcessingReceipts[purchaseId] = true
	local ok, decision = pcall(Process, receipt)
	ProcessingReceipts[purchaseId] = nil
	-- A Simple inbox discovered while running a managed server owns its own
	-- retry job. Do not also enqueue the managed worker/timer for that receipt.
	if Simple.HasReceipt(purchaseId) then
		if PendingReceipts[purchaseId] then
			PendingReceipts[purchaseId] = nil
			PendingCount -= 1
		end
		return if ok then decision else Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not ok or decision == Enum.ProductPurchaseDecision.NotProcessedYet then
		if PendingReceipts[purchaseId] or PendingCount < MAX_UNRESOLVED_OBSERVATIONS then
			if not PendingReceipts[purchaseId] then
				PendingCount += 1
			end
			PendingReceipts[purchaseId] = { Receipt = receipt, NextAttempt = os.clock() + 30 }
			local buyer = Players:GetPlayerByUserId(receipt.PlayerId)
			if Ready(buyer) then
				Runtime.Schedule(buyer, "CheckoutReceipt:" .. purchaseId, function()
					local success, result = pcall(Checkout.TryProcess, receipt)
					return success and result ~= Enum.ProductPurchaseDecision.NotProcessedYet
				end)
			end
		end
	elseif PendingReceipts[purchaseId] then
		PendingReceipts[purchaseId] = nil
		PendingCount -= 1
	end
	if not ok then
		error(decision)
	end
	return decision
end

function Checkout:Setup()
	assert(Config.CheckoutMode == "Simple" or Config.CheckoutMode == "Fast" or Config.CheckoutMode == "Durable",
		"RobuxShopConfig.CheckoutMode must be Simple, Fast or Durable")
	Simple.Init(Checkout.Notify, function(buyerId: number)
		return Fast.Current(buyerId) or Prompts[buyerId] or RecoveredPending[buyerId]
	end)
	Fast.SetNotify(Checkout.Notify)
	Recovery.Setup()
	local events = ReplicatedStorage.Events
	SelfRemote = events:FindFirstChild("ShopCheckoutEvent")
	if not SelfRemote then
		local created = Instance.new("RemoteEvent")
		created.Name, created.Parent = "ShopCheckoutEvent", events
		SelfRemote = created
	end
	GiftRemote = events.PendingGiftEvent
end

function Checkout:Start()
	assert(SelfRemote, "Checkout.Setup must run before Start").OnServerEvent:Connect(
		function(buyer, productId, clientContext)
			if productId == "ResumePending" then
				local opened, reason = Checkout.ResumePending(buyer)
				if not opened then
					Checkout.Notify({ BuyerId = buyer.UserId, Mode = "Self" }, reason or "Unavailable")
				end
				return
			end
			Checkout.RequestSelf(buyer, productId, clientContext)
		end
	)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local intent = Prompts[userId]
		if not intent or intent.ProductId ~= productId then
			return
		end
		if intent.Strategy == "Fast" then
			if Prompts[userId] and Prompts[userId].RequestId == intent.RequestId then
				Prompts[userId] = nil
				Changed(userId)
			end
			if purchased then
				intent.PaymentReported = true
				Fast.Queue(intent)
			else
				RecoveredPending[userId] = nil
				Fast.Cancel(intent)
				Checkout.Notify(intent, "Cancelled")
			end
			local buyer = Players:GetPlayerByUserId(userId)
			if buyer then
				RefreshFlags(buyer)
			end
			return
		end
		local ok, err = pcall(function()
			if purchased then
				Store.MarkPaymentReported(intent)
			end
			if not purchased and Cancel(intent) then
				Checkout.Notify(intent, "Cancelled")
			end
			if Prompts[userId] and Prompts[userId].RequestId == intent.RequestId then
				Prompts[userId] = nil
				Changed(userId)
			end
			local buyer = Players:GetPlayerByUserId(userId)
			if buyer then
				RecoverBuyer(buyer)
			end
		end)
		if not ok then
			warn("[Checkout] Prompt cleanup failed: " .. tostring(err))
			local buyer = Players:GetPlayerByUserId(userId)
			if buyer then
				Runtime.Schedule(buyer, "CheckoutPromptCleanup", function()
					if purchased then
						Store.MarkPaymentReported(intent)
					end
					if not purchased then
						Cancel(intent)
					end
					if Prompts[userId] == intent then
						Prompts[userId] = nil
					end
					RecoverBuyer(buyer)
					return true
				end)
			end
		end
	end)
	local function watch(player: Player)
		if Connections[player] then
			return
		end
		local function recover()
			if Ready(player) then
				for purchaseId, observation in pairs(UnresolvedObservations[player.UserId] or {}) do
					Runtime.Schedule(player, "CheckoutObservation:" .. purchaseId, function()
						ObserveReceipt(observation.Receipt)
						return true
					end)
				end
				Runtime.Schedule(player, "CheckoutRecovery", function()
					RecoverBuyer(player)
					return not Requesting[player.UserId] and Store.CompactBuyer(player.UserId)
				end)
			end
		end
		Connections[player] = PlayerData.Observe(player, "DataLoaded", recover)
		recover()
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		Changed(player.UserId)
		Fast.Depart(player.UserId)
		if Connections[player] then
			Connections[player]:Disconnect()
		end
		Connections[player] = nil
		-- A departed player's in-flight write must settle before recovery or a rejoin
		-- can cancel its draft. RequestProtected releases this fence when it finishes.
		Prompts[player.UserId], NextRequest[player.UserId], RecoveredPending[player.UserId] = nil, nil, nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	-- Drain departed buyers too; no Player instances are retained by this queue.
	task.spawn(function()
		while task.wait(15) do
			Fast.Drain()
			local processed = 0
			for _, pending in pairs(PendingReceipts) do
				if os.clock() >= pending.NextAttempt then
					pending.NextAttempt = os.clock() + 30
					pcall(Checkout.TryProcess, pending.Receipt)
					processed += 1
					if processed >= 4 then
						break
					end
				end
			end
			local batch = {}
			for _, observations in pairs(UnresolvedObservations) do
				for _, observation in pairs(observations) do
					table.insert(batch, observation.Receipt)
					if #batch >= 4 then
						break
					end
				end
				if #batch >= 4 then
					break
				end
			end
			for _, receipt in ipairs(batch) do
				pcall(ObserveReceipt, receipt)
			end
		end
	end)
end

function Checkout.Init()
	if Initialized then
		return
	end
	Checkout:Setup()
	Checkout:Start()
	Initialized = true
end

return Checkout
