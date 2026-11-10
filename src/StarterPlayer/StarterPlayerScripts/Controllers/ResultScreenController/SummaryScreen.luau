--!strict
--// Services
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local LeagueConfig = require(ReplicatedStorage.SharedModules.LeagueConfig)
local LeagueUtil = require(ReplicatedStorage.Utils.LeagueUtil)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local ResultScene = require(script.Parent.ResultScene)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local DimFrame = ResultFrame.Dim
local FlashFrame = ResultFrame.Flash
local SummaryFrame = ResultFrame.Holder.RankSummary
local Header = SummaryFrame.Header
local ContinueButton = SummaryFrame.Continue
local RankingFrame = SummaryFrame.Ranking
local Progression  = RankingFrame.Progression
local ChangeFrame = Progression.Changes
local SFXFolder = SoundService.SFX

--// Constants
local RATING_ANIMATE_TIME = 1

--// Types
export type SummaryScreen = {
	IsVisible: boolean,
    SummaryThread: thread?,
	Setup: (self: SummaryScreen) -> (),
	Start: (self: SummaryScreen) -> (),
	SetVisible: (self: SummaryScreen, visible: boolean) -> (),
	ShowSummary: (self: SummaryScreen, oldRating: number, newRating: number, isUnranked: boolean?) -> (),
}

local SummaryScreen = {} :: SummaryScreen

function SummaryScreen:Setup()
	self.IsVisible = false
	SummaryFrame.Visible = false

    local listing = {}

    for _, league in ipairs(LeagueConfig.Leagues) do
        local id = league.Icon

        local item = Instance.new("ImageLabel")
        item.Image = id
        table.insert(listing, item)
    end

    ContentProvider:PreloadAsync(listing)
    for _, item in ipairs(listing) do
        item:Destroy()
    end
    table.clear(listing)
end

function SummaryScreen:Start()
    ContinueButton.Activated:Connect(function()
        if self.IsVisible then
            self:SetVisible(false)
        end
    end)
	self:SetVisible(false)
end

function SummaryScreen:SetVisible(visible)
	self.IsVisible = visible
	SummaryFrame.Visible = visible

    if visible then
        ResultScene:SwitchToSummary()
        TweenUtils.PlayTweenSequence({
            TweenService:Create(DimFrame, TweenInfo.new(0), {BackgroundTransparency = 1}),
            TweenService:Create(RankingFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
            TweenService:Create(Header, TweenInfo.new(0), {Position = UDim2.fromScale(-0.5, 0)}),
            function()          
                SoundService:PlayLocalSound(SFXFolder.Swoosh)
            end,
            true,
            TweenService:Create(DimFrame, TweenInfo.new(1, Enum.EasingStyle.Linear), {BackgroundTransparency = 0.5}),
            true,
            TweenService:Create(Header, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.1, 0)}),
            0.5,
            TweenService:Create(RankingFrame.UIScale, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Scale = 1}),
        })
    else
        if self.SummaryThread then
            task.cancel(self.SummaryThread)
        end
        TweenUtils.PlayTweenSequence({
            TweenService:Create(DimFrame, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {BackgroundTransparency = 1}),
        })
    end
end

