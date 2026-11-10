--!strict
-- Pure time-derived offers. Sort dictionary keys before using seeded randomness.
local Rotation = {}

export type Entry = { ID: number, Variant: { string }, Quantity: { number }, OriginalPrice: number? }
export type Config = { List: { Entry }, Seed: number, Duration: number, StartAt: number }
export type Offer = {
	Index: number,
	ProductId: number,
	Weapon: string,
	Variant: string,
	Quantity: number,
	OriginalPrice: number?,
	Available: boolean,
}
export type Snapshot = {
	RotationKey: string,
	Rotation: number,
	StartsAt: number,
	EndsAt: number,
	Offers: { Offer },
}

local function integer(value: any, minimum: number): boolean
	return type(value) == "number" and value >= minimum and value < math.huge and value % 1 == 0
end

function Rotation.Validate(config: Config, weaponConfig: any)
	assert(integer(config.Seed, 0) and config.Seed < 2147483647, "Invalid WeaponPacks.Seed")
	assert(integer(config.Duration, 1), "WeaponPacks.Duration must be positive integer seconds")
	assert(integer(config.StartAt, 0), "WeaponPacks.StartAt must be a Unix timestamp")
	assert(#config.List > 0 and next(weaponConfig.BaseWeapons), "Empty weapon pack list/base weapons")
	local knownVariants, ids = {}, {}
	for _, variants in pairs(weaponConfig.RarityVariants) do
		for _, variant in ipairs(variants) do
			knownVariants[variant] = true
		end
	end
	for _, entry in ipairs(config.List) do
		assert(integer(entry.ID, -1), "Weapon pack ID must be -1, 0 or a developer product ID")
		if entry.ID > 0 then
			assert(not ids[entry.ID], "Weapon packs must have distinct developer product IDs")
			ids[entry.ID] = true
		end
		assert(#entry.Variant > 0 and #entry.Quantity > 0, "Empty weapon pack variants/quantities")
		for _, variant in ipairs(entry.Variant) do
			assert(knownVariants[variant], "Unknown weapon pack variant: " .. tostring(variant))
		end
		for _, quantity in ipairs(entry.Quantity) do
			assert(integer(quantity, 1), "Weapon pack quantities must be positive integers")
		end
		assert(entry.OriginalPrice == nil or integer(entry.OriginalPrice, 0), "Invalid weapon pack OriginalPrice")
	end
end

function Rotation.GetSnapshot(config: Config, weaponConfig: any, now: number): Snapshot?
	if now < config.StartAt then
		return nil
	end
	local slot = math.floor((now - config.StartAt) / config.Duration)
	local startsAt = config.StartAt + slot * config.Duration
	local bases = {}
	for name in pairs(weaponConfig.BaseWeapons) do
		table.insert(bases, name)
	end
	table.sort(bases)
	local offers = {}
	for index, entry in ipairs(config.List) do
		local rng = Random.new((config.Seed + slot * 48271 + index * 69621) % 2147483647)
		local variant = entry.Variant[rng:NextInteger(1, #entry.Variant)]
		local base = bases[rng:NextInteger(1, #bases)]
		table.insert(offers, {
			Index = index,
			ProductId = entry.ID,
			Weapon = base .. variant,
			Variant = variant,
			Quantity = entry.Quantity[rng:NextInteger(1, #entry.Quantity)],
			OriginalPrice = entry.OriginalPrice,
			Available = entry.ID ~= 0,
		})
	end
	return {
		RotationKey = string.format("WeaponPacks:%d:%d:%d:%d", config.Seed, config.StartAt, config.Duration, slot),
		Rotation = slot,
		StartsAt = startsAt,
		EndsAt = startsAt + config.Duration,
		Offers = offers,
	}
end

return Rotation
