-- Configures Robux products, rotating offers, reward values, and the server checkout strategy.
local ChestConfig = require(script.Parent.ChestConfig)
local WeaponConfig = require(script.Parent.WeaponConfig)
local AbilityConfig = require(script.Parent.AbilityConfig)

local Config = {}

export type CheckoutMode = "Simple" | "Fast" | "Durable"

-- Simple: runtime selections and attribute-based online rewards; no checkout storage before prompting.
-- Receipt compatibility lookups and disconnected-recipient gift persistence are storage exceptions.
-- Fast: existing prompt-first checkout, background persistence, reservations and durable recovery.
-- Durable: existing save-and-reserve-before-prompt checkout and durable receipt recovery.
Config.CheckoutMode = "Simple" :: CheckoutMode

export type Reward = {
    Type: string,
    Item: string?,
    Quantity: number?,
}

export type CoinItem = {
    ID: number,
    Order: number,
    Value: number,
    OriginalValue: number,
}

--#region  --old
Config.FirstTimeBonus = {
	CoinPack = 0.25
}
Config.Special = {
	HasX2Coins = 3717395826,
    TimeStop = 3718766269,
}
--#endregion

-- Designer estimates in Robux, not actual standalone sale prices.
-- 25 coins/Robux matches the Wooden, Silver and Gold chest prices.
Config.WorthEstimates = {
    CoinsPerRobux = 25,
    WeaponByRarity = { Common = 9, Rare = 49, Epic = 99, Legendary = 249, Mythic = 499 },
    Ability = { Smash = 99 },
}
-- Full bundle value before discounts, independent of a player's existing items.
function Config.CalculateWorth(rewards: {Reward}): number
    -- local worth = 0
    -- for _, reward in ipairs(rewards) do
    --     local quantity = reward.Quantity
    --     if reward.Type ~= "Ability" then
    --         assert(type(quantity) == "number" and quantity > 0 and quantity < math.huge and quantity % 1 == 0,
    --             "Pack reward quantity must be a positive integer")
    --     end

    --     if reward.Type == "Weapon" then
    --         assert(type(reward.Item) == "string", "Pack weapon name is required")
    --         local info = WeaponConfig.GetWeaponInfo(reward.Item)
    --         assert(info and (info.Variant == "None"
    --             or table.find(WeaponConfig.RarityVariants[info.Rarity], info.Variant)),
    --             "Unknown pack weapon: " .. reward.Item)
    --         worth += assert(Config.WorthEstimates.WeaponByRarity[info.Rarity], "Missing weapon worth") * quantity
    --     elseif reward.Type == "Ability" then
    --         assert(type(reward.Item) == "string" and AbilityConfig.Abilities[reward.Item], "Unknown pack ability")
    --         worth += Config.WorthEstimates.Ability[reward.Item]
    --     elseif reward.Type == "Chest" then
    --         assert(type(reward.Item) == "string" and ChestConfig.Chests[reward.Item], "Unknown pack chest")
    --         worth += ChestConfig.Chests[reward.Item].CostInRobux * quantity
    --     elseif reward.Type == "Coin" then
    --         worth += quantity / Config.WorthEstimates.CoinsPerRobux
    --     else
    --         error("Unknown pack reward type: " .. tostring(reward.Type))
    --     end
    -- end
    -- return math.round(worth)
end

Config.LimitedItem = {
    -- Each weapon needs its own developer product ID. Keep IDs bound to the
    -- same weapon so late receipts never award a different rotation's item.
    -- 0 disables purchases for that entry, while still publishing the schedule.
    -- The same ID is used for self purchases and gifts; checkout snapshots fix the recipient.
    Seed = 20261020,
    Version = 1, -- Increment only when intentionally replacing the live schedule.
    -- Repeats every #List rotations. Each weapon appears exactly once per cycle.
    -- Set positions to weapon names; omitted positions or false use seeded random
    -- choices from the remaining weapons. An empty table keeps the random schedule.
    RotationOrder = {
        -- [1] = "HammerKing",
        -- [2] = false,
        -- [3] = "HammerDemon",
    },
    List = {
        {
            ID = 3720601459, -- 799 Robux
            Item = "HammerKaido",
            Image = "",
        },
        -- {
        --     ID = 3720601846,
        --     Item = "HammerKaido",
        --     Image = "",
        -- },
        -- {
        --     ID = 3720601921,
        --     Item = "HammerKaido",
        --     Image = "",
        -- },
        -- {
        --     ID = 3720601998,
        --     Item = "HammerKaido",
        --     Image = "",
        -- },
    },
    -- Keep List, RotationOrder, Seed, StartAt and Duration stable within a Version.
    Duration = 60*60*24*7, -- 3 days, synchronized across all servers.
    StartAt = DateTime.fromUniversalTime(2026,10,25,12).UnixTimestamp
}
Config.StarterLegendaryPack = {
    ID = 3720601234, -- 97 Robux
    Worth = 0, -- Calculated below from Rewards.
    Rewards = {
        {
            Item = "ChickenFire",
            Type = "Weapon",
            Quantity  = 1
        },
        {
            Item = "Shrink",
            Type = "Ability",
        },
        {
            Item = "Gold",
            Type = "Chest",
            Quantity  = 3
        },
        {
            Type = "Coin",
            Quantity  = 3000
        },
    } 
}
Config.StarterLegendaryPack.Worth = 1000 --Config.CalculateWorth(Config.StarterLegendaryPack.Rewards)
Config.Passes = {
    -- Roblox gamepass IDs (not developer products). 0 disables ownership checks/prompts.
    -- GiftID is a developer product (0 disables gifting); ID remains the Roblox gamepass.
    -- Attribute reflects Roblox ownership OR the persistent Owned_Pass_<name> gift entitlement.
    VIP = {
        ID = 2044298550, -- 349 Robux
        GiftID = 3721093889,
        Attribute = "HasVIP",
        Image = "",
        Benefits = {
            CoinMultiplier = 1.5,
            UniqueNametag = true,
            ExtraLives = 0
        }
    },
    InstantChest = {
        ID = 2045150556, -- 79 Robux
        GiftID = 3721094176,
        Attribute = "HasInstantChest",
        Image = "",
	},
	x2Coins = {
		ID = 2022998364, -- 249 Robux
		GiftID = 3717395826,
		Attribute = "Has2xCoins",
		Image = ""
	}
}

