--!strict
-- Owns runtime checkout reservations and coalesced post-prompt saves, including departed buyers.

--// Services
local Players = game:GetService("Players")

--// Modules
local Types = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)
local Store = require(game:GetService("ServerScriptService").Services.PurchaseService.Checkout.Store)

--// Constants
local MAX_PENDING = 512
local MAX_WRITERS = 4

--// Properties
local Entries: { [string]: Entry } = {}
local Active: { [number]: Entry } = {}
local Locks: { [number]: boolean } = {}
local Allowances: { [string]: { Pending: number, Paid: number } } = {}
local GiftClaims: { [string]: { Key: string, Amount: number, RecipientId: number } } = {}
local Count = 0
local Writers = 0
local Notify: ((Types.Notification, string, unknown?) -> ())? = nil

--// Types
type Entry = {
	Intent: Types.Intent,
	Dirty: boolean,
	Cancelled: boolean,
	Committed: boolean,
	Finished: boolean,
	Key: string?,
	Amount: number,
	NextAttempt: number,
	Attempt: number,
	Warned: boolean,
}
export type FastCheckout = {
	SetNotify: (callback: (Types.Notification, string, unknown?) -> ()) -> (),
	Register: (intent: Types.Intent) -> (boolean, string?),
	Current: (buyerId: number) -> Types.Intent?,
	Run: (buyerId: number, callback: () -> ...any) -> ...any,
	Queue: (intent: Types.Intent) -> (),
	Cancel: (intent: Types.Intent) -> (),
	Paid: (intent: Types.Intent) -> (),
	Finish: (intent: Types.Intent) -> (),
	Retire: (intent: Types.Intent, final: boolean?) -> (),
	Delivered: (intent: Types.Notification) -> (),
	Depart: (buyerId: number) -> (),
	Drain: () -> (),
}

--// Module
local Fast = {} :: FastCheckout

--// APIs
function Fast.SetNotify(callback)
	Notify = callback
end

function Fast.Current(buyerId)
	local entry = Active[buyerId]
	return if entry and not entry.Cancelled and not entry.Finished then entry.Intent else nil
end

function Fast.Register(intent)
	if Active[intent.BuyerId] or Entries[intent.RequestId] or Count >= MAX_PENDING then
		return false, "PurchasePending"
	end
	local reservation = intent.Reservation
	local key = if reservation then tostring(intent.RecipientId) .. ":" .. reservation.Key else nil
	local amount = if reservation then reservation.Amount or 1 else 0
	if reservation and key then
		local allowance = Allowances[key] or { Pending = 0, Paid = 0 }
		if reservation.Used + allowance.Paid + allowance.Pending + amount > reservation.Limit then
			return false, "RecipientLimitReached"
		end
		allowance.Pending += amount
		Allowances[key] = allowance
	end
	local entry: Entry = {
		Intent = intent,
		Dirty = false,
		Cancelled = false,
		Committed = false,
		Finished = false,
		Key = key,
		Amount = amount,
		NextAttempt = 0,
		Attempt = 0,
		Warned = false,
	}
	Entries[intent.RequestId] = entry
	Active[intent.BuyerId] = entry
	Count += 1
	return true, nil
end

function Fast.Run(buyerId, callback)
	-- Never wait on another native call: the receipt/retry scheduler will try again.
	assert(not Locks[buyerId], "Checkout persistence is already running")
	Locks[buyerId] = true
	local result = table.pack(pcall(callback))
	Locks[buyerId] = nil
	if not result[1] then
		error(result[2])
	end
	return table.unpack(result, 2, result.n)
end

local function Release(entry: Entry, paid: boolean)
	if entry.Committed then
		return
	end
	entry.Committed = true
	local key = entry.Key
	local allowance = key and Allowances[key]
	if allowance then
		allowance.Pending -= entry.Amount
		if paid and entry.Intent.Mode == "Gift" and key and Players:GetPlayerByUserId(entry.Intent.RecipientId) then
			allowance.Paid += entry.Amount
			GiftClaims[entry.Intent.RequestId] =
				{ Key = key, Amount = entry.Amount, RecipientId = entry.Intent.RecipientId }
		end
		if allowance.Pending == 0 and allowance.Paid == 0 and key then
			Allowances[key] = nil
		end
	end
end

