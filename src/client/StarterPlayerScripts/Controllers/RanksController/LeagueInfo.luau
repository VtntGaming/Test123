--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local LeagueConfig = require(ReplicatedStorage.SharedModules.LeagueConfig)
local LeagueUtil = require(ReplicatedStorage.Utils.LeagueUtil)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local RanksFrame = MainGui.RanksFrame
local InfoFrame = RanksFrame.LeagueInfo

--// Types
export type LeagueInfo = {
    IsVisible: boolean,
    Setup: (self: LeagueInfo) -> (),
    Start: (self: LeagueInfo) -> (),
    BuildInfo: (self: LeagueInfo) -> (),
    SetVisible: (self: LeagueInfo, visible: boolean) -> (),
}

--// Local functions
local LeagueInfo = {} :: LeagueInfo

function LeagueInfo:Setup()
    self.IsVisible = false
end

function LeagueInfo:Start()    
    InfoFrame.ExitButton.Activated:Connect(function()
        self:SetVisible(false)
    end)
    
    self:BuildInfo()
    self:SetVisible(false)
end

function LeagueInfo:SetVisible(visible)
    self.IsVisible = visible

    if visible then
		TweenUtils.PlayTweenSequence({
			function()
				InfoFrame.Visible = true
			end,
			TweenService:Create(InfoFrame.UIScale, TweenInfo.new(0), {Scale = 0}),
			TweenService:Create(InfoFrame.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}),
		})

        for _, item in ipairs(InfoFrame.Listing:GetChildren()) do
            if item:IsA("Frame") and item ~= InfoFrame.Listing.Template then
                local animateItem = item :: typeof(InfoFrame.Listing.Template)

                local uiScale = animateItem.UIScale

                TweenUtils.PlayTweenSequence({
                    TweenService:Create(uiScale, TweenInfo.new(0), {Scale = 0}),
                    animateItem.LayoutOrder * 0.1,
                    TweenService:Create(uiScale, TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Scale = 1}),                    
                })
            end
        end
	else
		TweenUtils.PlayTweenSequence({
			TweenService:Create(InfoFrame.UIScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Scale = 0}),
			function()
				InfoFrame.Visible = false
			end,
		})
	end
end

function LeagueInfo:BuildInfo()
    local info = InfoFrame
	local listing = info.Listing
	local template = listing.Template
	template.Visible = false

	local leagues = LeagueConfig.Leagues
	for i, league in ipairs(leagues) do
		local row = template:Clone()
		row.Name = "League_" .. league.Name
		row.LayoutOrder = i -- highest league first
		local mainContainer = row.MainContainer
		local icon = mainContainer.LeagueIcon
		local name = mainContainer.LeagueName
		local minTrophies = mainContainer.MinTrophies
		if icon then icon.Image = league.Icon end
		if name then name.Text = league.Name end
		if minTrophies then minTrophies.Text = LeagueUtil.FormatNumber(league.MinTrophies) .. `{league.MinTrophies > 0 and "+" or ""} 🏆` end

		if i == #LeagueConfig.Leagues then
			row.NextRank.Visible = false
		end

		row.Visible = true
		row.Parent = template.Parent
	end
end

return LeagueInfo