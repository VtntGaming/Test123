--!strict
-- Reads legacy routing without repairs and persists only Simple's disconnected-recipient gifts.

--// Services
local DataStoreService = game:GetService("DataStoreService")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local Types = require(Services.PurchaseService.Types)
local Data = require(Services.PlayerDataService)
local Inbox = require(Services.PurchaseService.Gifting.Store)

--// References
local Checkouts = DataStoreService:GetDataStore("GiftPurchases_V1")
local Receipts = DataStoreService:GetDataStore("RobuxShopReceipts_V1")
local Fresh = Instance.new("DataStoreGetOptions")
Fresh.UseCache = false

--// Types
export type Evidence = { Kind: "Managed" | "Simple" | "Missing", Intent: Types.Intent?, Bound: boolean? }
export type SimpleStore = {
	Read: (Types.Receipt, Player) -> Evidence,
	Queue: (Types.Intent) -> Types.Intent,
	Delivered: (Types.Intent) -> (),
}

--// Module
local Store = {} :: SimpleStore

--// APIs
local function evidence(record: Types.Intent, receipt: Types.Receipt): Evidence
	assert(record.BuyerId == receipt.PlayerId and record.ProductId == receipt.ProductId, "Receipt identity mismatch")
	return { Kind = if record.Strategy == "Simple" then "Simple" else "Managed", Intent = record, Bound = true }
end

function Store.Read(receipt, player)
	-- Do not use Checkout.Store.GetBuyer/GetReceipt: they can reconcile or write.
	local archived = Checkouts:GetAsync("Receipt_" .. receipt.PurchaseId, Fresh)
	if archived then
		if archived.Unmatched then
			return { Kind = "Managed", Bound = true }
		end
		return evidence(archived, receipt)
	end
	local ledger = Receipts:GetAsync("R:" .. receipt.PurchaseId, Fresh)
	if ledger then
		assert(ledger.PlayerId == receipt.PlayerId, "Receipt owner mismatch")
		assert(ledger.ProductId == receipt.ProductId or ledger.Legacy == true, "Receipt product mismatch")
		return { Kind = "Managed", Bound = true }
	end
	local buyer = Checkouts:GetAsync("Buyer_" .. receipt.PlayerId, Fresh)
	if buyer then
		if buyer.Receipts and buyer.Receipts[receipt.PurchaseId] then
			return evidence(buyer.Receipts[receipt.PurchaseId], receipt)
		end
		if buyer.Unmatched and buyer.Unmatched[receipt.PurchaseId] then
			return { Kind = "Managed", Bound = true }
		end
		local function eligible(intent: Types.Intent?): boolean
			return intent ~= nil
				and intent.Prompted
				and intent.ProductId == receipt.ProductId
				and (intent.PurchaseId == nil or intent.PurchaseId == receipt.PurchaseId)
				and not (buyer.FastClosed and buyer.FastClosed[intent.RequestId])
		end
		if eligible(buyer.Active) then
			return { Kind = "Managed" }
		end
		for _, pending in ipairs({ buyer.FastPending or {}, buyer.RecoveryPending or {} }) do
			for _, intent in pairs(pending) do
				if eligible(intent) then
					return { Kind = "Managed" }
				end
			end
		end
	end
	local state = Data.GetPurchaseState(player)
	if
		(state.Journal and state.Journal[receipt.PurchaseId]) or (state.Recovery and state.Recovery[receipt.PurchaseId])
	then
		return { Kind = "Managed", Bound = true }
	end
	for _, records in pairs(state.Legacy or {}) do
		if type(records) == "table" and records[receipt.PurchaseId] ~= nil then
			return { Kind = "Managed", Bound = true }
		end
	end
	return { Kind = "Missing" }
end

function Store.Queue(intent)
	local id = assert(intent.PurchaseId)
	local saved = Checkouts:UpdateAsync("Receipt_" .. id, function(current)
		if current then
			assert(
				current.Strategy == "Simple"
					and current.BuyerId == intent.BuyerId
					and current.ProductId == intent.ProductId
					and current.RecipientId == intent.RecipientId,
				"Conflicting offline gift binding"
			)
			return current
		end
		return intent
	end)
	assert(saved, "Offline gift binding did not persist")
	if not saved.Delivered then
		Inbox.Enqueue(saved)
	end
	local complete = Checkouts:UpdateAsync("Receipt_" .. id, function(current)
		assert(current and current.Strategy == "Simple", "Missing offline gift binding")
		current.Complete = true
		return current
	end)
	return assert(complete)
end

function Store.Delivered(intent)
	Checkouts:UpdateAsync("Receipt_" .. assert(intent.PurchaseId), function(current)
		assert(
			current and current.Strategy == "Simple" and current.RecipientId == intent.RecipientId,
			"Missing offline gift binding"
		)
		current.Delivered, current.Complete = true, true
		return current
	end)
end

return Store
