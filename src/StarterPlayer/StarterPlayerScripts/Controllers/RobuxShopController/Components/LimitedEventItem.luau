--!strict
--// Services
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
local LimitedItemFrame = ShopFrame.CanvasGroup.Listing.Exclusive.LimitedItem
local Background = LimitedItemFrame.Spacer.Background.Background

--// Constants
local TIME_END_ATTRIBUTE = "LimitedItemEndsAt"

--// Types
export type LimitedEventItem = {
    Category: string,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    Frame: typeof(LimitedItemFrame),
    Setup: (self: LimitedEventItem) -> (),
    Start: (self: LimitedEventItem) -> (),
    SetVisible: (self: LimitedEventItem, visible: boolean, awaitTime: number?) -> (),
    SetItem: (self: LimitedEventItem, itemName: string) -> (),
}

local function FormatTime(t: number): string
	local seconds = t % 60
	local minutes = math.floor(t / 60) % 60
	local hours = math.floor(t / 3600) % 24

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, seconds)
	else
		return string.format("%d:%02d", minutes, seconds)
	end
end

local Item = {} :: LimitedEventItem

function Item:Setup()
    self.Category = "Exclusive"
    local itemIcon = LimitedItemFrame.Spacer.Item
    local originPos = itemIcon.Position
    self.AnimationCallbacks = {
        function()
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(Background, TweenInfo.new(0), {Position = UDim2.fromScale(0, 0), AnchorPoint = Vector2.zero}),
                    TweenService:Create(Background, TweenInfo.new(30, Enum.EasingStyle.Linear), {Position = UDim2.fromScale(1,1), AnchorPoint = Vector2.one}),
                }, true)
            end
        end,
        function()
            local glow = LimitedItemFrame.Spacer.Item.Glow
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
        end,
    }

    self.Frame = LimitedItemFrame
    self.AnimationThreads = {}
    self.IsVisible = false
end

function Item:Start()
    task.spawn(function()
        while task.wait(1) do
            local endTime = tonumber(ReplicatedStorage:GetAttribute(TIME_END_ATTRIBUTE)) or 0

            local timeLeft = 0
            if endTime ~= 0 then
                timeLeft = math.min(endTime - os.time())
            end

            self.Frame.Spacer.Timer.Text = FormatTime(timeLeft)
        end
    end)
end

function Item:SetItem(itemName)
    local data = WeaponConfig.GetWeaponInfo(itemName)

    if not data then
        return
    end

    local displayName = data.DisplayName
    local icon = data.Icon
    local frame = self.Frame
    local nameFrame = frame.Spacer.ItemName
    local imageIcon = frame.Spacer.Item.Icon
    
    nameFrame.ItemName.Text = displayName
    nameFrame.Effect.Base.Base.Text = displayName
    nameFrame.Effect.Base.Down.Text = displayName
    imageIcon.Image = icon
end

function Item:SetVisible(visible, awaitTime)
    if visible then
        for _, cb in ipairs(self.AnimationCallbacks) do
            table.insert(self.AnimationThreads, task.spawn(cb, awaitTime))
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(LimitedItemFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
            awaitTime or 0,
            TweenService:Create(LimitedItemFrame.UIScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        for _, thread in ipairs(self.AnimationThreads) do
            task.cancel(thread)
        end

        table.clear(self.AnimationThreads)
    end
end

return Item