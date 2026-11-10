--!strict
-- Persists checkout bindings and recipient reservations using the existing GiftPurchases_V1 keys.

--// Modules
local PurchaseTypes = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)
local Runtime = require(game:GetService("ServerScriptService").Services.Helper.ShopRuntime)

--// References
local DataStore = game:GetService("DataStoreService"):GetDataStore("GiftPurchases_V1")
local FreshRead = Instance.new("DataStoreGetOptions")
FreshRead.UseCache = false

--// Constants
local CACHE_SECONDS = 30
local CACHE_WAIT_SECONDS = 0.1
local CACHE_RETRY_SECONDS = 30
local MAX_CACHE_CALLS = 4

--// Properties
local IdleMap: MemoryStoreHashMap? = nil
local CacheRetryAt = 0
local CacheCalls = 0

--// Types
type QuotaRecord = {
	Key: string,
	Used: number,
	Pending: { [string]: number | boolean },
	Committed: { [string]: boolean },
}

export type CheckoutStore = {
	IsBuyerIdle: (id: number) -> boolean,
	GetBuyer: (id: number, fresh: boolean?) -> PurchaseTypes.BuyerRecord,
	GetReceipt: (id: string) -> PurchaseTypes.Intent?,
	Begin: (intent: PurchaseTypes.Intent) -> boolean?,
	SaveFast: (intent: PurchaseTypes.Intent) -> string?,
	ReconcileBuyer: (id: number) -> PurchaseTypes.BuyerRecord,
	CancelFast: (intent: PurchaseTypes.Intent) -> boolean,
	MarkPrompted: (intent: PurchaseTypes.Intent) -> boolean,
	MarkPaymentReported: (intent: PurchaseTypes.Intent) -> (),
	Cancel: (buyerId: number, requestId: string) -> boolean?,
	CleanCancelled: (intent: PurchaseTypes.Intent) -> (),
	Reserve: (intent: PurchaseTypes.Intent) -> boolean?,
	Release: (intent: PurchaseTypes.Intent) -> (),
	CommitReservation: (intent: PurchaseTypes.Intent) -> (),
	Bind: (
		receipt: PurchaseTypes.Receipt,
		excludedRequestId: string?,
		runtimeIntent: PurchaseTypes.Intent?
	) -> PurchaseTypes.Intent?,
	Replace: (receipt: PurchaseTypes.Receipt, replacement: PurchaseTypes.Intent) -> PurchaseTypes.Intent,
	Complete: (intent: PurchaseTypes.Intent) -> (),
	MarkDelivered: (intent: PurchaseTypes.Intent) -> (),
	CompactBuyer: (id: number) -> boolean,
}

--// Module
local Store = {} :: CheckoutStore

--// APIs
-- Idle hints only skip the recovery read. Begin still atomically checks DataStore.
-- Bound both cache latency and outstanding native calls; an outage never blocks checkout.
local function CacheCall(callback: (MemoryStoreHashMap) -> boolean): (boolean, boolean)
	if os.clock() < CacheRetryAt or CacheCalls >= MAX_CACHE_CALLS then
		return false, false
	end
	CacheCalls += 1
	local ok, result = Runtime.Await(CACHE_WAIT_SECONDS, function()
		local success, value = pcall(function()
			if not IdleMap then
				IdleMap = game:GetService("MemoryStoreService"):GetHashMap("CheckoutIdle_V1")
			end
			return callback(assert(IdleMap))
		end)
		CacheCalls -= 1
		if not success then
			error(value)
		end
		return value
	end)
	if not ok then
		CacheRetryAt = os.clock() + CACHE_RETRY_SECONDS
	end
	return ok, result == true
end

local function PublishIdle(id: number, idle: boolean)
	if os.clock() < CacheRetryAt or CacheCalls >= MAX_CACHE_CALLS then
		return
	end
	task.spawn(function()
		CacheCall(function(map)
			map:SetAsync(tostring(id), idle, CACHE_SECONDS)
			return true
		end)
	end)
