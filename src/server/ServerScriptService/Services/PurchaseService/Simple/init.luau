--!strict
-- Prompts from runtime selections and grants online rewards without purchase-triggered saves.
-- Only legacy receipt compatibility and disconnected-recipient gifts use storage.

--// Services
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local Http = game:GetService("HttpService")
local Services = game:GetService("ServerScriptService").Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local Types = require(Services.PurchaseService.Types)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Runtime = require(Services.Helper.ShopRuntime)
local Data = require(Services.PlayerDataService)
local Store = require(script.Store)
local Inbox = require(Services.PurchaseService.Gifting.Store)

--// Constants
local MAX_PENDING = 256
local MAX_SELECTIONS = 8

--// Properties
local Initialized = false
local Selections: { [number]: { [string]: Types.Intent } } = {}
local Prompting: { [number]: { Intent: Types.Intent, Deadline: number } } = {}
local Requesting: { [number]: boolean } = {}
local NextRequest: { [number]: number } = {}
local Bindings: { [string]: Types.Intent } = {}
local Observed: { [string]: { [string]: boolean } } = {}
local Completed: { [string]: { BuyerId: number, ProductId: number } } = {}
local Processing: { [string]: boolean } = {}
local Pending: { [string]: Types.Receipt } = {}
local PendingCount = 0
local Connections: { [Player]: PlayerData.Connection } = {}
local Notify: (Types.Notification, string, unknown?) -> () = function() end
local ManagedCurrent: (number) -> Types.Intent? = function()
	return nil
end

--// Types
export type SimpleCheckout = {
	Request: (Player, Player, number, unknown, Types.Mode) -> (boolean, string?),
	TryProcess: (Types.Receipt) -> Types.Decision?,
	HasBuyer: (number) -> boolean,
	HasReceipt: (string) -> boolean,
	Deliver: (Player, Types.Intent) -> boolean,
	Setup: ((Types.Notification, string, unknown?) -> (), (number) -> Types.Intent?) -> (),
	Start: () -> (),
	Init: ((Types.Notification, string, unknown?) -> (), (number) -> Types.Intent?) -> (),
}

--// Module
local Simple = {} :: SimpleCheckout

--// APIs
local function ready(player: Player?): boolean
	return player ~= nil and player.Parent == Players and PlayerData.Get(player, "DataLoaded") == true
end

local function notify(intent: Types.Notification, status: string, details: unknown?)
	local ok, err = pcall(function()
		Notify(intent, status, details)
		return true
	end)
	if not ok then
		warn("[SimpleCheckout] Feedback: " .. tostring(err))
	end
end

local function closePrompt(buyerId: number)
	Prompting[buyerId] = nil
	local buyer = Players:GetPlayerByUserId(buyerId)
	if buyer then
		PlayerData.Set(buyer, "SimpleCheckoutPending", false)
	end
end

local function removeSelection(intent: Types.Intent)
	local selections = Selections[intent.BuyerId]
	if selections then
		selections[intent.RequestId] = nil
		if not next(selections) then
			Selections[intent.BuyerId] = nil
		end
	end
end

local function context(value: unknown): Types.Context?
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		return nil
	end
	local entries = value :: { [string]: unknown }
	local result: { [string]: string } = {}
	for _, key in ipairs({ "ClientRequestId", "RotationKey" }) do
		local entry = entries[key]
		if entry ~= nil then
			if type(entry) ~= "string" or #entry > 128 then
				return nil
			end
			result[key] = entry
		end
	end
	return { ClientRequestId = result.ClientRequestId, RotationKey = result.RotationKey }
end

function Simple.HasBuyer(buyerId)
	return Selections[buyerId] ~= nil or Requesting[buyerId] == true
end

function Simple.HasReceipt(id)
	return Bindings[id] ~= nil or Completed[id] ~= nil or Pending[id] ~= nil
end

