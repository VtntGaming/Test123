--!strict
-- Persists paid recipient inbox entries and their delivery state using existing GiftPurchases_V1 keys.

--// Modules
local PurchaseTypes = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)

--// References
local DataStore = game:GetService("DataStoreService"):GetDataStore("GiftPurchases_V1")

--// Types
export type GiftInbox = {
	Enqueue: (intent: PurchaseTypes.Intent) -> PurchaseTypes.Inbox?,
	GetInbox: (recipientId: number) -> PurchaseTypes.Inbox,
	Delivered: (intent: PurchaseTypes.Intent) -> (),
	Finalize: (intent: PurchaseTypes.Intent) -> (),
}

--// Module
local Store = {} :: GiftInbox

--// APIs
local function Key(id: number)
	return "Inbox_" .. id
end

function Store.Enqueue(intent)
	-- A finalized delivery is represented by its individual checkout receipt, never re-enqueued.
	local receipt = DataStore:UpdateAsync("Receipt_" .. assert(intent.PurchaseId), function(record)
		return record
	end)
	if receipt and receipt.Delivered then
		return nil
	end
	return DataStore:UpdateAsync(Key(intent.RecipientId), function(inbox)
		inbox = inbox or {}
		if not inbox[intent.PurchaseId] then
			local count = 0
			for _ in pairs(inbox) do
				count += 1
			end
			assert(count < 256, "Recipient inbox is full; paid receipt will retry")
		end
		inbox[intent.PurchaseId] = inbox[intent.PurchaseId] or intent
		return inbox
	end)
end

function Store.GetInbox(recipientId)
	return DataStore:GetAsync(Key(recipientId)) or {}
end

function Store.Delivered(intent)
	DataStore:UpdateAsync(Key(intent.RecipientId), function(inbox)
		assert(inbox and inbox[intent.PurchaseId], "Missing gift inbox entry")
		inbox[intent.PurchaseId].Delivered = true
		return inbox
	end)
end

function Store.Finalize(intent)
	DataStore:UpdateAsync(Key(intent.RecipientId), function(inbox)
		if inbox then
			inbox[intent.PurchaseId] = nil
		end
		return inbox
	end)
end

return Store