end

function Store.IsBuyerIdle(id)
	local ok, idle = CacheCall(function(map)
		return map:GetAsync(tostring(id)) == true
	end)
	return ok and idle
end

local function BuyerKey(id: number)
	return "Buyer_" .. id
end
local function ReceiptKey(id: string)
	return "Receipt_" .. id
end
local function QuotaKey(intent: PurchaseTypes.Intent)
	local reservation = assert(intent.Reservation, "Missing reservation")
	local first, second = 5381, 7919
	for index = 1, #reservation.Key do
		local byte = string.byte(reservation.Key, index)
		first, second = (first * 33 + byte) % 4294967296, (second * 65599 + byte) % 4294967296
	end
	return string.format("Quota_%d_%08x%08x", intent.RecipientId, first, second)
end

function Store.ReconcileBuyer(id)
	local saved = DataStore:UpdateAsync(BuyerKey(id), function(record: PurchaseTypes.BuyerRecord?)
		local current: PurchaseTypes.BuyerRecord = record or {}
		local recovery = current.RecoveryPending or {}
		current.RecoveryPending = recovery
		local active = current.Active
		if active and (active.PaymentReported or active.PurchaseId) then
			recovery[active.RequestId] = active
			current.Active = nil
		end
		local pending = current.FastPending
		if pending then
			for requestId, intent in pairs(pending) do
				if current.FastClosed and current.FastClosed[requestId] then
					pending[requestId] = nil
				elseif intent.PaymentReported or intent.PurchaseId then
					recovery[requestId] = intent
					pending[requestId] = nil
				end
			end
		end
		return current
	end)
	return assert(saved, "Checkout reconciliation did not persist")
end

function Store.GetBuyer(id, fresh)
	local record = DataStore:GetAsync(BuyerKey(id), if fresh then FreshRead else nil) or {}
	local active = record.Active
	local repair = active and (active.PaymentReported or active.PurchaseId)
	for requestId, intent in pairs(record.FastPending or {}) do
		if intent.PaymentReported or intent.PurchaseId or (record.FastClosed and record.FastClosed[requestId]) then
			repair = true
			break
		end
	end
	if repair then
		record = Store.ReconcileBuyer(id)
	end
	PublishIdle(
		id,
		record.Active == nil and next(record.FastPending or {}) == nil and next(record.Cancelled or {}) == nil
	)
	return record
end
function Store.GetReceipt(id)
	local record = DataStore:UpdateAsync(ReceiptKey(id), function(current)
		return current
	end)
	return if record and not record.Unmatched then record else nil
end

-- Archive first, remove index second. A failed archive never removes routing evidence.
function Store.CompactBuyer(id)
	local record = Store.GetBuyer(id)
	local archived = {}
	local work = 0
	for purchaseId, intent in pairs(record.Receipts or {}) do
		DataStore:UpdateAsync(ReceiptKey(purchaseId), function(current)
			return if current and not current.Unmatched then current else intent
		end)
		archived[purchaseId] = intent.RequestId
		work += 1
		if work >= 16 then
			break
		end
	end
	local unmatched = {}
	if work < 16 then
		for purchaseId in pairs(record.Unmatched or {}) do
			DataStore:UpdateAsync(ReceiptKey(purchaseId), function(current)
				return current
					or {
						BuyerId = id,
						Unmatched = true,
						Reconciled = record.UnmatchedRequests and record.UnmatchedRequests[purchaseId],
					}
			end)
			unmatched[purchaseId] = true
			work += 1
			if work >= 16 then
				break
			end
		end
	end
	if work == 0 then
		return true
	end
	local saved = DataStore:UpdateAsync(
		BuyerKey(id),
		function(current: PurchaseTypes.BuyerRecord?): PurchaseTypes.BuyerRecord?
			if not current then
				return nil
			end
			local receipts = current.Receipts
			if receipts then
				for purchaseId, requestId in pairs(archived) do
					local intent = receipts[purchaseId]
					if intent and intent.RequestId == requestId then
						receipts[purchaseId] = nil
					end
				end
			end
			for purchaseId in pairs(unmatched) do
				if current.Unmatched then
					current.Unmatched[purchaseId] = nil
				end
				if current.UnmatchedRequests then
					current.UnmatchedRequests[purchaseId] = nil
				end
			end
			return current
		end
	)
	return saved ~= nil and not next(saved.Receipts or {}) and not next(saved.Unmatched or {})
