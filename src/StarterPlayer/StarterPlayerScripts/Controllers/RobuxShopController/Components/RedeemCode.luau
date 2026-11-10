--!strict
-- Redeems promo codes and displays server-confirmed rewards alongside existing error feedback.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local RedeemCodeFrame = ShopFrame.CanvasGroup.Listing.SocialRewards.RedeemCode
local Spacer = RedeemCodeFrame.Spacer
local Background = RedeemCodeFrame.Spacer.Background.Background
local CodeInput = Spacer.CodeInput
local Remote = ReplicatedStorage.Events.RedeemCodeFunction
local InvalidSound = SoundService.SFX.invalid
local BlockedSound = SoundService.SFX.Blocked
local SuccessSound = SoundService.SFX.Success

--// Types
export type CodeRedeemController = {
    Category: string,
    AnimationCallbacks: {(awaitTime: number?) -> ()},
    AnimationThreads: {thread},
    IsVisible: boolean,
    OnRedeem: boolean,
    Frame: typeof(RedeemCodeFrame),
    Setup: (self: CodeRedeemController) -> (),
    Start: (self: CodeRedeemController) -> (),
    SetVisible: (self: CodeRedeemController, visible: boolean, awaitTime: number?) -> (),
    RedeemCode: (self: CodeRedeemController, codeToRedeem: string) -> (),
}

local Controller = {} :: CodeRedeemController

function Controller:Setup()
    self.Category = "SocialRewards"
    self.AnimationCallbacks = {
        function()
            while task.wait() do
                TweenUtils.PlayTweenSequence({
                    TweenService:Create(Background, TweenInfo.new(0), {Position = UDim2.fromScale(0, 0), AnchorPoint = Vector2.zero}),
                    TweenService:Create(Background, TweenInfo.new(30, Enum.EasingStyle.Linear), {Position = UDim2.fromScale(1,1), AnchorPoint = Vector2.one}),
                }, true)
            end
        end
    }

    self.OnRedeem = false
    self.AnimationThreads = {}
    self.IsVisible = false
    self.Frame = RedeemCodeFrame
end

function Controller:Start()
    local redeemButton = self.Frame.Spacer.BuyOptions.ClaimButton
    local input = CodeInput.Code

    redeemButton.Activated:Connect(function()
        local code = input.Text
        if code == "" then
            return
        end

        input.Text = ""

        self:RedeemCode(code)
    end)
end

function Controller:RedeemCode(codeToRedeem)
    if self.OnRedeem then
        return
    end

    self.OnRedeem = true
    pcall(function()
        local success, message, rewardMessage = Remote:InvokeServer(codeToRedeem)

        if not success then
            SoundService:PlayLocalSound(InvalidSound)
            SoundService:PlayLocalSound(BlockedSound)
            local tweens = {}
            local messageCanvas = CodeInput.Message
            local messageLabel = messageCanvas.Message

            messageLabel.Text = string.upper(message)

            TweenUtils.PlayTweenSequence({
                function()
                    messageCanvas.Visible = true
                end,
                TweenService:Create(messageCanvas, TweenInfo.new(0), {GroupTransparency = 0}),
                1,
                TweenService:Create(messageCanvas, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {GroupTransparency = 1}),
                function()
                    messageCanvas.Visible = false
                end,
            })

            local count = 10
            local size = 0.02
            local animTime = 0.25

            for i = 10 - 1, 0, -1 do
                local intensity = size * (i / count)
                local pos = 0.5 + intensity * math.sign((i % 2) - 0.5)

                table.insert(tweens, 
                    TweenService:Create(Spacer, TweenInfo.new(animTime / count, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
                        Position = UDim2.fromScale(pos, 0.5)
                    })
                )
            end

            TweenUtils.PlayTweenSequence(tweens)
        else
            SoundService:PlayLocalSound(SuccessSound)
            local feedback = if type(rewardMessage) == "string" then rewardMessage
                elseif type(message) == "string" then message else "Code redeemed!"
            -- Notifications use RichText; item names must stay literal text.
            feedback = feedback:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            NotificationUtil.Show("Success", feedback)
        end
    end)
    self.OnRedeem = false
end

function Controller:SetVisible(visible, awaitTime)
    if visible then
        for _, cb in ipairs(self.AnimationCallbacks) do
            table.insert(self.AnimationThreads, task.spawn(cb, awaitTime))
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(RedeemCodeFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
            awaitTime or 0,
            TweenService:Create(RedeemCodeFrame.UIScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        for _, thread in ipairs(self.AnimationThreads) do
            task.cancel(thread)
        end

        table.clear(self.AnimationThreads)
    end
end

return Controller
