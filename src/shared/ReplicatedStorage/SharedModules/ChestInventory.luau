--!strict
-- OwnedChests is a JSON dictionary. Legacy comma-separated saves are read during migration.
local HttpService = game:GetService("HttpService")

local ChestInventory = {}
export type Counts = { [string]: number }

local function validate(value: any): Counts
	assert(type(value) == "table", "OwnedChests must contain a dictionary")
	local counts: Counts = {}
	for name, count in value do
		assert(type(name) == "string" and name ~= "", "Invalid OwnedChests name")
		assert(type(count) == "number" and count >= 0 and count < math.huge and count % 1 == 0,
			"Invalid OwnedChests count for " .. name)
		if count > 0 then counts[name] = count end
	end
	return counts
end

function ChestInventory.Decode(encoded: unknown): Counts
	if encoded == nil or encoded == "" then return {} end
	assert(type(encoded) == "string", "OwnedChests must be a string")
	if string.match(encoded, "^%s*[%{%[]") then
		return validate(HttpService:JSONDecode(encoded))
	end

	local counts: Counts = {}
	for _, name in string.split(encoded, ",") do
		if name ~= "" then counts[name] = (counts[name] or 0) + 1 end
	end
	return counts
end

function ChestInventory.Encode(counts: Counts): string
	local validated = validate(counts)
	-- JSONEncode may encode an empty Luau table as []; keep the attribute a JSON object.
	if next(validated) == nil then return "{}" end
	return HttpService:JSONEncode(validated)
end

return ChestInventory