end

function Store.Begin(intent)
	PublishIdle(intent.BuyerId, false)
	local saved = DataStore:UpdateAsync(
		BuyerKey(intent.BuyerId),
		function(record: PurchaseTypes.BuyerRecord?): PurchaseTypes.BuyerRecord
			local current: PurchaseTypes.BuyerRecord = record or { Receipts = {} }
			if not current.Active and not next(current.FastPending or {}) then
				current.Active = intent
			end
			return current
		end
	)
	return saved and saved.Active and saved.Active.RequestId == intent.RequestId
end

function Store.SaveFast(intent)
	local status: string? = nil
	DataStore:UpdateAsync(
		BuyerKey(intent.BuyerId),
		function(record: PurchaseTypes.BuyerRecord?): PurchaseTypes.BuyerRecord?
			local current: PurchaseTypes.BuyerRecord = record or {}
			status = nil
			if current.FastClosed and current.FastClosed[intent.RequestId] then
				status = current.FastClosed[intent.RequestId]
				return nil
			end
			local recovery = current.RecoveryPending or {}
			if intent.PaymentReported or recovery[intent.RequestId] then
				local selected = recovery[intent.RequestId] or table.clone(intent)
				selected.PaymentReported = selected.PaymentReported or intent.PaymentReported
				recovery[intent.RequestId] = selected
				current.RecoveryPending = recovery
				if current.FastPending then
					current.FastPending[intent.RequestId] = nil
				end
				status = "Recovery"
				return current
			end
			local pending = current.FastPending or {}
			current.FastPending = pending
			local existing = pending[intent.RequestId]
			if not existing then
				pending[intent.RequestId] = table.clone(intent)
			elseif intent.PaymentReported then
				existing.PaymentReported = true
			end
			return current
		end
	)
	return status
end

function Store.CancelFast(intent)
	local saved = DataStore:UpdateAsync(
		BuyerKey(intent.BuyerId),
		function(record: PurchaseTypes.BuyerRecord?): PurchaseTypes.BuyerRecord?
			local current: PurchaseTypes.BuyerRecord = record or {}
			local terminal = current.FastClosed or {}
			current.FastClosed = terminal
			local closed = terminal[intent.RequestId]
			if closed and closed ~= "Cancelled" then
				return nil -- A receipt already owns this selection.
			end
			terminal[intent.RequestId] = "Cancelled"
			if current.FastPending then
				current.FastPending[intent.RequestId] = nil
			end
			if current.RecoveryPending then
				current.RecoveryPending[intent.RequestId] = nil
			end
			return current
		end
	)
	return saved ~= nil
end

function Store.MarkPrompted(intent)
	local saved = DataStore:UpdateAsync(
		BuyerKey(intent.BuyerId),
		function(record: PurchaseTypes.BuyerRecord?): PurchaseTypes.BuyerRecord?
			local active = record and record.Active
			if not active or active.RequestId ~= intent.RequestId then
				return nil
			end
			active.Prompted = true
			return record
		end
	)
	return saved ~= nil
end

function Store.MarkPaymentReported(intent)
	if intent.Strategy == "Fast" then
		Store.SaveFast(intent)
		return
	end
	DataStore:UpdateAsync(BuyerKey(intent.BuyerId), function(record: PurchaseTypes.BuyerRecord?)
		if record and record.Active and record.Active.RequestId == intent.RequestId then
			record.Active.PaymentReported = true
			local recovery = record.RecoveryPending or {}
			recovery[intent.RequestId] = record.Active
			record.RecoveryPending = recovery
			record.Active = nil
		end
		return record
	end)
