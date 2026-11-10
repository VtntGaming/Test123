--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local ForgeStates = require(script.Parent.ForgeStates)
local GhostItem = require(script.Parent.GhostItem)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local Signal = require(ReplicatedStorage.Utils.Signal)

--// References
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ForgeFrame = MainGui:WaitForChild("ForgeFrame")
local InventoryList = ForgeFrame.ScrollHolder.ScrollingFrame
local ItemTemplate = InventoryList.Template

--// Constants
local ACTIVATION_TIME = 0.25

--// Types
export type ItmeType = typeof(ItemTemplate)

export type ForgeItem = {
    __index: ForgeItem,
    --// API properties
    Frame: ItmeType,
    WeaponName: string,
    WeaponInfo: WeaponConfig.WeaponInfo,
    Connections: {[string]: RBXScriptConnection},
    --// Global properties
    UpdateInventoryCount: Signal.Signal<string, number>,
    QuickAssign: Signal.Signal<string>,
    --// Methods
    new: (weaponName: string) -> (ForgeItem),
    Destroy: (self: ForgeItem) -> (),
    SetQuantity: (self: ForgeItem, count: number) -> (),
    Start: (self: ForgeItem) -> (),
}

local ForgeItem = {} :: ForgeItem
ForgeItem.UpdateInventoryCount = Signal.new()
ForgeItem.QuickAssign = Signal.new()
ForgeItem.__index = ForgeItem

function ForgeItem.new(weaponName)
    local self = setmetatable({} :: any, ForgeItem) :: ForgeItem
    local frame = ItemTemplate:Clone()

    local weaponInfo = WeaponConfig.GetWeaponInfo(weaponName)
    frame.Name = weaponName
    frame.Parent = InventoryList

    local title = frame.Title
    title.Text = weaponInfo.DisplayName
    title.TextColor3 = weaponInfo.RarityColor
    title.Font = Enum.Font.LuckiestGuy

    local quantityLabel = frame.QuantityLabel
    quantityLabel.Font = Enum.Font.LuckiestGuy

    local icon = frame.Icon
    icon.Image = weaponInfo.Icon
    icon.ScaleType = Enum.ScaleType.Fit
    icon.ImageTransparency = 0

    frame.Visible = true
    frame.Parent = InventoryList
    self.Frame = frame
    self.WeaponInfo = weaponInfo
    self.WeaponName = weaponName
    self.Connections = {}

    self:Start()

    return self
end

function ForgeItem:Start()
    local frame = self.Frame
    local weaponName = self.WeaponName
    local lastHold = 0

    self.Connections.OnInputBegan = frame.InputBegan:Connect(function(input: InputObject)
        if ForgeStates.GhostItem then
            return
        end

        if ForgeStates.ThreeSlotStatus.IsAnimating then
            return
        end

        local isDragInput: boolean = input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        if not isDragInput or not ForgeFrame.Visible then
            return
        end

        if ForgeStates.InventoryCounts[weaponName] <= 0 then
            return
        end

        lastHold = time()

        ForgeStates.DragSource = nil

        local ghostItem = GhostItem.new(weaponName)
        ghostItem.Created:Connect(function()
            ForgeStates.GhostItem = ghostItem
        end)
        ghostItem.Released:Connect(function()
            if ForgeStates.GhostItem == ghostItem then
                ForgeStates.GhostItem = nil
            end
        end)
        ghostItem:CreateGhost(frame, input.Position, "Inventory")

        self.UpdateInventoryCount:Fire(weaponName, -1)
    end)

    self.Connections.OnInputEnded = frame.InputEnded:Connect(function(input: InputObject)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            if time() - lastHold < ACTIVATION_TIME then
                self.QuickAssign:Fire(self.WeaponName)
            end
        end
    end)
end

function ForgeItem:SetQuantity(quantity)
    local frame = self.Frame

    local quantityLabel = frame.QuantityLabel
    quantityLabel.Text = "X" .. quantity
end

function ForgeItem:Destroy()
    if not self.Frame then
        return
    end

    self.Frame:Destroy()

    for _, conn in pairs(self.Connections) do
        conn:Disconnect()
    end

    table.clear(self)
end

return ForgeItem