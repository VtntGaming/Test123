--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local GamepassContainer = ShopFrame.CanvasGroup.Listing.Passes
local Ref = GamepassContainer.VIP

--// Types
export type FrameType = typeof(Ref)

export type GamepassItem = {
    __index: GamepassItem,
    Category: string,
    Frame: FrameType,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    GamepassName: string,
    Start: (self: GamepassItem) -> (),
    SetVisible: (self: GamepassItem, visible: boolean, awaitTime: number?) -> (),
    new: (frame: any, gamepassName: string) -> GamepassItem,
}

local Item = {} :: GamepassItem
Item.__index = Item

function Item.new(frame, gamepassName)
    local self = setmetatable({}, Item) :: GamepassItem
    self.Category = "Passes"
    
    local background = frame.Spacer.Background.Background
    local movementTime = 20

    if gamepassName == "VIP" then
        movementTime = 30
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
        end,
    }

    self.GamepassName = gamepassName
    self.Frame = frame
    self.AnimationThreads = {}
    self.IsVisible = false

    return self
end

function Item:Start()
    
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