end

function Store.Cancel(buyerId, requestId)
	local saved = DataStore:UpdateAsync(BuyerKey(buyerId), function(record: PurchaseTypes.BuyerRecord?)
		local current: PurchaseTypes.BuyerRecord = record or {}
		local active = current.Active
		if active and active.RequestId == requestId and not active.PurchaseId then
			local cancelled = current.Cancelled or {}
			current.Cancelled = cancelled
			cancelled[requestId] = active
			current.Active = nil
		end
		return current
	end)
	return saved and saved.Cancelled and saved.Cancelled[requestId] ~= nil
end

function Store.CleanCancelled(intent)
	DataStore:UpdateAsync(BuyerKey(intent.BuyerId), function(record: PurchaseTypes.BuyerRecord?)
		if record and record.Cancelled then
			record.Cancelled[intent.RequestId] = nil
		end
		return record
	end)
end

function Store.Reserve(intent)
	local spec = intent.Reservation
	if not spec then
		return true
	end
	local amount = if spec.Amount == nil then 1 else spec.Amount
	local saved = DataStore:UpdateAsync(QuotaKey(intent), function(record: QuotaRecord?)
		-- Seed legacy usage once. Later profile counts may already include a grant
		-- whose reservation is still pending while its delivery save completes.
		local current: QuotaRecord = record or { Key = spec.Key, Used = spec.Used, Pending = {}, Committed = {} }
		assert(current.Key == spec.Key, "Reservation key collision")
		if current.Pending[intent.RequestId] or current.Committed[intent.RequestId] then
			return current
		end
		local pending = 0
		for _, reserved in pairs(current.Pending) do
			pending += if type(reserved) == "number" then reserved else 1
		end
		if current.Used + pending + amount <= spec.Limit then
			current.Pending[intent.RequestId] = amount
		end
		return current
	end)
	return saved and (saved.Pending[intent.RequestId] ~= nil or saved.Committed[intent.RequestId] == true)
end

function Store.Release(intent)
	local reservation = intent.Reservation
	if not reservation then
		return
	end
	DataStore:UpdateAsync(QuotaKey(intent), function(record: QuotaRecord?)
		if record then
			assert(record.Key == reservation.Key, "Reservation key collision")
			record.Pending[intent.RequestId] = nil
		end
		return record
	end)
end

function Store.CommitReservation(intent)
	local reservation = intent.Reservation
	if not reservation then
		return
	end
	DataStore:UpdateAsync(QuotaKey(intent), function(record: QuotaRecord?)
		if intent.Strategy == "Fast" then
			local current = record or { Key = reservation.Key, Used = reservation.Used, Pending = {}, Committed = {} }
			assert(current.Key == reservation.Key, "Reservation key collision")
			if not current.Committed[intent.RequestId] then
				current.Pending[intent.RequestId] = nil
				current.Committed[intent.RequestId] = true
				current.Used += reservation.Amount or 1 -- Honor an already-paid purchase, even over quota.
			end
			return current
		end
		assert(record and record.Key == reservation.Key, "Missing recipient reservation")
		if not record.Committed[intent.RequestId] then
			assert(record.Pending[intent.RequestId], "Missing request reservation")
			local reserved = record.Pending[intent.RequestId]
			record.Pending[intent.RequestId] = nil
			record.Committed[intent.RequestId] = true
			record.Used += if type(reserved) == "number" then reserved else 1
		end
		return record
	end)
end

