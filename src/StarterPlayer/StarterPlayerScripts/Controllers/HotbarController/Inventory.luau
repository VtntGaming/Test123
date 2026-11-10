--!strict
-- Owns the inventory button and the listing, shortcuts and equipping of chest stacks.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local HotbarItem = require(script.Parent.HotbarItem)
local InventoryController = require(script.Parent.Parent.InventoryController)
local ChestInventory = require(ReplicatedStorage.SharedModules.ChestInventory)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainUI = LocalPlayer.PlayerGui:WaitForChild("MainGui") :: ScreenGui & {
    HUD: Frame & {
        Hotbar: Frame & {
            Inventory: Frame & { Inventory: ImageButton, UIScale: UIScale },
        },
    },
}
local InventoryButton = MainUI.HUD.Hotbar.Inventory

--// Constants
local OWNED_CHEST_ATTRIBUTE = "OwnedChests"
local INVENTORY_KEYCODE = Enum.KeyCode.B

--// Properties
local Items: { [string]: HotbarItem.HotbarItem } = {}
local Started = false

--// Types
export type Inventory = {
    Setup: (self: Inventory) -> (),
    Start: (self: Inventory) -> (),
    UpdateListing: () -> (),
    EquipItem: (itemName: string) -> (),
}

--// Controller
local Inventory = {} :: Inventory

--// APIs
function Inventory:Setup()
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end

function Inventory:Start()
    if Started then
        return
    end
    Started = true
    do -- inventory button
        InventoryButton.Inventory.Activated:Connect(function()
            InventoryController.Toggle()
        end)

        local inventoryScale = InventoryButton.UIScale
        local lastHold: number? = nil

        UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if
                input.KeyCode == INVENTORY_KEYCODE
                and not gameProcessed
                and not UserInputService:GetFocusedTextBox()
            then
                TweenService:Create(
                    inventoryScale,
                    TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
                    { Scale = 0.85 }
                ):Play()
                lastHold = time()
            end
        end)

        UserInputService.InputEnded:Connect(function(input, gameProcessed)
            if input.KeyCode == INVENTORY_KEYCODE and lastHold then
                TweenService:Create(
                    inventoryScale,
                    TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
                    { Scale = 1 }
                ):Play()
                if not gameProcessed and not UserInputService:GetFocusedTextBox() and time() - lastHold <= 0.25 then
                    InventoryController.Toggle()
                end
                lastHold = nil
            end
        end)
    end
    HotbarItem.Activated:Connect(function(itemName: string)
        Inventory.EquipItem(itemName)
    end)

    LocalPlayer:GetAttributeChangedSignal(OWNED_CHEST_ATTRIBUTE):Connect(function()
        Inventory.UpdateListing()
    end)

    Inventory.UpdateListing()
end

function Inventory.UpdateListing()
    local listing = ChestInventory.Decode(LocalPlayer:GetAttribute(OWNED_CHEST_ATTRIBUTE))

    for itemName, item in pairs(Items) do
        local count = listing[itemName]

        if not count or count <= 0 then
            item:Destroy()
            Items[itemName] = nil
        end
    end

    for itemName, count in pairs(listing) do
        local item = Items[itemName] or HotbarItem.new(itemName)

        item:SetCount(count)
        if not Items[itemName] then
            Items[itemName] = item
        end
    end

    local arrayItem = {}

    for _, item in pairs(Items) do
        table.insert(arrayItem, item)
    end

    table.sort(arrayItem, function(item1, item2)
        return item1.Frame.LayoutOrder < item2.Frame.LayoutOrder
    end)

    for order, item in ipairs(arrayItem) do
        item:SetKeybind(order)
    end
end

function Inventory.EquipItem(itemName)
    local char = LocalPlayer.Character
    if not char then
        return
    end
    local hum = char:FindFirstChildWhichIsA("Humanoid")

    if hum then
        local existing = nil
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("ChestName") == itemName then
                existing = tool
                break
            end
        end

        if existing then
            hum:UnequipTools()
        else
            local item = Items[itemName]
            local tool = item and item:GetTool()

            if tool then
                hum:EquipTool(tool)
            end
        end
    end
end

return Inventory
