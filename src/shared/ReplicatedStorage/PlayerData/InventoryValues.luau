--!strict
-- Converts legacy inventory strings to item counts without changing gameplay or persistence callers.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local ChestInventory = require(ReplicatedStorage.SharedModules.ChestInventory)

--// Types
export type Counts = { [string]: number }
export type InventoryValues = {
	-- Returns whether the logical key is stored as a folder of per-item counts.
	Contains: (string) -> boolean,
	-- Decodes the existing comma-list or chest JSON format, preserving repeated item quantities.
	Decode: (string, string) -> Counts,
	-- Encodes counts for existing callers; comma lists use sorted item names and preserve duplicates.
	Encode: (string, Counts) -> string,
	-- Builds ownership lookup counts; CSV inventory names use existing trimmed-name semantics.
	Lookup: (string, Counts) -> Counts,
}

--// Store
local InventoryValues: InventoryValues = {} :: InventoryValues

--// APIs
function InventoryValues.Contains(key)
	return key == "OwnedWeapons" or key == "OwnedAbilities" or key == "OwnedChests"
end

function InventoryValues.Decode(key, encoded)
	if key == "OwnedChests" then
		return ChestInventory.Decode(encoded)
	end
	local counts: Counts = {}
	for _, name in string.split(encoded, ",") do
		if name ~= "" then
			counts[name] = (counts[name] or 0) + 1
		end
	end
	return counts
end

function InventoryValues.Encode(key, counts)
	if key == "OwnedChests" then
		return ChestInventory.Encode(counts)
	end
	local names: { string } = {}
	for name in counts do
		table.insert(names, name)
	end
	table.sort(names)
	local entries: { string } = {}
	for _, name in names do
		for _ = 1, counts[name] do
			table.insert(entries, name)
		end
	end
	return table.concat(entries, ",")
end

function InventoryValues.Lookup(key, counts)
	local lookup: Counts = {}
	for name, count in counts do
		local normalized = if key == "OwnedChests" then name else (string.match(name, "^%s*(.-)%s*$") or name)
		lookup[normalized] = (lookup[normalized] or 0) + count
	end
	return lookup
end

return InventoryValues
