--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local PlayerCard = require(script.Parent.PlayerCard)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// Modules

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui  = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local ShowcaseFrame = ResultFrame.Holder.Showcase
local MatchScoreFrame = ShowcaseFrame.MatchScore
local MatchScoreContainer = MatchScoreFrame.Container
local MatchScoreHeader = MatchScoreContainer.Header
local SFXFolder = SoundService.SFX

export type PlayerScoreData = PlayerCard.PlayerScoreData

export type MatchScore = {
    OpenTweens: {TweenUtils.TweenType},
    CloseTweens: {TweenUtils.TweenType},
    PlayerCards: {PlayerCard.PlayerCard},
    Setup: (self: MatchScore) -> (),
    Start: (self: MatchScore) -> (),
    Reset: (self: MatchScore) -> (),
    SetVisible: (self: MatchScore, visible: boolean) -> (),
    BuildList: (self: MatchScore, list: {PlayerScoreData}) -> (),
}

local MatchScore = {} :: MatchScore

function MatchScore:Setup()
    self.OpenTweens = {
        function()
            MatchScoreFrame.Visible = true
            SoundService:PlayLocalSound(SFXFolder.Swoosh)
        end,
        TweenService:Create(MatchScoreHeader, TweenInfo.new(0), {Position = UDim2.fromScale(-0.5, 0)}),
        TweenService:Create(MatchScoreContainer, TweenInfo.new(0), {Position = UDim2.fromScale(1.5, 0.5)}),
        true,
        TweenService:Create(MatchScoreHeader, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0, 0)}),
        TweenService:Create(MatchScoreContainer, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.5, 0.5)}),
    }

    self.CloseTweens = {
        TweenService:Create(MatchScoreContainer, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Position = UDim2.fromScale(1.5, 0.5)}),
        function()
            MatchScoreFrame.Visible = false
        end,
    }

    self.PlayerCards = {}
end

function MatchScore:Start()
    self:SetVisible(false)
end

function MatchScore:SetVisible(visible)
    if visible then
        TweenUtils.PlayTweenSequence(self.OpenTweens)
        for _, card in ipairs(self.PlayerCards) do
            card:Appear()
        end
    else
        TweenUtils.PlayTweenSequence(self.CloseTweens)
    end
end

function MatchScore:Reset()
    for _, item in ipairs(self.PlayerCards) do
        item:Destroy()
    end

    table.clear(self.PlayerCards)
end

function MatchScore:BuildList(list)
    self:Reset()

    for placement, data in ipairs(list) do
        local card = PlayerCard.new(data, placement)

        self.PlayerCards[placement] = card
    end
end

return MatchScore