-- LUCKY CHESTS --

export type LuckyChestPack = { ID: number, Thumbnail: string, Name: string?, ModelName: string?, Price: number? }

Config.LuckyChestPacks = {
    -- One unopened chest per purchase; opening rolls uniformly from BaseWeapons + this variant.
    -- Example: Rainbow can roll BatRainbow, ChickenRainbow, HammerRainbow, etc.
    -- ID = 0 disables registration until a real developer product ID is assigned.
    -- Optional ModelName and Thumbnail override presentation; missing visuals use Wooden.
	Fire = {
		ID = 3720602853, -- 99 Robux
		Thumbnail = "rbxassetid://76398618402432",
		Name= "Fire",
		ModelName = "Fire",
		Color = Color3.fromRGB(255, 7, 0),
	},
	Lightning = {
		ID = 3720602935, -- 99 Robux
		Thumbnail = "rbxassetid://111881333213647",
		Name= "Lightning",
		ModelName = "Lightning",
	},
    Ice = {
		ID = 3720603039, -- 99 Robux
		Thumbnail = "rbxassetid://135536484065068",
		Name= "Ice",
		ModelName = "Ice",
	},
	Rainbow = {
		ID = 3720603119, -- 499 Robux
		Thumbnail = "rbxassetid://126336783453619",
		Name= "Rainbow",
		ModelName = "Rainbow",
	},
} :: { [string]: LuckyChestPack }


-- WEAPONS --

export type WeaponPack = {
    ID: number, -- -1 = free claim; 0 = disabled placeholder; >0 = developer product.
    Variant: {string}, -- Pick one variant, then one base weapon, per rotation.
    Quantity: {number}, -- Pick the displayed bundle size; free claims, paid purchases and gifts grant all copies.
    OriginalPrice: number?, -- Display only; Roblox determines the actual product price.
}
Config.WeaponPacks = { -- Extra copies are usefull for fusion to get new item of same rarity
    List = 
    {
        {
            ID = -1, --FREE
            Variant = WeaponConfig.RarityVariants.Common,
			Quantity = {1,3},
        },
        {
            ID = 3720600516, -- 99 Robux
            Variant = WeaponConfig.RarityVariants.Rare,
            Quantity = {2,5},
        },
        {
			ID = 3720600589, -- 199 Robux
            Variant = WeaponConfig.RarityVariants.Epic,
            Quantity = {2,5},
        },
        {
            ID = 3720600644, -- 299 Robux
            Variant = WeaponConfig.RarityVariants.Legendary,
            Quantity = {2,5},
        },
        {
            ID = 3720600766, -- 499 Robux,
            Variant = WeaponConfig.RarityVariants.Mythic,
            Quantity = {5,10,15},
            OriginalPrice = 1000,
        }
    } :: {WeaponPack},
    Seed = 25467479,
    -- Keep List order, variants, quantities, base weapon names, Seed, StartAt and Duration
    -- identical across servers. Positive IDs must be unique to this section.
    -- Managed checkout snapshots the offered weapon before prompting; late receipts keep that reward.
    Duration = 60*60*24, -- 1 day, synchronized across all servers.
    StartAt = DateTime.fromUniversalTime(2026,10,20,12).UnixTimestamp
} 

Config.CoinPacks = {
    ["1_000"] = {
        ID = 3719946812, -- 39 Robux
        Order = 1,
        Value = 1_000,
        OriginalValue = 1_000,
    },
    ["5_000"] = {
        ID = 3719946908, -- 179 Robux
        Order = 2,
        Value = 5_000,
        OriginalValue = 5_000,
    },
    ["10_000"] = {
		ID = 3719947099, -- 349 Robux
        Order = 3,
        Value = 10_000,
        OriginalValue = 10_000,
    },
    ["25_000"] = {
        ID = 3719947411, -- 799 Robux
        Order = 4,
        Value = 25_000,
        OriginalValue = 25_000,
    },
    ["50_000"] = {
        ID = 3720599089, -- 1499 Robux
        Order = 5,
        Value = 50_000,
        OriginalValue = 50_000,
    },
    ["100_000"] = {
        ID = 3720599263, -- 2799 Robux
        Order = 6,
        Value = 100_000,
        OriginalValue = 100_000,
    },
    ["500_000"] = {
        ID = 3719947935, -- 4999 Robux
        Order = 7,
        Value = 500_000,
        OriginalValue = 500_000,
	},
} :: {[string]: CoinItem}

Config.DailyRewards = {
    SkipDailyProductId = 3722877814
}

return Config
