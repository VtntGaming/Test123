--!strict
-- Defines the daily win requirement and the daily chest's rarity weights and appearance.

--// Modules
local ChestConfig = require(script.Parent.ChestConfig)

--// Types
export type DailyChestConfig = {
    WinsRequired: number,
    ChestType: string,
    Rates: ChestConfig.ChestRates,
    DisplayName: string,
    Order: number,
    ModelName: string,
    Thumbnail: string,
    Color: Color3,
}

--// Config
local DailyChestConfig: DailyChestConfig = {
    WinsRequired = 3,
    ChestType = "DailyChest",
    Rates = { Common = 30, Rare = 35, Epic = 30, Legendary = 5, Mythic = 0 },
    DisplayName = "Daily Chest",
    Order = 7,
    ModelName = "DailyChest",
    Thumbnail = "rbxassetid://75734689086296", -- Empty uses the Wooden thumbnail until a daily chest icon is assigned.
    Color = Color3.fromRGB(255, 251, 0),
}

return table.freeze(DailyChestConfig)
