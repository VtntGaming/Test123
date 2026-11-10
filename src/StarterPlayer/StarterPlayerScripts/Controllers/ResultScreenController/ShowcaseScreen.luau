--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local MatchScore = require(script.Parent.MatchScore)
local PlayerPlacement = require(script.Parent.PlayerPlacement)
local ResultScene = require(script.Parent.ResultScene)
local SummaryScreen = require(script.Parent.SummaryScreen)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui  = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local ShowcaseFrame = ResultFrame.Holder.Showcase
local ContinueButton = ShowcaseFrame.Continue

--// Constants
local APPEAR_AWAIT = 1.5

--// Types
export type PlayerScoreData = MatchScore.PlayerScoreData

export type ShowcaseConfig = {
    Placement: number,
    OldRating: number,
    NewRating: number,
    IsUnranked: boolean?,
    Listing: {PlayerScoreData},
}

export type ShowcaseScreen = {
    IsVisible: boolean,
    ShowcaseThread: thread?,
    AppearThread: thread?,
    OldRating: number,
    NewRating: number,
    IsUnranked: boolean,
    Setup: (self: ShowcaseScreen) -> (),
    Start: (self: ShowcaseScreen) -> (),
    SetVisible: (self: ShowcaseScreen, visible: boolean) -> (),
    ShowShowcase: (self: ShowcaseScreen, config: ShowcaseConfig) -> (),
}

local ShowcaseScreen = {} :: ShowcaseScreen

function ShowcaseScreen:Setup()
    self.IsVisible = false
    MatchScore:Setup()
    self.OldRating = 0
    self.NewRating = 0
    self.IsUnranked = false
end

function ShowcaseScreen:Start()
    ContinueButton.Activated:Connect(function()
        if self.IsVisible then
            self:SetVisible(false)
            SummaryScreen:ShowSummary(self.OldRating, self.NewRating, self.IsUnranked)
        end
    end)
    
    MatchScore:Start()
end

function ShowcaseScreen:SetVisible(visible)
    self.IsVisible = visible

    if self.ShowcaseThread then
        task.cancel(self.ShowcaseThread)
    end

    if self.AppearThread then
        task.cancel(self.AppearThread)
    end

    if visible then
        ResultScene:SetSceneCameraEnabled(false)
        SummaryScreen:SetVisible(false) -- Force this to disable first
        ShowcaseFrame.Visible = true       

        self.AppearThread = TweenUtils.PlayTweenSequence({
            TweenService:Create(ResultFrame, TweenInfo.new(0.25, Enum.EasingStyle.Linear), {BackgroundTransparency = 0}),
            function()
                ResultScene:SetSceneCameraEnabled(true)
            end,
            TweenService:Create(ResultFrame, TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {BackgroundTransparency = 1}),
            APPEAR_AWAIT,
            function()
                MatchScore:SetVisible(true)
            end
        })   
    else
        MatchScore:SetVisible(false)
        task.delay(0.05, function()
            PlayerPlacement:Disappear()
            task.wait(0.05)
            TweenService:Create(ContinueButton, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Position = UDim2.fromScale(0.75, 1.1)}):Play()
        end)
        task.wait(0.35)
        ShowcaseFrame.Visible = false
    end
end

function ShowcaseScreen:ShowShowcase(config)
    self.OldRating = config.OldRating
    self.NewRating = config.NewRating
    self.IsUnranked = config.IsUnranked == true
    MatchScore:BuildList(config.Listing)
    self:SetVisible(true)
    PlayerPlacement:Reset()
    self.ShowcaseThread = TweenUtils.PlayTweenSequence({
        function()
            ContinueButton.Visible = false
            ShowcaseFrame.MatchScore.Visible = false    -- Forst this to invisible first
        end,
        TweenService:Create(ContinueButton, TweenInfo.new(0), {Position = UDim2.fromScale(0.75, 1.1)}),
        1.5 + APPEAR_AWAIT,
        function()
            PlayerPlacement:ShowPlacement(config.Placement)            
        end,
        1.5,
        function()
            ContinueButton.Visible = true
        end,
        TweenService:Create(ContinueButton, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.75, 0.9)}),
    })
end

return ShowcaseScreen