function Store.Bind(receipt, excludedRequestId, runtimeIntent)
	-- Read the individual archive without GetAsync's cache before consulting the compact buyer index.
	local existing = DataStore:UpdateAsync(ReceiptKey(receipt.PurchaseId), function(record)
		return record
	end)
	if existing then
		if existing.Unmatched then
			return nil
		end
		assert(
			existing.BuyerId == receipt.PlayerId and existing.ProductId == receipt.ProductId,
			"Receipt identity mismatch"
		)
		return existing
	end
	local saved = DataStore:UpdateAsync(BuyerKey(receipt.PlayerId), function(record: PurchaseTypes.BuyerRecord?)
		local current: PurchaseTypes.BuyerRecord = record or {}
		local receipts = current.Receipts or {}
		current.Receipts = receipts
		if receipts[receipt.PurchaseId] then
			return current
		end
		local unmatched = current.Unmatched or {}
		current.Unmatched = unmatched
		if unmatched[receipt.PurchaseId] then
			return current
		end
		local candidates: { [string]: PurchaseTypes.Intent } = {}
		local function consider(candidate: PurchaseTypes.Intent?)
			if
				candidate
				and candidate.RequestId ~= excludedRequestId
				and candidate.Prompted
				and candidate.ProductId == receipt.ProductId
				and (not candidate.PurchaseId or candidate.PurchaseId == receipt.PurchaseId)
				and not (current.FastClosed and current.FastClosed[candidate.RequestId])
			then
				candidates[candidate.RequestId] = candidate
			end
		end
		consider(current.Active)
		for _, candidate in pairs(current.FastPending or {}) do
			consider(candidate)
		end
		for _, candidate in pairs(current.RecoveryPending or {}) do
			consider(candidate)
		end
		consider(runtimeIntent)
		local requestId, active = next(candidates)
		if not active or next(candidates, requestId) ~= nil then
			-- An orphan must never attach itself to a future checkout on retry.
			unmatched[receipt.PurchaseId] = true
			local requests = current.UnmatchedRequests or {}
			requests[receipt.PurchaseId] = candidates
			current.UnmatchedRequests = requests
			return current
		end
		active = table.clone(active)
		active.PurchaseId = receipt.PurchaseId
		receipts[receipt.PurchaseId] = active
		if current.Active and current.Active.RequestId == active.RequestId then
			current.Active.PurchaseId = receipt.PurchaseId
		end
		if active.Strategy == "Fast" then
			local terminal = current.FastClosed or {}
			current.FastClosed = terminal
			terminal[active.RequestId] = receipt.PurchaseId
			if current.FastPending then
				current.FastPending[active.RequestId] = nil
			end
		end
		if current.RecoveryPending then
			current.RecoveryPending[active.RequestId] = nil
		end
		return current
	end)
	local intent = saved and saved.Receipts and saved.Receipts[receipt.PurchaseId]
	if not intent then
		DataStore:UpdateAsync(ReceiptKey(receipt.PurchaseId), function(record)
			return record
				or {
					BuyerId = receipt.PlayerId,
					ProductId = receipt.ProductId,
					Unmatched = true,
					Reconciled = saved and saved.UnmatchedRequests and saved.UnmatchedRequests[receipt.PurchaseId],
				}
		end)
		DataStore:UpdateAsync(BuyerKey(receipt.PlayerId), function(record)
			if record and record.Unmatched then
				record.Unmatched[receipt.PurchaseId] = nil
			end
			if record and record.UnmatchedRequests then
				record.UnmatchedRequests[receipt.PurchaseId] = nil
			end
			return record
		end)
		return nil
	end
	local archived = DataStore:UpdateAsync(ReceiptKey(receipt.PurchaseId), function(record)
		return record or intent
	end)
	return if archived and not archived.Unmatched then archived else nil
end

