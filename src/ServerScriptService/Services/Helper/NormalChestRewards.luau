--!strict
-- Normal chest selection owns rarity weights, luck, pity and availability limits.
local NormalChestRewards = {}
type ChestInfo = {
	Rates: { [string]: number },
}
type PityRule = {
	attribute: string,
	minRarity: string,
	threshold: number,
}
type RollEntry = {
	weight: number,
	list: { string },
	rarity: string,
	rank: number,
}

function NormalChestRewards.new(WeaponConfig: any, WeaponsFolder: Instance, ReplicatedStorage: any, enforceLimits: boolean)
	local pools: { [string]: { string } } = {}
	local poolsBuilt = false
	local RARITY_RANK: { [string]: number } = { Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5 }
	local PITY: { PityRule } = {
		{ attribute = "PityEpic", minRarity = "Epic", threshold = 12 },
		{ attribute = "PityLegendary", minRarity = "Legendary", threshold = 60 },
	}

	local function buildPools(): ()
		pools = {}
		local function add(rarity: string, fullName: string): ()
			if not WeaponsFolder:FindFirstChild(fullName) then
				return
			end -- never give a weapon without a model
			pools[rarity] = pools[rarity] or {}
			table.insert(pools[rarity], fullName)
		end
		for baseName in pairs(WeaponConfig.BaseWeapons) do
			add("Common", baseName) -- the plain weapon is Common
			for rarity, variants in pairs(WeaponConfig.RarityVariants or {}) do
				for _, variant in variants do add(rarity, baseName .. variant) end
			end
		end
		poolsBuilt = true
	end

	local function availableIn(rarity: string): { string }
		local list: { string } = {}
		local limit = WeaponConfig.RarityLimits and WeaponConfig.RarityLimits[rarity]
		for _, name in ipairs(pools[rarity] or {}) do
			local existing = ReplicatedStorage:GetAttribute("Existing_" .. name) or 0
			if not enforceLimits or not limit or existing < limit then
				table.insert(list, name)
			end
		end
		return list
	end

	local function updatePity(player: Player, rolledRank: number): ()
		for _, rule in PITY do
			local current = tonumber(player:GetAttribute(rule.attribute)) or 0
			if rolledRank >= RARITY_RANK[rule.minRarity] then
				player:SetAttribute(rule.attribute, 0)
			else
				player:SetAttribute(rule.attribute, current + 1)
			end
		end
	end

	-- returns weaponFullName, rarity   (or nil)
	local function rollWeapon(player: Player, chestInfo: ChestInfo): (string?, string?)
		if not poolsBuilt then buildPools() end

		-- optional luck hook: player attribute "Luck" (0 = none) boosts every rarity except Common
		local luckAttr = player:GetAttribute("Luck")
		local luck = 1 + math.max(0, if type(luckAttr) == "number" then luckAttr else 0)

		-- pity: is this roll forced to a minimum rarity?
		local forceRank = 0
		for _, rule in PITY do
			if (tonumber(player:GetAttribute(rule.attribute)) or 0) + 1 >= rule.threshold then
				forceRank = math.max(forceRank, RARITY_RANK[rule.minRarity])
			end
		end

		local function collect(minRank: number): ({ RollEntry }, number)
			local entries: { RollEntry } = {}
			local total = 0
			for rarity, rate in chestInfo.Rates do
				local rank = RARITY_RANK[rarity] or 1
				if rate > 0 and rank >= minRank then
					local list = availableIn(rarity)
					if #list > 0 then
						local weight = if rarity == "Common" then rate else rate * luck
						total += weight
						table.insert(entries, { weight = weight, list = list, rarity = rarity, rank = rank })
					end
				end
			end
			return entries, total
		end

		local entries, total = collect(forceRank)
		if total <= 0 and forceRank > 0 then
			entries, total = collect(0) -- this chest cannot give the pity rarity: roll normally
		end

		if total <= 0 then
			-- every rarity of this chest is exhausted: hand out anything still available
			for rarity in pools do
				local list = availableIn(rarity)
				if #list > 0 then return list[math.random(#list)], rarity end
			end
			return nil, nil
		end

		local chosen = entries[#entries]
		local roll = math.random() * total
		for _, entry in entries do
			roll -= entry.weight
			if roll <= 0 then
				chosen = entry
				break
			end
		end

		updatePity(player, chosen.rank)
		return chosen.list[math.random(#chosen.list)], chosen.rarity
	end


	return {
		Roll = function(player: Player, info: ChestInfo): string? return (rollWeapon(player, info)) end,
		BuildPools = function(): { [string]: { string } }
			buildPools()
			return pools
		end,
	}
end

return NormalChestRewards