function Simple.Request(buyer, recipient, productId, rawContext, mode)
	local parsed = context(rawContext)
	local failure = {
		BuyerId = buyer.UserId,
		RecipientId = recipient and recipient.UserId,
		ProductId = productId,
		Mode = mode,
		Strategy = "Simple" :: "Simple",
		ClientRequestId = parsed and parsed.ClientRequestId,
	}
	local function reject(reason: string): (boolean, string?)
		notify(failure, reason)
		return false, reason
	end
	if not parsed or type(productId) ~= "number" or productId <= 0 or productId >= math.huge or productId % 1 ~= 0 then
		return reject("InvalidRequest")
	end
	if not ready(buyer) or not ready(recipient) then
		return reject("DataNotLoaded")
	end
	if mode == "Gift" and buyer == recipient then
		return reject("InvalidRecipient")
	end
	local definition = Registry.Get(productId)
	if
		not definition
		or (mode == "Gift" and definition.GiftAllowed == false)
		or (mode == "Self" and definition.SelfAllowed == false)
	then
		return reject("Unavailable")
	end
	local prompt = Prompting[buyer.UserId]
	if Requesting[buyer.UserId] or (prompt and prompt.Deadline > os.clock()) then
		return reject("PurchasePending")
	end
	if os.clock() < (NextRequest[buyer.UserId] or 0) then
		return reject("RateLimited")
	end
	local count = 0
	for _ in pairs(Selections[buyer.UserId] or {}) do
		count += 1
	end
	if count >= MAX_SELECTIONS then
		local oldest: Types.Intent? = nil
		for _, selected in pairs(Selections[buyer.UserId] or {}) do
			if
				not selected.PaymentReported
				and not selected.PurchaseId
				and (not oldest or selected.CreatedAt < oldest.CreatedAt)
			then
				oldest = selected
			end
		end
		if not oldest then
			return reject("PurchasePending")
		end
		-- Bound/paid selections are never discarded merely to admit another prompt.
		removeSelection(oldest)
	end
	NextRequest[buyer.UserId] = os.clock() + 1
	Requesting[buyer.UserId] = true
	local ok, reward, reason = pcall(definition.SimpleSnapshot or definition.Snapshot, buyer, recipient, parsed, mode)
	Requesting[buyer.UserId] = nil
	if not ok then
		warn("[SimpleCheckout] Snapshot: " .. tostring(reward))
		return reject("Unavailable")
	end
	if not reward then
		return reject(reason or "Unavailable")
	end
	-- Detach nested bundles from mutable product configuration without storage I/O.
	reward = Http:JSONDecode(Http:JSONEncode(reward))
	if not ready(buyer) or not ready(recipient) then
		return reject("PlayerLeft")
	end
	reward.Kind = definition.Kind
	local intent: Types.Intent = {
		RequestId = Http:GenerateGUID(false),
		BuyerId = buyer.UserId,
		RecipientId = recipient.UserId,
		ProductId = productId,
		Mode = mode,
		Reward = reward,
		Strategy = "Simple",
		ClientRequestId = parsed.ClientRequestId,
		CreatedAt = os.time(),
		Prompted = true,
	}
	local selections = Selections[buyer.UserId] or {}
	Selections[buyer.UserId] = selections
	selections[intent.RequestId] = intent
	local opened = { Intent = intent, Deadline = os.clock() + 120 }
	Prompting[buyer.UserId] = opened
	PlayerData.Set(buyer, "SimpleCheckoutPending", true)
	task.delay(120, function()
		if Prompting[buyer.UserId] == opened then
			closePrompt(buyer.UserId)
		end
	end)
	-- No storage is performed until Roblox invokes the receipt callback.
	local prompted, err = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, buyer, productId)
	if not prompted then
		closePrompt(buyer.UserId)
		warn("[SimpleCheckout] Uncertain prompt: " .. tostring(err))
		return reject("PromptFailed") -- Retain selection: the prompt may have reached Roblox.
	end
	notify(intent, "PromptOpen")
	return true, "PromptOpen"
end

local function policy(player: Player, definition: Types.Product): boolean
	if definition.SimplePolicy then
		local allowed = definition.SimplePolicy(player)
		return allowed and ready(player)
	end
	return ready(player)
end

local function grant(player: Player, intent: Types.Intent)
	local definition = assert(Registry.Get(intent.ProductId), "Product handler unavailable")
	assert(intent.Reward.Kind == definition.Kind, "Saved reward kind mismatch")
	assert(policy(player, definition), "Recipient unavailable or policy restricted")
	-- Every product grant prepares/validates its inputs before non-yielding mutation.
	local apply = definition.SimpleGrant or definition.Grant
	apply(player, intent.Reward)
end

