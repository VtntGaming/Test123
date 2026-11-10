--!strict
-- Persists receipt journals, retired product catalogs and quarantined legacy records without expanding profiles.

--// Services
local DataStoreService = game:GetService("DataStoreService")

--// Modules
local PurchaseTypes = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)

--// References
local DataStore = DataStoreService:GetDataStore("RobuxShopReceipts_V1")

--// Types
export type ReceiptStore = {
	Catalog: (kind: string, entries: any) -> any,
	Read: (id: string, userId: number) -> any,
	Prepare: (receipt: PurchaseTypes.Receipt, kind: string, resolve: () -> any, legacyComplete: boolean?) -> any,
	Finish: (id: string, record: any, stage: string) -> any,
	Quarantine: (userId: number, field: string, value: any) -> (),
	HasBudget: () -> boolean,
}

--// Module
local Store = {} :: ReceiptStore

--// APIs
function Store.Catalog(kind, entries)
	local saved = DataStore:UpdateAsync("Catalog:" .. kind, function(record)
		record = record or {}
		for id, entry in pairs(entries) do
			record[tostring(id)] = entry
		end
		return record
	end)
	assert(saved, "Product catalog did not persist")
	return saved
end

function Store.Read(id, userId)
	local record = DataStore:GetAsync("R:" .. id)
	if record then
		assert(record.PlayerId == userId, "Receipt owner mismatch")
	end
	return record
end

function Store.Prepare(receipt, kind, resolve, legacyComplete)
	local saved = DataStore:UpdateAsync("R:" .. receipt.PurchaseId, function(record)
		if record then
			assert(
				record.PlayerId == receipt.PlayerId and (record.ProductId == receipt.ProductId or record.Legacy == true),
				"Receipt identity mismatch"
			)
			assert(record.Kind == kind, "Receipt kind mismatch")
			return record
		end
		return {
			PlayerId = receipt.PlayerId,
			ProductId = receipt.ProductId,
			Kind = kind,
			Reward = if legacyComplete then nil else resolve(),
			Stage = if legacyComplete then "Complete" else "Prepared",
			CreatedAt = os.time(),
			Legacy = legacyComplete == true,
		}
	end)
	assert(saved, "Receipt preparation did not persist")
	return saved
end

function Store.Finish(id, record, stage)
	local saved = DataStore:UpdateAsync("R:" .. id, function(current)
		assert(
			current and current.PlayerId == record.PlayerId and current.Kind == record.Kind,
			"Missing/mismatched prepared receipt"
		)
		if current.Stage ~= "Complete" then
			current.Stage = stage
			if record.Reward then
				current.Reward = record.Reward
			end
		end
		return current
	end)
	assert(saved, "Receipt finalization did not persist")
	return saved
end

function Store.Quarantine(userId, field, value)
	local first, second = 5381, 7919
	for index = 1, #field do
		first = (first * 33 + string.byte(field, index)) % 4294967296
		second = (second * 65599 + string.byte(field, index)) % 4294967296
	end
	local key = string.format("Q:%d:%08x%08x", userId, first, second)
	DataStore:UpdateAsync(key, function(current)
		return current or { Field = field, Value = value, CreatedAt = os.time() }
	end)
end

function Store.HasBudget()
	return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) >= 5
end

return Store
