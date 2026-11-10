--!strict
--/ Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local Placement = ResultFrame.Holder.Showcase.PlayerRanking.Placement
local SFXFolder = SoundService.SFX

--// Constants
local PLACEMENT_FORMAT = {
    First = "ST",
    Second = "ND",
    Third = "RD",
    Default = "TH",
}

--// Types
export type PlayerPlacement = {
    ShowThread: thread?,
    Reset: (self: PlayerPlacement) -> (),
    Disappear: (self: PlayerPlacement) -> (),
    ShowPlacement: (self: PlayerPlacement, placement: number) -> (),
}

--// Controller
local PlayerPlacement = {} :: PlayerPlacement

function PlayerPlacement:Reset()
    TweenUtils.PlayTweenSequence({
        TweenService:Create(Placement.UIScale, TweenInfo.new(0), {Scale = 0})
    }, true)

    if self.ShowThread then
        task.cancel(self.ShowThread)
    end
end

function PlayerPlacement:Disappear()
    TweenUtils.PlayTweenSequence({
        TweenService:Create(Placement.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Scale = 0})
    })
end

function PlayerPlacement:ShowPlacement(placement)
    local suffix = PLACEMENT_FORMAT.Default

    local remains = placement % 10
    
    if remains <= 3 and placement // 10 ~= 10 then
        if remains == 1 then
            suffix = PLACEMENT_FORMAT.First
        elseif remains == 2 then
            suffix = PLACEMENT_FORMAT.Second
        else
            suffix = PLACEMENT_FORMAT.Third
        end
    end
    local placementDisplay = Placement.Placement
    local display = `{placement} <font size="8">{suffix}</font>`

    placementDisplay.Text = display

    local placementFillSCale = Placement.UIScale
    local placementTextScale = Placement.Placement.UIScale
    local placementTitle = Placement.Display

    if self.ShowThread then
        task.cancel(self.ShowThread)
    end

    self.ShowThread = TweenUtils.PlayTweenSequence({
        TweenService:Create(placementTextScale, TweenInfo.new(0), {Scale = 0}),
        TweenService:Create(placementTitle, TweenInfo.new(0), {Position = UDim2.fromScale(0.25, 0)}),
        1,
        true,
        TweenService:Create(placementFillSCale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
        true,
        TweenService:Create(placementTitle, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0, 0)}),
        0.05,
        TweenService:Create(placementTextScale, TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Scale = 1.5}),
        function()
            SoundService:PlayLocalSound(SFXFolder.Slam)
        end,
        TweenService:Create(placementTextScale, TweenInfo.new(0.15, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {Scale = 0.5}),
        true,
        TweenService:Create(placementTextScale, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Scale = 1}),
        TweenService:Create(placementFillSCale, TweenInfo.new(0), {Scale = 0.75}),
        TweenService:Create(placementFillSCale, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Scale = 1}),
    })
end

return PlayerPlacement