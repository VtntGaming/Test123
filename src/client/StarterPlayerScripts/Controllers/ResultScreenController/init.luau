--!strict
-- Presents result screen controller behavior using logical Player data access.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local ResultScene = require(script.ResultScene)
local ShowcaseScreen = require(script.ShowcaseScreen)
local SummaryScreen = require(script.SummaryScreen)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui  = LocalPlayer.PlayerGui
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local ShowResultEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("ShowResult") :: RemoteEvent

--// Types
type PlayerScoreData = ShowcaseScreen.PlayerScoreData

export type ResultScreen = {
	Init: () -> (),	
	ShowResult: (placement: number, listing: {PlayerScoreData}, remains: number, oldRating: number, newRating: number) -> (),
	CheckState: () -> (),
}

--// Local functions
local function GenerateHiddenScore(placement: number)
	return {
		IsHidden = true,
		Name = "???",
		Icon = "",
		Placement = placement,
		RankRating = 0,
		RatingChange = 0,
	}
end

local ResultScreen = {} :: ResultScreen

--// APIs
function ResultScreen.Init()
	ShowcaseScreen:Setup()
	SummaryScreen:Setup()
	ResultScene:Setup()

	ResultFrame.Visible = false
	ShowResultEvent.OnClientEvent:Connect(function(placement, listing, remains, oldRating, newRating)
		ResultScreen.ShowResult(placement, listing, remains, oldRating, newRating)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject)
		-- Demo hotkey

		if input.KeyCode == Enum.KeyCode.H and UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) then
			if RunService:IsStudio() then
				local listing: {PlayerScoreData} = {}

				local hiddenCount = 4
				local baseCount = 10
				local testOldRating = 1000
				local testNewRating = 2000

				for i = 1, baseCount do
					local placement = #listing + 1
					local ratingChange = math.round((20 - (placement - 1) * 5) * math.lerp(0.9, 1.1, math.random()))
					table.insert(listing, {
						Name = `Player{i}`,
						Icon = "rbxthumb://type=AvatarHeadShot&id=1&w=48&h=48",
						Placement = placement,
						RankRating = 1,
						RatingChange = ratingChange,
					})
				end

				ResultScreen.ShowResult(1, listing, hiddenCount, testOldRating, testNewRating)				
			end
		end
	end)
	
	PlayerData.Observe(LocalPlayer, "IsOnArena", function()
		local isOnArena = PlayerData.Get(LocalPlayer, "IsOnArena")

		if isOnArena then
			if ShowcaseScreen.IsVisible then
				ShowcaseScreen:SetVisible(false)
			end

			if SummaryScreen.IsVisible then
				SummaryScreen:SetVisible(false)
			end
		end
	end)

	local showcaseFrame = ResultFrame.Holder.Showcase
	local summaryFrame = ResultFrame.Holder.RankSummary

	local function onVisibilityChanged()
		if not showcaseFrame.Visible and not summaryFrame.Visible then
			PlayerData.SetLocal(LocalPlayer, "ResultShown", false)
        	ResultScene:SetSceneCameraEnabled(false)
        	ResultFrame.Cinematic.Visible = false
			ResultFrame.Dim.BackgroundTransparency = 1
		end
	end

	showcaseFrame:GetPropertyChangedSignal("Visible"):Connect(onVisibilityChanged)
	summaryFrame:GetPropertyChangedSignal("Visible"):Connect(onVisibilityChanged)

	PlayerData.SetLocal(LocalPlayer, "ResultShown", false)

	ShowcaseScreen:Start()
	SummaryScreen:Start()
	ResultScene:Start()
end

function ResultScreen.ShowResult(placement, listing, remains, oldRating, newRating)
	ResultFrame.Visible = true
	PlayerData.SetLocal(LocalPlayer, "ResultShown", true)

	local resultListing = table.clone(listing)
	for hiddenPlacement = remains, 1, -1 do
		table.insert(resultListing, 1, GenerateHiddenScore(hiddenPlacement))
	end 
	
	ShowcaseScreen:ShowShowcase({
		Placement = placement,
		Listing = resultListing,
		OldRating = oldRating,
		NewRating = newRating
	})
end

return ResultScreen
