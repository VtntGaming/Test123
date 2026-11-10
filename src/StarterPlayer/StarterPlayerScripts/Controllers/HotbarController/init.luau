--!strict
-- Initializes the inventory and daily chest hotbar workflows.

--// Modules
local Inventory = require(script.Inventory)
local DailyChest = require(script.DailyChest)

--// Properties
local Initialized = false

--// Types
export type HotbarController = {
    Init: () -> (),
    Setup: (self: HotbarController) -> (),
    Start: (self: HotbarController) -> (),
    UpdateListing: () -> (),
    EquipItem: (itemName: string) -> (),
}

--// Controller
local HotbarController = {} :: HotbarController

--// APIs
function HotbarController:Setup()
    Inventory:Setup()
    DailyChest:Setup()
end

function HotbarController:Start()
    Inventory:Start()
    DailyChest:Start()
end

function HotbarController.Init()
    if Initialized then
        return
    end
    HotbarController:Setup()
    Initialized = true
    HotbarController:Start()
end

function HotbarController.UpdateListing()
    Inventory.UpdateListing()
end

function HotbarController.EquipItem(itemName)
    Inventory.EquipItem(itemName)
end

return HotbarController
