--!strict
-- Displays group reward feedback and keeps the claim button synchronized with saved claim state.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local GroupRewardsFrame = ShopFrame.CanvasGroup.Listing.SocialRewards.GroupRewards
local Background = GroupRewardsFrame.Spacer.Background.Background
local Remote = ReplicatedStorage.Events.ClaimGroupRewardEvent    

--// Constants
local TRIGGER_DEBOUNCE = 0.25

--// Types
export type GroupRewardsController = {
    Category: string,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    Frame: typeof(GroupRewardsFrame),
    LastTrigger: number,
    Started: boolean?,
    Setup: (self: GroupRewardsController) -> (),
    Start: (self: GroupRewardsController) -> (),
    SetVisible: (self: GroupRewardsController, visible: boolean, awaitTime: number?) -> ()
}

local Controller = {} :: GroupRewardsController

function Controller:Setup()
    self.Category = "SocialRewards"
    local itemIcon = GroupRewardsFrame.Spacer.Item
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
            local glow = GroupRewardsFrame.Spacer.Item.Glow
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
    self.LastTrigger = 0
    self.AnimationThreads = {}
    self.IsVisible = false
    self.Frame = GroupRewardsFrame
end

function Controller:Start()
    if self.Started then return end
    self.Started = true
    local claimButton = self.Frame.Spacer.BuyOptions.ClaimButton
    local originalText = claimButton.Price.Text
    local notified = false
    local function refresh()
		local claimed = PlayerData.Get(LocalPlayer, "GroupRewardClaimed") == true
		local enabled = PlayerData.Get(LocalPlayer, "DataLoaded") == true and not claimed
        claimButton.Price.Text = if claimed then "Claimed" else originalText
        claimButton.Active = enabled
        claimButton.Interactable = enabled
        claimButton.AutoButtonColor = enabled
    end
	PlayerData.Observe(LocalPlayer, "GroupRewardClaimed", refresh)
	PlayerData.Observe(LocalPlayer, "DataLoaded", refresh)
    refresh()

    Remote.OnClientEvent:Connect(function(result: unknown, amount: unknown)
        if result == "Claimed" then
            refresh()
            if notified then return end
            notified = true
            local message = if type(amount) == "number" then `Group reward claimed! Received {amount} Coins.` else "Group reward claimed!"
            NotificationUtil.Show("Success", message)
        elseif result == "NotInGroup" then
            NotificationUtil.Show("Warning", "Join the group to claim this reward.")
        end
    end)

    claimButton.Activated:Connect(function()
		if
			PlayerData.Get(LocalPlayer, "DataLoaded") ~= true
			or PlayerData.Get(LocalPlayer, "GroupRewardClaimed") == true
		then
			return
		end
        local now = os.clock()
        if now - self.LastTrigger < TRIGGER_DEBOUNCE then return end
        self.LastTrigger = now
        Remote:FireServer()
    end)
end

function Controller:SetVisible(visible, awaitTime)
    if visible then
        for _, cb in ipairs(self.AnimationCallbacks) do
            table.insert(self.AnimationThreads, task.spawn(cb, awaitTime))
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(GroupRewardsFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
            awaitTime or 0,
            TweenService:Create(GroupRewardsFrame.UIScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        for _, thread in ipairs(self.AnimationThreads) do
            task.cancel(thread)
        end

        table.clear(self.AnimationThreads)
    end
end

return Controller
