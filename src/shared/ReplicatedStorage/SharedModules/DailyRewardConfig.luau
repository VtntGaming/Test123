-- DailyRewardConfig
-- One reward per day, shown on the Day1..DayN cards of StarterGui.MainGui.DailyRewardFrame.
-- Shared by the server (grants) and the client (UI).
--
-- HOW IT WORKS
--   * A day unlocks ClaimCooldown seconds after the previous claim (24h by default).
--   * There is NO streak: missing days never costs the player progress, they just continue where they left off.
--   * After the last day: LoopAfterLastDay = false -> the calendar stays completed.
--                         LoopAfterLastDay = true  -> a fresh cycle starts after the cooldown.
--
-- CHANGING A REWARD = edit its line in the DAYS list below. The UI is never touched: the card text,
-- icon and glow color all come from here.
--
--   Type      "Coins" | "Chest" | "Weapon"                                              (required)
--   Amount    Coins:  how many coins                                                    (Coins only)
--   Item      Chest:  any key of ChestConfig.Chests / Weapon: any full weapon name      (Chest / Weapon)
--             (a weapon needs a model with the same name in ReplicatedStorage.Assets.Weapons)
--   Quantity  Chest:  how many chests, default 1                                        (Chest only)
--   Image     icon shown on the card, "rbxassetid://..."                                (recommended)
--             if you leave it out, the icon of the chest / weapon / coins is used instead
--   Label     (optional) text on the card. Default: "250", "x2 Wooden", the weapon's display name
--   Color     (optional) Color3 of the card glow + text. Default: chest color / weapon rarity color / coins color
--
--   { Type = "Coins",  Amount = 250,                  Image = "rbxassetid://86241191871484" }
--   { Type = "Chest",  Item = "Wooden", Quantity = 2, Image = "rbxassetid://74107152687727" }
--   { Type = "Weapon", Item = "SlapFire",             Image = "rbxassetid://120921841513867" }

local RobuxShopConfig = require(script.Parent.RobuxShopConfig)
local ChestConfig = require(script.Parent:WaitForChild("ChestConfig"))
local WeaponConfig = require(script.Parent:WaitForChild("WeaponConfig"))

local DailyRewardConfig = {}

-- ==========================================
-- SETTINGS
-- ==========================================
DailyRewardConfig.UISlots = 7                  -- how many Day cards the UI has (Day1..Day7). Rewards past this are ignored.
DailyRewardConfig.ClaimCooldown = 24 * 60 * 60 -- seconds between two claims
DailyRewardConfig.LoopAfterLastDay = false     -- start a new cycle after the last day?
DailyRewardConfig.AutoOpenWhenClaimable = true -- pop the window up once after joining if a reward is ready
DailyRewardConfig.AutoOpenDelay = 2            -- seconds after the loading screen is gone

-- ==========================================
-- MONETIZATION
-- ==========================================
-- Developer Product that skips the wait: the buyer instantly claims the next day's reward and the 24h
-- timer for the day after starts from that moment. 0 = disabled (the waiting card shows "SOON" instead).
-- TODO: create a Developer Product in the Creator Dashboard and paste its ID here.
DailyRewardConfig.SkipDailyProductId = RobuxShopConfig.DailyRewards.SkipDailyProductId

-- Fallbacks, only used when a reward has no Image / Color of its own.
DailyRewardConfig.CoinsIcon = "rbxassetid://86241191871484"
DailyRewardConfig.CoinsColor = Color3.fromRGB(255, 200, 40)

-- ==========================================
-- THE DAYS  (one line = one card, in order: first line = Day 1)
-- ==========================================
local DAYS = {
	{ Type = "Coins",  Amount = 100,                  Image = "rbxassetid://138957212341782" },  -- Day 1
	{ Type = "Buff",  Item = "x2Coin", Amount = 60*10,Image = "rbxassetid://122743071357499" },  -- Day 2
	{ Type = "Coins",  Amount = 500,                  Image = "rbxassetid://138957212341782" },  -- Day 3
	{ Type = "LuckyChest",  Item = "Fire", Quantity = 1, Image = "rbxassetid://76398618402432" },  -- Day 4
	{ Type = "Coins",  Amount = 1000,                 Image = "rbxassetid://85104578461278" },  -- Day 5
	{ Type = "Chest",  Item = "Diamond",   Quantity = 1, Image = "rbxassetid://100574297197050" }, -- Day 6
	{ Type = "Weapon", Item = "SlapRainbow",          Image = "rbxassetid://106259603973412" }, -- Day 7 (Epic) week prize

	-- Not shown: the UI only has 7 cards. Add Day8..DayN cards to the UI + raise UISlots to use these.
	--{ Type = "Coins",  Amount = 1500 },                                                        -- Day 8
	--{ Type = "Chest",  Item = "Silver",   Quantity = 3 },                                      -- Day 9
	--{ Type = "Chest",  Item = "Obsidian", Quantity = 1 },                                      -- Day 10
	--{ Type = "Coins",  Amount = 2500 },                                                        -- Day 11
	--{ Type = "Chest",  Item = "Diamond",  Quantity = 1 },                                      -- Day 12
	--{ Type = "Coins",  Amount = 5000 },                                                        -- Day 13
	--{ Type = "Weapon", Item = "BatKing" },                                                     -- Day 14 (Legendary)
}