local function Flush(entry: Entry)
	local intent = entry.Intent
	if Locks[intent.BuyerId] or Writers >= MAX_WRITERS or not entry.Dirty then
		return
	end
	Writers += 1
	entry.Dirty = false
	local ok, result = pcall(Fast.Run, intent.BuyerId, function(): string?
		if entry.Cancelled then
			return if Store.CancelFast(intent) then "Cancelled" else "Closed"
		elseif not entry.Finished then
			return Store.SaveFast(intent)
		end
		return nil
	end)
	Writers -= 1
	if Entries[intent.RequestId] ~= entry then
		return
	end
	if ok and result then
		Fast.Retire(intent, result ~= "Recovery")
		if result == "Cancelled" and Notify then
			Notify(intent, "Cancelled", nil)
		end
		return
	end
	if not ok then
		entry.Dirty = true
		entry.Attempt += 1
		entry.NextAttempt = os.clock() + math.min(60, 2 ^ math.min(entry.Attempt, 6))
		if not entry.Warned then
			entry.Warned = true
			warn("[FastCheckout] Save pending: " .. tostring(result))
			if Notify then
				Notify(intent, "SavePending", nil)
			end
		end
	else
		entry.Attempt = 0
		entry.Warned = false
		if entry.Cancelled and Notify then
			Notify(intent, "Cancelled", nil)
		end
	end
	if not entry.Dirty and (entry.Cancelled or entry.Finished or not Players:GetPlayerByUserId(intent.BuyerId)) then
		if not entry.Finished and not entry.Cancelled then
			Release(entry, false)
		end
		if Active[intent.BuyerId] == entry then
			Active[intent.BuyerId] = nil
		end
		if Entries[intent.RequestId] == entry then
			Entries[intent.RequestId] = nil
			Count -= 1
		end
	end
end

function Fast.Queue(intent)
	local entry = Entries[intent.RequestId]
	if not entry or entry.Intent.RequestId ~= intent.RequestId then
		return
	end
	entry.Dirty = true
	-- Called only after the prompt attempt. A queued save is coalesced with payment/cancellation.
	task.spawn(Flush, entry)
end

function Fast.Cancel(intent)
	local entry = Entries[intent.RequestId]
	if not entry or entry.Intent.RequestId ~= intent.RequestId or entry.Finished then
		return
	end
	entry.Cancelled = true
	if Active[intent.BuyerId] == entry then
		Active[intent.BuyerId] = nil
	end
	Release(entry, false)
	Fast.Queue(intent)
end

function Fast.Paid(intent)
	local entry = Entries[intent.RequestId]
	if entry and entry.Intent.RequestId == intent.RequestId then
		Release(entry, true)
	end
end

function Fast.Finish(intent)
	local entry = Entries[intent.RequestId]
	if not entry or entry.Intent.RequestId ~= intent.RequestId then
		return
	end
	Release(entry, true)
	entry.Finished = true
	if Active[intent.BuyerId] == entry then
		Active[intent.BuyerId] = nil
	end
	Fast.Queue(entry.Intent)
end

function Fast.Retire(intent, final)
	-- The selection is durably closed or routed to background recovery. Release only its own gate.
	local entry = Entries[intent.RequestId]
	if entry then
		Release(entry, false)
		entry.Finished = true
		entry.Dirty = false
		if Active[intent.BuyerId] == entry then
			Active[intent.BuyerId] = nil
		end
		Entries[intent.RequestId] = nil
		Count -= 1
	end
	Fast.Delivered(intent)
	if Notify then
		Notify(intent, "CheckoutReleased", { Final = final == true })
	end
end

function Fast.Delivered(intent)
	local requestId = intent.RequestId
	local claim = requestId and GiftClaims[requestId]
	if not claim or not requestId then
		return
	end
	local allowance = Allowances[claim.Key]
	if allowance then
		allowance.Paid -= claim.Amount
		if allowance.Pending == 0 and allowance.Paid == 0 then
			Allowances[claim.Key] = nil
		end
	end
	GiftClaims[requestId] = nil
end

function Fast.Depart(buyerId)
	local entry = Active[buyerId]
	if entry and not entry.Dirty and not Locks[buyerId] then
		Release(entry, false)
		Active[buyerId] = nil
		Entries[entry.Intent.RequestId] = nil
		Count -= 1
	end
	for requestId, claim in pairs(GiftClaims) do
		if claim.RecipientId == buyerId then
			Fast.Delivered({ BuyerId = buyerId, Mode = "Gift", RequestId = requestId })
		end
	end
end

function Fast.Drain()
	local started = 0
	for _, entry in pairs(Entries) do
		if
			entry.Dirty
			and not Locks[entry.Intent.BuyerId]
			and Writers < MAX_WRITERS
			and os.clock() >= entry.NextAttempt
		then
			task.spawn(Flush, entry)
			started += 1
			if started >= MAX_WRITERS then
				break
			end
		end
	end
end

return Fast
