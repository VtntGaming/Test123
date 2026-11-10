--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local CoinFrameContainer = ShopFrame.CanvasGroup.Listing.LuckyChests
local Ref = CoinFrameContainer.List1.Chest1

--// Types
export type FrameType = typeof(Ref)

export type LuckyChestItem = {
    __index: LuckyChestItem,
    Category: string,
    Frame: FrameType,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    SlotIndex: number,
    ChestName: string,
    Start: (self: LuckyChestItem) -> (),
    SetVisible: (self: LuckyChestItem, visible: boolean, awaitTime: number?) -> (),
    new: (frame: any, slotIndex: number, chestName: string) -> LuckyChestItem,
}

local Item = {} :: LuckyChestItem
Item.__index = Item

function Item.new(frame, slotIndex, chestName)
    local self = setmetatable({}, Item) :: LuckyChestItem
    self.Category = "LuckyChests"
    
    local background = frame.Spacer.Background.Background
    local movementTime = 40

    if slotIndex == 7 then
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
        end,
    }

    self.SlotIndex = slotIndex
    self.Frame = frame
    self.AnimationThreads = {}
    self.IsVisible = false
    self.ChestName = chestName

    return self
end

function Item:Start()
	local spacer = self.Frame:FindFirstChild("Spacer")
	if not spacer then return end

	local chestConfig = RobuxShopConfig.LuckyChestPacks[self.ChestName]
	if not chestConfig then
		warn(`No LuckyChestPacks entry for {self.ChestName}`)
		return
	end
	
	--IMAGE--
	local chestImage = spacer.Item:FindFirstChild("Icon") :: ImageLabel? -- use the real name
	if chestImage then
		chestImage.Image = chestConfig.Thumbnail
	else
		warn("No chest image found for chest item", self.Frame:GetFullName())
	end

	--NAME--
	local chestName = spacer.ItemName:FindFirstChild("ItemName") :: TextLabel
	local effectNameBase = spacer.ItemName:FindFirstChild("Effect"):FindFirstChild("Base"):FindFirstChild("Base") :: TextLabel
	local effectNameDown = spacer.ItemName:FindFirstChild("Effect"):FindFirstChild("Base"):FindFirstChild("Down") :: TextLabel
	if chestName and effectNameBase and effectNameDown then
		chestName.Text = chestConfig.Name or self.ChestName
		effectNameBase.Text = chestConfig.Name or self.ChestName
		effectNameDown.Text = chestConfig.Name or self.ChestName
	else
		warn("No chest name found for chest item", self.Frame:GetFullName())
	end
	
	--INFO--
	local chestInfo = spacer:FindFirstChild("Info") :: TextLabel
	if chestInfo then
		chestInfo.Text = `100% Chance {self.ChestName} Weapon`
	else
		warn("No chest info found for chest item", self.Frame:GetFullName())
	end
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