function Store.Replace(receipt, replacement)
	local prior = DataStore:UpdateAsync(ReceiptKey(receipt.PurchaseId), function(record)
		return record
	end)
	if prior and not prior.Unmatched then
		return prior
	end
	-- The buyer index arbitrates replacement vs. a concurrent binding before archiving.
	local saved = DataStore:UpdateAsync(BuyerKey(receipt.PlayerId), function(record: PurchaseTypes.BuyerRecord?)
		local current: PurchaseTypes.BuyerRecord = record or {}
		local receipts = current.Receipts or {}
		current.Receipts = receipts
		if not receipts[receipt.PurchaseId] then
			local selected = table.clone(replacement)
			local reconciled: { [string]: PurchaseTypes.Intent } = {}
			local candidates = (prior and prior.Reconciled)
				or (current.UnmatchedRequests and current.UnmatchedRequests[receipt.PurchaseId])
				or {}
			for requestId, original in pairs(candidates) do
				local closed = current.FastClosed and current.FastClosed[requestId]
				local active = current.Active
				local bound = active and active.RequestId == requestId and active.PurchaseId
				if
					(not closed or closed == "Cancelled" or closed == receipt.PurchaseId)
					and (not bound or bound == receipt.PurchaseId)
				then
					reconciled[requestId] = original
					local terminal = current.FastClosed or {}
					terminal[requestId] = receipt.PurchaseId
					current.FastClosed = terminal
					if active and active.RequestId == requestId then
						current.Active = nil
					end
					if current.FastPending then
						current.FastPending[requestId] = nil
					end
					if current.RecoveryPending then
						current.RecoveryPending[requestId] = nil
					end
					local cancelled = current.Cancelled or {}
					cancelled[requestId] = original
					current.Cancelled = cancelled
				end
			end
			selected.Reconciled = reconciled
			receipts[receipt.PurchaseId] = selected
		end
		if current.Unmatched then
			current.Unmatched[receipt.PurchaseId] = nil
		end
		if current.UnmatchedRequests then
			current.UnmatchedRequests[receipt.PurchaseId] = nil
		end
		return current
	end)
	local selected = assert(saved and saved.Receipts and saved.Receipts[receipt.PurchaseId])
	local archived = DataStore:UpdateAsync(ReceiptKey(receipt.PurchaseId), function(record)
		if record and not record.Unmatched then
			return record
		end
		return selected
	end)
	assert(
		archived and archived.BuyerId == receipt.PlayerId and archived.ProductId == receipt.ProductId,
		"Replacement receipt identity mismatch"
	)
	return archived
end

function Store.Complete(intent)
	local purchaseId = assert(intent.PurchaseId, "Missing bound receipt")
	DataStore:UpdateAsync(ReceiptKey(purchaseId), function(record: PurchaseTypes.Intent?)
		assert(record and record.RequestId == intent.RequestId, "Checkout binding changed")
		record.Complete = true
		return record
	end)
	local saved = DataStore:UpdateAsync(BuyerKey(intent.BuyerId), function(record: PurchaseTypes.BuyerRecord?)
		assert(record, "Missing checkout buyer")
		if record.Active and record.Active.RequestId == intent.RequestId then
			record.Active = nil
		end
		if record.Receipts then
			record.Receipts[purchaseId] = nil
		end
		if record.RecoveryPending then
			record.RecoveryPending[intent.RequestId] = nil
		end
		if intent.Strategy == "Fast" then
			local terminal = record.FastClosed or {}
			record.FastClosed = terminal
			terminal[intent.RequestId] = purchaseId
			if record.FastPending then
				record.FastPending[intent.RequestId] = nil
			end
		end
		return record
	end)
	PublishIdle(
		intent.BuyerId,
		saved ~= nil
			and saved.Active == nil
			and next(saved.FastPending or {}) == nil
			and next(saved.Cancelled or {}) == nil
	)
end

function Store.MarkDelivered(intent)
	local purchaseId = assert(intent.PurchaseId, "Missing bound receipt")
	DataStore:UpdateAsync(ReceiptKey(purchaseId), function(record: PurchaseTypes.Intent?)
		assert(record and record.RequestId == intent.RequestId, "Checkout binding changed")
		record.Delivered = true
		return record
	end)
end

return Store
