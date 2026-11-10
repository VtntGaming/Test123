--!strict
-- Derives a deterministic limited-item schedule shared across servers and restarts.

--// Types
export type Entry = { ID: number, Item: string, Image: string, Robux: number? }
export type Config = {
	List: { Entry },
	Duration: number,
	StartAt: number,
	Seed: number,
	Version: number,
	RotationOrder: { [number]: string | boolean }?,
}
export type Offer = {
	Entry: Entry,
	Key: string,
	Index: number,
	StartsAt: number,
	EndsAt: number,
}
export type LimitedItemRotation = {
	Validate: (config: Config) -> (),
	GetOffer: (config: Config, now: number) -> Offer?,
	GetLatestOffer: (config: Config, item: string, now: number) -> Offer?,
}

--// Module
local Rotation = {} :: LimitedItemRotation

--// APIs
local function Integer(value: number, minimum: number): boolean
	return type(value) == "number" and value >= minimum and value < math.huge and value % 1 == 0
end

function Rotation.Validate(config)
	assert(Integer(config.Duration, 1), "LimitedItem.Duration must be a positive integer in seconds")
	assert(Integer(config.StartAt, 0), "LimitedItem.StartAt must be a Unix timestamp")
	assert(Integer(config.Seed, 0) and config.Seed < 2147483647, "Invalid LimitedItem.Seed")
	assert(Integer(config.Version, 1), "LimitedItem.Version must be a positive integer")
	assert(#config.List > 0, "LimitedItem.List must not be empty")
	local names, ids = {}, {}
	for _, entry in ipairs(config.List) do
		-- assert(
		-- 	type(entry.Item) == "string" and entry.Item ~= "" and not names[entry.Item],
		-- 	"Duplicate/invalid limited weapon"
		-- )
		assert(Integer(entry.ID, 0), "Invalid limited item product ID")
		assert(entry.ID == 0 or not ids[entry.ID], "Limited weapons must have distinct product IDs")
		assert(type(entry.Image) == "string", "Limited item Image must be a string")
		assert(
			entry.Robux == nil or Integer(entry.Robux, 1),
			"Limited item Robux must be a positive integer when supplied"
		)
		names[entry.Item] = true
		ids[entry.ID] = true
	end
	if config.RotationOrder ~= nil then
		assert(type(config.RotationOrder) == "table", "LimitedItem.RotationOrder must be a table")
		local fixed = {}
		for position, item in pairs(config.RotationOrder) do
			assert(
				Integer(position, 1) and position <= #config.List,
				"RotationOrder positions must be between 1 and #LimitedItem.List"
			)
			if item ~= false then
				assert(type(item) == "string" and names[item], "Unknown RotationOrder weapon")
				assert(not fixed[item], "RotationOrder can only include each weapon once")
				fixed[item] = true
			end
		end
	end
end

local function Shuffle(order: { number }, seed: number)
	local rng = Random.new(seed)
	for i = #order, 2, -1 do
		local other = rng:NextInteger(1, i)
		order[i], order[other] = order[other], order[i]
	end
end

local function RandomItemIndex(config: Config, slot: number): number
	local count = #config.List
	local cycle = math.floor(slot / count)
	local offset = slot % count + 1
	local order = {}
	if count <= 2 then
		-- With two entries, alternating is the only order without consecutive repeats.
		for i = 1, count do
			table.insert(order, i)
		end
		Shuffle(order, config.Seed)
	else
		-- Fix the last entry independently, then shuffle the rest. The previous
		-- cycle's last entry can be computed without recursively rebuilding history.
		local last = (cycle + config.Seed) % count + 1
		local previousLast = (cycle - 1 + config.Seed) % count + 1
		for i = 1, count do
			if i ~= last then
				table.insert(order, i)
			end
		end
		Shuffle(order, (config.Seed + cycle * 48271) % 2147483647)
		if order[1] == previousLast then
			order[1], order[2] = order[2], order[1]
		end
		table.insert(order, last)
	end
	return order[offset]
end

local function ItemIndex(config: Config, slot: number): number
	local requested = config.RotationOrder
	if requested == nil or next(requested) == nil then
		return RandomItemIndex(config, slot)
	end

	local count = #config.List
	local cycle = math.floor(slot / count)
	local offset = slot % count + 1
	local order: { [number]: number } = {}
	local reserved: { [number]: boolean } = {}
	for position, item in pairs(requested) do
		if type(item) == "string" then
			for index, entry in ipairs(config.List) do
				if entry.Item == item then
					order[position] = index
					reserved[index] = true
					break
				end
			end
		end
	end
	local remaining: { number } = {}
	for index = 1, count do
		if not reserved[index] then
			table.insert(remaining, index)
		end
	end

	if not order[count] then
		local last, previousLast
		if not order[1] and #remaining <= 2 then
			-- Only two free endpoints cannot swap between cycles without repeating
			-- at the boundary. Choose their order once and retain it.
			Shuffle(remaining, config.Seed)
			last = remaining[#remaining]
			previousLast = last
		else
			last = remaining[(cycle + config.Seed) % #remaining + 1]
			previousLast = remaining[(cycle - 1 + config.Seed) % #remaining + 1]
		end
		order[count] = last
		table.remove(remaining, assert(table.find(remaining, last)))
		Shuffle(remaining, (config.Seed + cycle * 48271) % 2147483647)
		if not order[1] and remaining[1] == previousLast then
			remaining[1], remaining[2] = remaining[2], remaining[1]
		end
	else
		-- A fixed final weapon is reserved, so no random first position can repeat it.
		Shuffle(remaining, (config.Seed + cycle * 48271) % 2147483647)
	end
	local nextRandom = 1
	for position = 1, count do
		if not order[position] then
			order[position] = remaining[nextRandom]
			nextRandom += 1
		end
	end
	return order[offset]
end

function Rotation.GetOffer(config, now)
	if now < config.StartAt then
		return nil
	end
	local slot = math.floor((now - config.StartAt) / config.Duration)
	local startsAt = config.StartAt + slot * config.Duration
	return {
		Entry = config.List[ItemIndex(config, slot)],
		Key = string.format("LimitedItem:%d:%d:%d:%d", config.Version, config.StartAt, config.Duration, slot),
		Index = slot,
		StartsAt = startsAt,
		EndsAt = startsAt + config.Duration,
	}
end

-- Product IDs identify weapons permanently. A delayed receipt uses that weapon's
-- most recent offer, rather than granting whatever happens to be displayed now.
function Rotation.GetLatestOffer(config, item, now)
	if now < config.StartAt then
		return nil
	end
	local currentSlot = math.floor((now - config.StartAt) / config.Duration)
	for slot = currentSlot, math.max(0, currentSlot - #config.List * 2 + 1), -1 do
		local offer = Rotation.GetOffer(config, config.StartAt + slot * config.Duration)
		if offer and offer.Entry.Item == item then
			return offer
		end
	end
	return nil
end

return Rotation
