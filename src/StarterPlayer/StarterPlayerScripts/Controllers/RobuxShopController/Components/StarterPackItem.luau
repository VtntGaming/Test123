--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
--local StartPageService = game:GetService("StartPageService")
local TweenService = game:GetService("TweenService")

--// Modules
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local ChestConfig = require(ReplicatedStorage.SharedModules.ChestConfig)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local StarterPackFrame = ShopFrame.CanvasGroup.Listing.Exclusive.StarterPack
local Background = StarterPackFrame.Spacer.Background.Background
local ItemList = StarterPackFrame.Spacer.Items
local Template = ItemList.Template

--// Types
export type StarterPackItem = {
    Category: string,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    Frame: typeof(StarterPackFrame),
    Setup: (self: StarterPackItem) -> (),
    Start: (self: StarterPackItem) -> (),
    SetVisible: (self: StarterPackItem, visible: boolean, awaitTime: number?) -> ()
}

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

local Item = {} :: StarterPackItem

function Item:Setup()
    self.Category = "Exclusive"
    self.AnimationCallbacks = {
        function(awaitTime)
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(Background, TweenInfo.new(0), {Position = UDim2.fromScale(0, 0), AnchorPoint = Vector2.zero}),
                    TweenService:Create(Background, TweenInfo.new(30, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true), {Position = UDim2.fromScale(1,1), AnchorPoint = Vector2.one}),
                }, true)
            end
        end
    }

    local rewardList = RobuxShopConfig.StarterLegendaryPack.Rewards

    for order, reward in ipairs(rewardList) do
        local itemName = reward.Item
        local itemType = reward.Type
        local quantity = reward.Quantity
        local icon: string?

        local item = Template:Clone()
        item.LayoutOrder = order

        if itemType == "Weapon" then
            local weaponData = WeaponConfig.GetWeaponInfo(itemName)

            icon = weaponData and weaponData.Icon
        elseif itemType == "Chest" then
            local chestData = ChestConfig.GetChestInfo(itemName)

            icon = chestData and chestData.Thumbnail
        elseif itemType == "Ability" then
            local ability = AbilityConfig.Abilities[itemName]

            icon = ability and ability.Icon
        elseif itemType == "Coin" then
            icon = "rbxassetid://86241191871484"
        end

        item.Icon.Image = icon or ""

        if quantity and quantity > 0 then
            item.Quantity.Text = `<font size="10">x</font>{FormatNumber(quantity)}`
            item.Quantity.Visible = true
        end

        item.Visible = true
        item.Parent = ItemList
    end

    self.AnimationThreads = {}
    self.IsVisible = false
    self.Frame = StarterPackFrame
end

function Item:Start()
    
end

function Item:SetVisible(visible, awaitTime)
    if visible then
        for _, cb in ipairs(self.AnimationCallbacks) do
            table.insert(self.AnimationThreads, task.spawn(cb, awaitTime))
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(StarterPackFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
            awaitTime or 0,
            TweenService:Create(StarterPackFrame.UIScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        for _, thread in ipairs(self.AnimationThreads) do
            task.cancel(thread)
        end

        table.clear(self.AnimationThreads)
    end
end

return Item