--!strict
--// Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local WeaponFrameContainer = ShopFrame.CanvasGroup.Listing.Weapons.Items
local Ref = WeaponFrameContainer.SpecialItem

--// Constants
local WEAPON_PACK_ATTRIBUTE = "WeaponPacks"

--// Types
type WeaponPacks = {
    Offers: {SlotData}
}

type SlotData = {
    Quantity: number,
    Weapon: string
}

export type FrameType = typeof(Ref)

export type WeaponItem = {
    __index: WeaponItem,
    Category: string,
    Frame: FrameType,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    SlotIndex: number,
    new: (frame: any, slotIndex: number) -> WeaponItem,
    Start: (self: WeaponItem) -> (),
    SetVisible: (self: WeaponItem, visible: boolean, awaitTime: number?) -> (),
    UpdateData: (self: WeaponItem) -> (),
}

local Item = {} :: WeaponItem
Item.__index = Item

function Item.new(frame, slotIndex)
    local self = setmetatable({}, Item) :: WeaponItem
    self.Category = "Weapons"
    
    local background = frame.Spacer.Background.Background
    local movementTime = 40

    if slotIndex == 5 then
        movementTime = 50
    end
    local itemIcon = frame.Spacer.Item
    local originPos = itemIcon.Position

    self.AnimationCallbacks = {
        function()
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(background, TweenInfo.new(0), {Position = UDim2.fromScale(0, 0), AnchorPoint = Vector2.zero}),
                    TweenService:Create(background, TweenInfo.new(movementTime, Enum.EasingStyle.Linear), {Position = UDim2.fromScale(1,1), AnchorPoint = Vector2.one}),
                }, true)
            end
        end,
        function()
            local glow = self.Frame.Spacer.Item.Glow
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(glow, TweenInfo.new(0), {Rotation = 0}),
                    TweenService:Create(glow, TweenInfo.new(30, Enum.EasingStyle.Linear), {Rotation = 360}),
                }, true)
            end
        end,
        function()
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(itemIcon, TweenInfo.new(0), {Position = originPos - UDim2.fromScale(0, 0.02)}),
                    TweenService:Create(itemIcon, TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true), {Position = originPos + UDim2.fromScale(0, 0.02)})
                }, true)
            end
        end
    }

    self.SlotIndex = slotIndex
    self.Frame = frame
    self.AnimationThreads = {}
    self.IsVisible = false

    return self
end

function Item:Start()
    ReplicatedStorage:GetAttributeChangedSignal(WEAPON_PACK_ATTRIBUTE):Connect(function()
        self:UpdateData()
    end)

    self:UpdateData()
end

function Item:UpdateData()
    local data: WeaponPacks?
    pcall(function()
        data = HttpService:JSONDecode(ReplicatedStorage:GetAttribute(WEAPON_PACK_ATTRIBUTE))        
    end)

    local offers = data and data.Offers
    local indexData = offers and offers[self.SlotIndex]

    if not indexData then
        return
    end

    local quantity = indexData.Quantity
    local weaponName = indexData.Weapon

    local weaponData = WeaponConfig.GetWeaponInfo(weaponName)

    if not weaponData then
        return
    end

    local rarity = weaponData.Rarity
    local rarityColor = weaponData.RarityColor
    local displayName = weaponData.DisplayName
    local icon = weaponData.Icon

    local spacier = self.Frame.Spacer
    local itemNameDisplay = spacier.ItemName
    local quantityDisplay = spacier.Quantity
    local rarityDisplay = spacier.Rarity
    local iconDisplay = spacier.Item.Icon

    itemNameDisplay.Text = displayName
    quantityDisplay.Text = `<font size="10">x</font>{quantity}`
    rarityDisplay.Text = rarity
    rarityDisplay.TextColor3 = rarityColor
    iconDisplay.Image = icon
end

function Item:SetVisible(visible, awaitTime)
    if visible then
        local frameScale = self.Frame.UIScale
        for _, cb in ipairs(self.AnimationCallbacks) do
            table.insert(self.AnimationThreads, task.spawn(cb, awaitTime))
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(frameScale, TweenInfo.new(0), {Scale = 0}),
            awaitTime or 0,
            TweenService:Create(frameScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        for _, thread in ipairs(self.AnimationThreads) do
            task.cancel(thread)
        end

        table.clear(self.AnimationThreads)
    end
end

return Item