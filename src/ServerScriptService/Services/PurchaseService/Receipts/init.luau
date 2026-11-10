--!strict
-- Coordinates receipt preparation, profile grants and journals, durable finalization and retry recovery.

--// Services
local Players = game:GetService("Players")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PurchaseTypes = require(Services.PurchaseService.Types)
local Data = require(Services.PlayerDataService)
local Runtime = require(Services.Helper.ShopRuntime)
local Store = require(Services.PurchaseService.Receipts.Store)

--// Constants
local MAX_JOURNAL = 256

--// Properties
local Definitions: { [string]: any } = {}
local Initialized = false
local WatchPlayer: ((Player) -> ())? = nil
local Connections: { [Player]: RBXScriptConnection } = {}
local Catalogs: { [string]: any } = {}
local ProductOwners: { [number]: string } = {}
local Results: { [Player]: any } = {}

--// Types
export type Receipts = {
	Result: (player: Player, id: string) -> any,
	Products: (kind: string, entries: any, register: any, factory: any) -> (),
	State: (player: Player) -> any,
	Register: (kind: string, definition: any) -> (),
	Dirty: (player: Player) -> (),
	Process: (
		player: Player,
		receipt: PurchaseTypes.Receipt,
		kind: string,
		resolve: () -> any,
		preflight: (() -> boolean)?
	) -> boolean,
	Wake: (player: Player) -> (),
	Setup: (self: Receipts) -> (),
	Start: (self: Receipts) -> (),
	Init: () -> (),
}

--// Module
local Receipts = {} :: Receipts

--// APIs
function Receipts.Result(player, id)
	local result = Results[player]
	return if result and result.Id == id then result.Reward else nil
end

-- Configured products register immediately even during a storage outage. Catalog
-- recovery imports retired IDs asynchronously; failed catalog I/O never blocks joins.
function Receipts.Products(kind, entries, register, factory)
	local catalog = Catalogs[kind]
	if not catalog then
		catalog = { Registered = {} }
		Catalogs[kind] = catalog
	end
	local function install(id: number, entry: any)
		assert(not ProductOwners[id] or ProductOwners[id] == kind, "Product ID used by multiple persistent sections")
		if catalog.Registered[id] then
			return
		end
		register(id, factory(id, entry))
		catalog.Registered[id], ProductOwners[id] = true, kind
	end
	for id, entry in pairs(entries) do
		install(id, entry)
	end
	if catalog.Started then
		return
	end
	catalog.Started = true
	local function synchronize()
		local ok, result = Runtime.Await(30, function()
			return Store.Catalog(kind, entries)
		end)
		if ok then
			local installed, err = pcall(function()
				for id, entry in pairs(result) do
					install(assert(tonumber(id)), entry)
				end
			end)
			if installed then
				return
			end
			warn("[PurchaseReceipts] Catalog registration: " .. tostring(err))
		end
		task.delay(60, synchronize)
	end
	task.spawn(synchronize)
end

function Receipts.State(player)
	return Data.GetPurchaseState(player)
end

function Receipts.Register(kind, definition)
	assert(not Definitions[kind] or Definitions[kind] == definition, "Duplicate persistent reward kind: " .. kind)
	Definitions[kind] = definition
end

function Receipts.Dirty(player)
	Runtime.Schedule(player, "PurchaseProfile", function()
		return Data.SavePlayer(player, true)
	end)
end

-- Legacy interpretation is registered by the owning product section.
local function Legacy(state: any, id: string, kind: string): (any, boolean)
	local definition = Definitions[kind]
	local adapter = definition and definition.Legacy
	local records = adapter and state.Legacy[adapter.Field]
	local raw = records and records[id]
	if raw ~= nil and adapter.Validate(raw) then
		return raw, adapter.IsComplete(raw)
	end
	return nil, false
end

local function RemoveLegacy(state: any, id: string, kind: string)
	local definition = Definitions[kind]
	local adapter = definition and definition.Legacy
	local records = adapter and state.Legacy[adapter.Field]
	if records then
		records[id] = nil
	end
end

local function Count(map: any): number
	local size = 0
	for _ in pairs(map) do
		size += 1
	end
	return size
end

local function PersistJournal(player: Player, id: string, token: any): boolean
	local state = Receipts.State(player)
	local entry = state.Journal[id]
	if not entry then
		return true
	end
	if not Data.SavePlayer(player, true) or not Runtime.Valid(player, "Receipt", token) then
		return false
	end
	Store.Finish(id, { PlayerId = player.UserId, Kind = entry.Kind, Reward = entry.Reward }, entry.Stage)
	if not Runtime.Valid(player, "Receipt", token) then
		return false
	end
	if state.Journal[id] == entry then
		state.Journal[id] = nil
	end
	RemoveLegacy(state, id, entry.Kind)
	Receipts.Dirty(player)
	return true
end

