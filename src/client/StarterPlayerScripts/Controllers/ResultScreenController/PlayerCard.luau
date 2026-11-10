--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local LeagueConfig = require(ReplicatedStorage.SharedModules.LeagueConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI.ResultFrame
local Container = ResultFrame.Holder.Showcase.MatchScore.Container.Listing
local TemplateDefault = Container.PlayerCard_Default
local TemplateHidden = Container.PlayerCard_Hidden

--// Constants
local RATING_CHANGE_DURATION = 2

--// Types
type PlayerCardType = typeof(TemplateDefault)

export type PlayerScoreData = {
    IsHidden: boolean?,
    Name: string,
    Icon: string,
    Placement: number?,
    RankRating: number,
    RatingChange: number,
}

export type PlayerCard = {
    __index: PlayerCard,
    Frame: PlayerCardType,
    Placement: number,
    TargetRatingChange: number,
    AppearAnim: {TweenUtils.TweenType},
    Threads: {[string]: thread},
    new: (data: PlayerScoreData, placement: number) -> (PlayerCard),
    Appear: (self: PlayerCard) -> (),
    Destroy: (self: PlayerCard) -> (),
}

local function FormatNumber(num: number): string
	local remain = (num * 1000) % 1000  -- Giving more precise decimal number
	local str = tostring(num // 1)

	local list = str:split("")

	for i = #list -2, 2, -3 do
		table.insert(list, i, ",")
	end

	local remainStr = tostring(remain / 1000)

	return table.concat(list)..remainStr:sub(2, #remainStr)
end

local PlayerCard = {} :: PlayerCard
PlayerCard.__index = PlayerCard

function PlayerCard.new(config, placement)
    local self = setmetatable({} :: any, PlayerCard) :: PlayerCard

    local frame: PlayerCardType
    local targetRatingChange = 0

    if config.IsHidden then
        frame = TemplateHidden:Clone() :: any
    else
        frame = TemplateDefault:Clone()
        
        local leagueData = LeagueConfig.Leagues[config.RankRating]

        if leagueData then
            local leagueImage = leagueData.Icon
            
            frame.Holder.LeagueIcon.Image = leagueImage
            frame.Holder.Title.Text = config.Name
            targetRatingChange = config.RatingChange
        end
        frame.Holder.Avatar.Image = config.Icon
    end
    self.TargetRatingChange = targetRatingChange

    frame.Visible = true    
    local holder = frame.Holder        
    local cardPlacement = placement
    holder.Rank.Text = `#{cardPlacement}`
    local awaitTime = math.max(0, cardPlacement - 1) * 0.05
    frame.Parent = Container

    self.AppearAnim = {
        function()
            if awaitTime > 0 then
                holder.Visible = false
                task.wait(awaitTime)
            end
        end,
        function()
            holder.Visible = true
        end,
        true, function()
            if not config.IsHidden then
                local s = time()
                
                while time() - s < RATING_CHANGE_DURATION do
                    local elapsed = time() - s
                    local progress = TweenService:GetValue(elapsed / RATING_CHANGE_DURATION, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
                    local currentRating = math.floor(self.TargetRatingChange * progress)

                    local display = `{currentRating >= 0 and "+" or ""}{(FormatNumber(currentRating))} 🏆`
                    holder.Value.Text = display
                    task.wait()
                end
            end            
        end,
        TweenService:Create(holder, TweenInfo.new(0), {Position = UDim2.fromScale(1.5, 0.5)}),
        TweenService:Create(holder, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {
            Position = UDim2.fromScale(0.35, 0.5)
        }),
        TweenService:Create(holder, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
            Position = UDim2.fromScale(0.5, 0.5)
        })
    }

    self.Frame = frame
    self.Placement = cardPlacement
    self.Threads = {}
    
    return self
end

function PlayerCard:Appear()
    if self.Threads.Appear then
        task.cancel(self.Threads.Appear)
    end

    self.Threads.Appear = TweenUtils.PlayTweenSequence(self.AppearAnim) :: thread
end

function PlayerCard:Destroy()
    if not self.Frame then
        return
    end

    for _, thread in pairs(self.Threads) do
        if coroutine.running() == thread then
            task.defer(function()
                task.cancel(thread)
            end)
        else
            task.cancel(thread)
        end
    end

    self.Frame:Destroy()
    table.clear(self)
end

return PlayerCard