function SummaryScreen:ShowSummary(oldRating, newRating, isUnranked)
	self:SetVisible(true)

    if self.SummaryThread then
        task.cancel(self.SummaryThread)
    end

    local currentIcon = RankingFrame.CurrentRank
    local newIcon = RankingFrame.NewRank
    local leagueNameDisplay = RankingFrame.LeagueName

    newIcon.Visible = false

    self.SummaryThread = task.spawn(function()
        local changeScale = ChangeFrame.UIScale
        local ratingChanges = newRating - oldRating
        local baseAwait = 1
        
        local currentGamesPlayed = tonumber(Players.LocalPlayer:GetAttribute("GamesPlayed")) or 0
        local previousGamesPlayed = math.max(0, currentGamesPlayed - 1)
        local gamePlayedRequirement = LeagueConfig.GamesPlayedRequirement
        local previousRatio = previousGamesPlayed / gamePlayedRequirement
        local newRatio = currentGamesPlayed / gamePlayedRequirement

        local oldIndex = LeagueUtil.GetLeagueIndex(oldRating)
        local newIndex = LeagueUtil.GetLeagueIndex(newRating)

        local oldLeague = LeagueUtil.GetLeague(oldRating)
        local newLeague = LeagueUtil.GetLeague(newRating)

        currentIcon.Image = oldLeague.Icon
        currentIcon.ImageTransparency = if isUnranked then 1 else 0
        newIcon.Image = newLeague.Icon

        leagueNameDisplay.Text = if isUnranked then "Unranked" else oldLeague.Name
        leagueNameDisplay.TextColor3 = if isUnranked then Color3.new(1, 1, 1) else oldLeague.Color

        if oldRating == newRating then
            baseAwait = 0
        end

        TweenUtils.PlayTweenSequence({
            TweenService:Create(currentIcon, TweenInfo.new(0), {Rotation = 0, Position = UDim2.fromScale(0.5, 0.45), ImageTransparency = if isUnranked then 1 else 0}),
            TweenService:Create(newIcon, TweenInfo.new(0), {ImageTransparency = 1}),
            TweenService:Create(newIcon.UIScale, TweenInfo.new(0), {Scale = 2}),
            TweenService:Create(ContinueButton, TweenInfo.new(0), {Position = UDim2.fromScale(0.5, 1.1)}),
            TweenService:Create(changeScale, TweenInfo.new(0), {Scale = 0.5}),
            2,
            function()
                ChangeFrame.Visible = true
                SoundService:PlayLocalSound(SFXFolder.Swoosh)
            end,
            TweenService:Create(changeScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
            0.5,
            true,
            function()
                task.wait(0.15)
                SoundService:PlayLocalSound(SFXFolder.Swoosh)
            end,
            TweenService:Create(changeScale, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {Scale = 0}),
            function()
                if ratingChanges >= 0 then
                    SoundService:PlayLocalSound(SoundService.SFX.RankUp)
                else
                    SoundService:PlayLocalSound(SoundService.SFX.RankDown)
                end
                ChangeFrame.Visible = false
            end,
            true,
            function()
                if oldIndex ~= newIndex then
                    task.wait(0.75)
                    TweenUtils.PlayTweenSequence({
                        TweenService:Create(currentIcon, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
                            Rotation = -15,
                            ImageTransparency = 1,
                            Position = UDim2.fromScale(0.5, 1)
                        }),
                    }, true)

                    if newIndex > oldIndex then
                        TweenUtils.PlayTweenSequence({
                            function()
                                newIcon.Visible = true
                            end,
                            true,
                            TweenService:Create(newIcon, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {ImageTransparency = 0}),
                            true,
                            TweenService:Create(newIcon.UIScale, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {Scale = 0.75}),
                            0.25,
                            function()
                                SoundService:PlayLocalSound(SFXFolder.LeagueUp)                                
                            end,
                            0.25,
                            function()
                                leagueNameDisplay.Text = newLeague.Name
                                leagueNameDisplay.TextColor3 = newLeague.Color
                            end,
                            TweenService:Create(FlashFrame, TweenInfo.new(0), {BackgroundTransparency = 0}),
                            true,
                            TweenService:Create(FlashFrame, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {BackgroundTransparency = 1}),
                            true,
                            TweenService:Create(newIcon.UIScale, TweenInfo.new(3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Scale = 1}),
                        }, true)
                    else
                        TweenUtils.PlayTweenSequence({
                            function()
                                newIcon.Visible = true
                                leagueNameDisplay.Text = newLeague.Name
                                leagueNameDisplay.TextColor3 = newLeague.Color
                                SoundService:PlayLocalSound(SFXFolder.LeagueDown)        
                            end,
                            TweenService:Create(newIcon.UIScale, TweenInfo.new(0), {Scale = 0.25}),
                            true,
                            TweenService:Create(newIcon, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {ImageTransparency = 0}),
                            true,
                            TweenService:Create(newIcon.UIScale, TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Scale = 1}),
                            1,
                        }, true)
                    end
                    baseAwait = 0
                end
            end,
            baseAwait,
            TweenService:Create(ContinueButton, TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {Position = UDim2.fromScale(0.5, 0.9)}),
        })

        local timeStart = time() + 3
        local ratingChangeDisplay = `{ratingChanges>=0 and "+" or ""}{LeagueUtil.FormatNumber(ratingChanges)} 🏆`
        if isUnranked then
            ratingChangeDisplay = "+1"
        end
        ChangeFrame.Display.Text = ratingChangeDisplay

        local function updateProgress()
            if isUnranked then
                Progression.Trophies.Text = `{previousGamesPlayed} / {gamePlayedRequirement} GAMES PLAYED`
                Progression.ProgressBar.Fill.Size = UDim2.fromScale(previousRatio, 1)
                task.wait(3)
                Progression.Trophies.Text = `{currentGamesPlayed} / {gamePlayedRequirement} GAMES PLAYED`
                TweenService:Create(Progression.ProgressBar.Fill, TweenInfo.new(
                    RATING_ANIMATE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut
                ), {
                    Size = UDim2.fromScale(newRatio, 1)
                }):Play()
                task.wait(RATING_ANIMATE_TIME)
                timeStart = 0
                return
            end

            local elapsed = time() - timeStart
            local progress = math.clamp(elapsed / RATING_ANIMATE_TIME, 0, 1)
            local value = TweenService:GetValue(progress, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
            
            local currentRating = math.lerp(oldRating, newRating, value)
            local nextLeague = LeagueConfig.Leagues[LeagueUtil.GetLeagueIndex(currentRating) + 1]
            local nextRating = nextLeague and nextLeague.MinTrophies
            local ratingProgress = LeagueUtil.GetProgress(currentRating)
            local display = nextRating 
                and `{LeagueUtil.FormatNumber(currentRating)} / {LeagueUtil.FormatNumber(nextRating)} 🏆`
                or `{LeagueUtil.FormatNumber(currentRating)} 🏆`
            Progression.Trophies.Text = display
            Progression.ProgressBar.Fill.Size = UDim2.fromScale(ratingProgress, 1)            
        end

        if ratingChanges ~= 0 and not isUnranked then
            while time() - timeStart < RATING_ANIMATE_TIME do
                updateProgress()
                task.wait()
            end            
        end
        
        updateProgress()   -- Update for the last time
    end)
end

return SummaryScreen