local function process(receipt: Types.Receipt): Types.Decision?
	local done = Completed[receipt.PurchaseId]
	if done then
		assert(done.BuyerId == receipt.PlayerId and done.ProductId == receipt.ProductId, "Receipt identity mismatch")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local buyer = Players:GetPlayerByUserId(receipt.PlayerId)
	if not ready(buyer) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not Observed[receipt.PurchaseId] then
		local eligible: { [string]: boolean } = {}
		for requestId, candidate in pairs(Selections[receipt.PlayerId] or {}) do
			if candidate.ProductId == receipt.ProductId and not candidate.PurchaseId then
				eligible[requestId] = true
			end
		end
		-- Fence before yielding: an old receipt cannot attach to a later prompt.
		Observed[receipt.PurchaseId] = eligible
	end
	local managed = ManagedCurrent(receipt.PlayerId)
	local evidence = Store.Read(receipt, buyer :: Player)
	if
		evidence.Kind == "Missing"
		and not Bindings[receipt.PurchaseId]
		and managed
		and managed.Prompted
		and managed.ProductId == receipt.ProductId
		and (not managed.PurchaseId or managed.PurchaseId == receipt.PurchaseId)
	then
		-- An older Fast write can still be in flight after the mode changes.
		if managed.PurchaseId == receipt.PurchaseId or next(Observed[receipt.PurchaseId]) == nil then
			return nil
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if evidence.Kind == "Managed" then
		-- A saved, already-bound managed receipt is authoritative. An unbound
		-- managed selection overlapping a Simple selection cannot be guessed.
		if not evidence.Bound and Bindings[receipt.PurchaseId] then
			-- This callback was bound in runtime before a later managed prompt.
			evidence = { Kind = "Missing" }
		else
			if not evidence.Bound and next(Observed[receipt.PurchaseId]) ~= nil then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local previous = Bindings[receipt.PurchaseId]
			if previous then
				previous.PurchaseId = nil
			end
			Bindings[receipt.PurchaseId] = nil
			return nil
		end
	end
	local intent: Types.Intent? = evidence.Intent or Bindings[receipt.PurchaseId]
	if not intent then
		local selected: Types.Intent? = nil
		for requestId, candidate in pairs(Selections[receipt.PlayerId] or {}) do
			if
				Observed[receipt.PurchaseId][requestId]
				and candidate.ProductId == receipt.ProductId
				and not candidate.PurchaseId
			then
				if selected then
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
				selected = candidate
			end
		end
		intent = selected
		if not intent then
			local definition = Registry.Get(receipt.ProductId)
			if not definition then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local recover: ((Player) -> (Types.Reward?, string?))? = definition.SimpleRecovery
				or definition.RecoveryReward
			if not recover then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			local reward = recover(buyer :: Player)
			if not reward or not ready(buyer) then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			reward.Kind = definition.Kind
			intent = {
				RequestId = "SimpleReplacement:" .. receipt.PurchaseId,
				BuyerId = receipt.PlayerId,
				RecipientId = receipt.PlayerId,
				ProductId = receipt.ProductId,
				Mode = "Self",
				Reward = reward,
				Strategy = "Simple",
				Replacement = true,
				CreatedAt = os.time(),
				Prompted = true,
			}
		end
	end
	assert(intent, "Missing Simple selection")
	assert(intent.BuyerId == receipt.PlayerId and intent.ProductId == receipt.ProductId, "Receipt identity mismatch")
	intent.PurchaseId = receipt.PurchaseId
	Bindings[receipt.PurchaseId] = intent
	local recipient = Players:GetPlayerByUserId(intent.RecipientId)
	if evidence.Kind == "Simple" or (intent.Mode == "Gift" and not ready(recipient)) or intent.Complete then
		-- Once a durable binding exists, never race it with an online runtime grant.
		intent = Store.Queue(intent)
		Bindings[receipt.PurchaseId] = intent
		notify(intent, if intent.Delivered then "Delivered" else "Queued")
	else
		if not ready(recipient) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		grant(recipient :: Player, intent)
	end
	Completed[receipt.PurchaseId] = { BuyerId = receipt.PlayerId, ProductId = receipt.ProductId }
	removeSelection(intent)
	Bindings[receipt.PurchaseId] = nil
	Observed[receipt.PurchaseId] = nil
	if evidence.Kind ~= "Simple" and not intent.Complete then
		notify(
			intent,
			if intent.Replacement
				then "ReplacementDelivered"
				elseif intent.Mode == "Gift" then "Delivered"
				else "Purchased",
			if intent.Replacement then intent.Reward else intent.Reward.Amount
		)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Simple.TryProcess(receipt)
	if type(receipt.PurchaseId) ~= "string" or receipt.PurchaseId == "" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if Processing[receipt.PurchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	Processing[receipt.PurchaseId] = true
	local ok, result = pcall(process, receipt)
	Processing[receipt.PurchaseId] = nil
	if not ok then
		warn("[SimpleCheckout] Receipt pending: " .. tostring(result))
	end
	if not ok or result == Enum.ProductPurchaseDecision.NotProcessedYet then
		local buyer = Players:GetPlayerByUserId(receipt.PlayerId)
		if ready(buyer) then
			notify(
				{ BuyerId = receipt.PlayerId, ProductId = receipt.ProductId, Mode = "Self", Strategy = "Simple" },
				"SavePending"
			)
		end
		if buyer and buyer.Parent == Players and not Pending[receipt.PurchaseId] and PendingCount < MAX_PENDING then
			Pending[receipt.PurchaseId] = receipt
			PendingCount += 1
		end
		if Pending[receipt.PurchaseId] and ready(buyer) then
			Runtime.Schedule(buyer :: Player, "SimpleReceipt:" .. receipt.PurchaseId, function()
				return Simple.TryProcess(receipt) ~= Enum.ProductPurchaseDecision.NotProcessedYet
			end)
		elseif not Pending[receipt.PurchaseId] then
			-- A saturated retry set must not disable receipts for unrelated buyers.
			local binding = Bindings[receipt.PurchaseId]
			if binding then
				binding.PurchaseId = nil
			end
			Observed[receipt.PurchaseId], Bindings[receipt.PurchaseId] = nil, nil
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if Pending[receipt.PurchaseId] then
		Pending[receipt.PurchaseId] = nil
		PendingCount -= 1
	end
	if result == nil then
		Observed[receipt.PurchaseId] = nil
	end
	return result
end

function Simple.Deliver(player, intent)
	assert(intent.Strategy == "Simple" and intent.RecipientId == player.UserId, "Invalid Simple inbox entry")
	if not ready(player) then
		return false
	end
	local id = assert(intent.PurchaseId)
	local evidence = Store.Read({ PlayerId = intent.BuyerId, ProductId = intent.ProductId, PurchaseId = id }, player)
	local saved = assert(evidence.Intent, "Missing offline gift binding")
	assert(evidence.Kind == "Simple", "Conflicting offline gift strategy")
	if not saved.Delivered then
		local processed = Http:JSONDecode(PlayerData.Get(player, "ProcessedGiftReceipts"))
		assert(type(processed) == "table", "Invalid gift receipt history")
		if not processed[id] then
			grant(player, saved)
			processed[id] = true
			PlayerData.Set(player, "ProcessedGiftReceipts", Http:JSONEncode(processed))
		end
		if not Data.SavePlayer(player, true) then
			return false
		end
		Store.Delivered(saved)
	end
	local processed = Http:JSONDecode(PlayerData.Get(player, "ProcessedGiftReceipts"))
	if processed[id] then
		processed[id] = nil
		PlayerData.Set(player, "ProcessedGiftReceipts", Http:JSONEncode(processed))
	end
	Inbox.Finalize(saved)
	notify(saved, "Delivered", saved.Reward.Amount)
	return true
end

function Simple.Setup(callback, managed)
	Notify = callback
	ManagedCurrent = managed
end

function Simple.Start()
	local function watch(player: Player)
		if Connections[player] then
			return
		end
		local function wake()
			if not ready(player) then
				return
			end
			for _, receipt in pairs(Pending) do
				if receipt.PlayerId == player.UserId then
					Runtime.Schedule(player, "SimpleReceipt:" .. receipt.PurchaseId, function()
						return Simple.TryProcess(receipt) ~= Enum.ProductPurchaseDecision.NotProcessedYet
					end)
				end
			end
		end
		Connections[player] = PlayerData.Observe(player, "DataLoaded", wake)
		wake()
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local prompt = Prompting[userId]
		if not prompt or prompt.Intent.ProductId ~= productId then
			return
		end
		closePrompt(userId)
		if purchased then
			prompt.Intent.PaymentReported = true
		elseif not prompt.Intent.PurchaseId then
			removeSelection(prompt.Intent)
			notify(prompt.Intent, "Cancelled")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		if Connections[player] then
			Connections[player]:Disconnect()
		end
		Connections[player] = nil
		Selections[player.UserId], Prompting[player.UserId], NextRequest[player.UserId], Requesting[player.UserId] =
			nil, nil, nil, nil
		for id, receipt in pairs(Pending) do
			if receipt.PlayerId == player.UserId then
				Pending[id] = nil
				PendingCount -= 1
				if not Processing[id] then
					Observed[id], Bindings[id] = nil, nil
				end
			end
		end
	end)
end

function Simple.Init(callback, managed)
	if Initialized then
		return
	end
	Initialized = true
	Simple.Setup(callback, managed)
	Simple.Start()
end

return Simple
