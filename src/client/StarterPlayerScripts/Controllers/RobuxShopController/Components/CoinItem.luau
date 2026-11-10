--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local CoinFrameContainer = ShopFrame.CanvasGroup.Listing.Coins.Items
local Ref = CoinFrameContainer.SpecialItem

--// Constants
-- local FIRST_TIME_ATTRIBUTE = "FirstTimeCoinPack"

--// Types
export type FrameType = typeof(Ref)

export type CoinItem = {
    __index: CoinItem,
    Category: string,
    Frame: FrameType,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    SlotIndex: number,
    PackName: string,
    Start: (self: CoinItem) -> (),
    SetVisible: (self: CoinItem, visible: boolean, awaitTime: number?) -> (),
    new: (frame: FrameType, slotIndex: number, packName: string) -> CoinItem,
}

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

-- local function IsFirstTime(packName: string): boolean
--     local data = tostring(LocalPlayer:GetAttribute(FIRST_TIME_ATTRIBUTE))
--     local split = string.split(data, ",")

--     if table.find(split, packName) then
--         return true
--     end

--     return false
-- end

local Item = {} :: CoinItem
Item.__index = Item

function Item.new(frame, slotIndex, packName)
    local self = setmetatable({} :: any, Item) :: CoinItem
    self.Category = "Coins"
    
    local background = frame.Spacer.Background.Background
    local movementTime = 40

    if slotIndex == 7 then
        movementTime = 50
    end

    local extendedCB

    local mostPopularFrame = frame.Spacer:FindFirstChild("MostPopular") :: GuiObject?

    if mostPopularFrame then
        local originPos = mostPopularFrame.Position
        local changes = UDim2.fromScale(0, 0.02)
        extendedCB = function()
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(mostPopularFrame, TweenInfo.new(0), {Position = originPos + changes}),
                    TweenService:Create(mostPopularFrame, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true), {Position = originPos - changes}),
                }, true)
            end
        end
    end

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
    }

    if extendedCB then
        table.insert(self.AnimationCallbacks, extendedCB)
    end

    local bonusValueDisplay = frame.Spacer.BonusValue

    local data = RobuxShopConfig.CoinPacks[packName]
    local coinValue = data and data.Value
    local originValue = data and data.OriginalValue or coinValue

    if coinValue then
        frame.Spacer.ItemName.Text = FormatNumber(originValue or coinValue)

        if originValue and originValue < coinValue then
            local bonusValue = coinValue - originValue

            bonusValueDisplay.Text = "+" .. FormatNumber(bonusValue)
            bonusValueDisplay.Visible = true
        end
    end

    self.SlotIndex = slotIndex
    self.Frame = frame
    self.AnimationThreads = {}
    self.IsVisible = false
    self.PackName = packName

    return self
end

function Item:Start()    
    -- local bonusFrame = self.Frame.Spacer.BonusValue

    -- LocalPlayer:GetAttributeChangedSignal(FIRST_TIME_ATTRIBUTE):Connect(function()
    --     bonusFrame.Visible = not IsFirstTime(self.PackName)
    -- end)

    -- bonusFrame.Visible = not IsFirstTime(self.PackName)
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