-- ==========================================
-- RESOLVED REWARDS (what the UI and the service read)
-- ==========================================
export type Reward = {
	Type: string,
	Amount: number?,   -- Coins
	Item: string?,     -- Chest key / full weapon name
	Quantity: number?, -- Chest
	Label: string,     -- short text on the card
	Name: string,      -- full text for notifications
	Image: string,
	Color: Color3,
}

local function formatNumber(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

-- Returns the value written in the config if it has the right type, otherwise the fallback.
local function pick(day: number, def: any, field: string, expectedType: string, fallback: any): any
	local value = def[field]
	if value == nil or value == "" then return fallback end
	if typeof(value) ~= expectedType then
		warn(("[DailyRewardConfig] Day %d: %s must be a %s (got %s), using the default"):format(day, field, expectedType, typeof(value)))
		return fallback
	end
	return value
end

local function resolve(day: number, def: any): Reward?
	if def.Type == "Coins" then
		local amount = def.Amount
		if type(amount) ~= "number" or amount <= 0 or amount % 1 ~= 0 then
			warn(("[DailyRewardConfig] Day %d: Coins needs a positive whole Amount"):format(day))
			return nil
		end
		return {
			Type = "Coins", Amount = amount,
			Label = pick(day, def, "Label", "string", formatNumber(amount)),
			Name = formatNumber(amount) .. " Coins",
			Image = pick(day, def, "Image", "string", DailyRewardConfig.CoinsIcon),
			Color = pick(day, def, "Color", "Color3", DailyRewardConfig.CoinsColor),
		}

	elseif def.Type == "Chest" then
		local chest = ChestConfig.Chests[def.Item]
		local quantity = def.Quantity or 1
		if not chest then
			warn(("[DailyRewardConfig] Day %d: unknown chest '%s' (see ChestConfig.Chests)"):format(day, tostring(def.Item)))
			return nil
		end
		if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
			warn(("[DailyRewardConfig] Day %d: Chest Quantity must be a positive whole number"):format(day))
			return nil
		end
		return {
			Type = "Chest", Item = def.Item, Quantity = quantity,
			Label = pick(day, def, "Label", "string", ("x%d %s"):format(quantity, def.Item)),
			Name = ("%dx %s Chest"):format(quantity, def.Item),
			Image = pick(day, def, "Image", "string", chest.Thumbnail),
			Color = pick(day, def, "Color", "Color3", chest.Color),
		}
	elseif def.Type == "LuckyChest" then
		local luckyChest = RobuxShopConfig.LuckyChestPacks[def.Item]
		local quantity = def.Quantity or 1
		if not luckyChest then
			warn(("[DailyRewardConfig] Day %d: unknown chest '%s' (see RobuxShopConfig.LuckyChestPacks)"):format(day, tostring(def.Item)))
			return nil
		end
		if type(quantity) ~= "number" or quantity <= 0 or quantity % 1 ~= 0 then
			warn(("[DailyRewardConfig] Day %d: Lucky Chest Quantity must be a positive whole number"):format(day))
			return nil
		end
		return {
			Type = "LuckyChest", Item = def.Item, Quantity = quantity,
			Label = pick(day, def, "Label", "string", ("x%d %s"):format(quantity, def.Item)),
			Name = ("%dx %s Chest"):format(quantity, def.Item),
			Image = pick(day, def, "Image", "string", luckyChest.Thumbnail),
			Color = pick(day, def, "Color", "Color3", luckyChest.Color),
		}
	elseif def.Type == "Weapon" then
		local info = def.Item and WeaponConfig.GetWeaponInfo(def.Item)
		if not info then
			warn(("[DailyRewardConfig] Day %d: unknown weapon '%s' (see WeaponConfig)"):format(day, tostring(def.Item)))
			return nil
		end
		return {
			Type = "Weapon", Item = def.Item, Quantity = 1,
			Label = pick(day, def, "Label", "string", info.DisplayName),
			Name = info.DisplayName .. " (" .. info.Rarity .. ")",
			Image = pick(day, def, "Image", "string", info.Icon),
			Color = pick(day, def, "Color", "Color3", info.RarityColor),
		}
	elseif def.Type == "Buff" then
		return {
			Type = "Buff", Item = def.Item, Quantity = 1,
			Label = pick(day, def, "Label", "string", ("x%d %s"):format(math.floor(def.Amount/60), "mins")),
			Name = "x2 Coin",
			Image = pick(day, def, "Image", "string", def.Image),
			Color = pick(day, def, "Color", "Color3", Color3.fromRGB(209, 201, 201)),
			Amount = def.Amount
		}
	end

	warn(("[DailyRewardConfig] Day %d: unknown reward type '%s'"):format(day, tostring(def.Type)))
	return nil
end

if #DAYS > DailyRewardConfig.UISlots then
	warn(("[DailyRewardConfig] %d rewards configured but the UI only has %d cards: days %d+ are ignored. Add cards to the UI and raise UISlots."):format(
		#DAYS, DailyRewardConfig.UISlots, DailyRewardConfig.UISlots + 1))
end

DailyRewardConfig.Rewards = {} :: { Reward }
for day = 1, math.min(#DAYS, DailyRewardConfig.UISlots) do
	local reward = resolve(day, DAYS[day])
	if not reward then
		-- Never leave a hole in the calendar: fall back to a small coin reward and shout about it above.
		reward = resolve(day, { Type = "Coins", Amount = 100 })
	end
	DailyRewardConfig.Rewards[day] = reward :: Reward
end

DailyRewardConfig.MaxDays = #DailyRewardConfig.Rewards

return DailyRewardConfig