function Receipts.Process(player, receipt, kind, resolve, preflight)
	assert(
		type(receipt.PurchaseId) == "string" and #receipt.PurchaseId > 0 and #receipt.PurchaseId <= 47,
		"Invalid PurchaseId"
	)
	assert(receipt.PlayerId == player.UserId, "Receipt buyer mismatch")
	local id = receipt.PurchaseId
	local success = Runtime.Run(player, "Receipt", function(token)
		local definition = assert(Definitions[kind], "Persistent reward handler not ready")
		local state = Receipts.State(player)
		local old, complete = Legacy(state, id, kind)
		if preflight and not old and not complete and not state.Journal[id] then
			local existing = Store.Read(id, player.UserId)
			if not Runtime.Valid(player, "Receipt", token) then
				return false, "TimedOut"
			end
			if not existing and not preflight() then
				return false, "Unavailable"
			end
			if not Runtime.Valid(player, "Receipt", token) then
				return false, "TimedOut"
			end
		end
		local record = Store.Prepare(receipt, kind, function()
			assert(Runtime.Valid(player, "Receipt", token), "Expired receipt preparation")
			return if old and not complete then old else resolve()
		end, complete)
		if not Runtime.Valid(player, "Receipt", token) then
			return false, "TimedOut"
		end
		if complete then
			Store.Finish(id, record, "Complete")
			if not Runtime.Valid(player, "Receipt", token) then
				return false, "TimedOut"
			end
			record.Stage = "Complete"
		end
		if record.Stage == "Complete" then
			state.Journal[id] = nil
			RemoveLegacy(state, id, kind)
			Receipts.Dirty(player)
			Results[player] = { Id = id, Reward = record.Reward }
			return true, nil
		end
		if not state.Journal[id] then
			if Count(state.Journal) >= MAX_JOURNAL then
				return false, "RetryLater"
			end
			-- Apply callbacks must prepare/validate all data first and must never yield.
			definition.Apply(player, record.Reward, id)
			state.Journal[id] = {
				Kind = kind,
				ProductId = receipt.ProductId,
				Reward = record.Reward,
				Stage = definition.Stage or "Complete",
			}
		end
		local reward = state.Journal[id].Reward
		local persisted = PersistJournal(player, id, token)
		if persisted and Runtime.Valid(player, "Receipt", token) then
			Results[player] = { Id = id, Reward = reward }
		end
		return persisted, nil
	end)
	if not success then
		Runtime.Schedule(player, "Receipt:" .. id, function()
			return Receipts.Process(player, receipt, kind, resolve, preflight)
		end)
	end
	return success
end

local function Recover(player: Player): boolean
	if not Runtime.Ready(player) then
		return false
	end
	local state = Receipts.State(player)
	local work = 0
	-- Keep damaged record IDs until the original ledger result can be restored.
	for id in pairs(state.Recovery) do
		if not Store.HasBudget() then
			return false
		end
		local record = Store.Read(id, player.UserId)
		if record and record.Stage ~= "Complete" then
			if not Definitions[record.Kind] then
				return false
			end
			if
				not Receipts.Process(
					player,
					{
						PlayerId = player.UserId,
						ProductId = record.ProductId,
						PurchaseId = id,
					},
					record.Kind,
					function()
						return record.Reward
					end
				)
			then
				return false
			end
		end
		state.Recovery[id] = nil
		Receipts.Dirty(player)
		work += 1
		if work >= 4 then
			return false
		end
	end
	for id in pairs(state.Journal) do
		local done = Runtime.Run(player, "Receipt", function(token)
			return PersistJournal(player, id, token), nil
		end)
		if not done then
			return false
		end
		work += 1
		if work >= 4 then
			return false
		end
	end
	if not Store.HasBudget() then
		return false
	end
	-- At most four legacy imports per pass; gameplay never waits for migration.
	local processed = 0
	for kind, definition in pairs(Definitions) do
		local adapter = definition.Legacy
		local records = if adapter then state.Legacy[adapter.Field] or {} else {}
		for id, old in pairs(records) do
			if not adapter.Validate(old) then
				state.Quarantine["Legacy:" .. id] = old
				records[id] = nil
			else
				local imported = Receipts.Process(
					player,
					{
						PlayerId = player.UserId,
						ProductId = adapter.ProductId(old),
						PurchaseId = id,
					},
					kind,
					function()
						return old
					end
				)
				if not imported then
					return false
				end
			end
			processed += 1
			if processed >= 4 then
				return false
			end
			task.wait()
		end
	end
	-- Product sections may still be initializing. Keep unknown legacy work pending.
	for field, records in pairs(state.Legacy) do
		if next(records) ~= nil then
			return false
		end
	end
	for field, raw in pairs(state.Quarantine) do
		Store.Quarantine(player.UserId, field, raw)
		if state.Quarantine[field] == raw then
			state.Quarantine[field] = nil
		end
		Receipts.Dirty(player)
		return false
	end
	return true
end

function Receipts.Wake(player)
	Runtime.Schedule(player, "PurchaseRecovery", function()
		return Recover(player)
	end)
end

function Receipts:Setup()
	WatchPlayer = function(player: Player)
		Connections[player] = player:GetAttributeChangedSignal("DataLoaded"):Connect(function()
			if Runtime.Ready(player) then
				Receipts.Wake(player)
			end
		end)
		if Runtime.Ready(player) then
			Receipts.Wake(player)
		end
	end
end

function Receipts:Start()
	local watch = assert(WatchPlayer, "Receipts.Setup must run before Start")
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(player)
		Results[player] = nil
		if Connections[player] then
			Connections[player]:Disconnect()
			Connections[player] = nil
		end
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
end

function Receipts.Init()
	if Initialized then
		return
	end
	Receipts:Setup()
	Receipts:Start()
	Initialized = true
end

return Receipts
