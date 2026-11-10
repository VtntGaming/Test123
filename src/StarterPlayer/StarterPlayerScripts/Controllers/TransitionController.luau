--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local TransitionGui = PlayerGui:WaitForChild("Transition")

--// Types
export type TransitionController = {
    Init: () -> (),
    CheckAttribute: () -> (),
}

--// Properties
local PreviousState = false
local TransitionThread: thread?

local Controller = {} :: TransitionController

function Controller.Init()
    LocalPlayer:GetAttributeChangedSignal("IsOnArena"):Connect(function()
        Controller.CheckAttribute()
    end)

    Controller.CheckAttribute()
end

function Controller.CheckAttribute()
    local isOnArena = LocalPlayer:GetAttribute("IsOnArena") == true

    if isOnArena and PreviousState ~= isOnArena then
        if TransitionThread then
            task.cancel(TransitionThread)
        end

        TransitionThread = TweenUtils.PlayTweenSequence({
            function()
                TransitionGui.Enabled = true
                TransitionGui.Dim.Visible = true
                TransitionGui.Top.Visible = false
                TransitionGui.Bottom.Visible = false
            end,
            TweenService:Create(TransitionGui.Top, TweenInfo.new(0), {Position = UDim2.fromScale(0.5, 0.5)}),
            TweenService:Create(TransitionGui.Bottom, TweenInfo.new(0), {Position = UDim2.fromScale(0.5, 0.5)}),
            TweenService:Create(TransitionGui.Dim, TweenInfo.new(0), {BackgroundTransparency = 1}),
            TweenService:Create(TransitionGui.Dim, TweenInfo.new(0.25), {BackgroundTransparency = 0}),
            function()
                TransitionGui.Dim.Visible = false   
                TransitionGui.Top.Visible = true
                TransitionGui.Bottom.Visible = true             
            end,
            true,
            TweenService:Create(TransitionGui.Top, TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {Position = UDim2.fromScale(0.5, 0)}),
            TweenService:Create(TransitionGui.Bottom, TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {Position = UDim2.fromScale(0.5, 1)}),
            function()
                TransitionGui.Enabled = false
            end
        })
    end

    PreviousState = isOnArena
end

return Controller