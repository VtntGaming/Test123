--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local MathUtils = require(ReplicatedStorage.Utils.MathUtils)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local ResultScene = require(script.ResultScene)
local ShowcaseScreen = require(script.ShowcaseScreen)
local SummaryScreen = require(script.SummaryScreen)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui  = LocalPlayer.PlayerGui
local CurrencyHolderHud = PlayerGui:WaitForChild("MainGui").HUD.CurrencyHolder
local ResultScreenUI = PlayerGui:WaitForChild("ResultScreen")
local ResultFrame = ResultScreenUI:WaitForChild("ResultFrame")
local ShowResultEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("ShowResult") :: RemoteEvent

--// Types
type PlayerScoreData = ShowcaseScreen.PlayerScoreData

export type ResultScreen = {
	Init: () -> (),	
	ShowResult: (
		placement: number, 
		listing: {PlayerScoreData}, 
		remains: number, 
		oldRating: number, 
		newRating: number,
		oldCoins: number,
		newCoins: number,
		isUnranked: boolean?) -> (),
	CheckState: () -> (),
}

--// Properties
local CoinThread: thread?

--// Local functions
local function GenerateHiddenScore(placement: number): PlayerScoreData
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
	ShowResultEvent.OnClientEvent:Connect(function(...)
		ResultScreen.ShowResult(...)
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
				local testOldCoins = 10000
				local testNewCoins = 25000
				local isUnranked = false

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

				ResultScreen.ShowResult(
					1, 
					listing, 
					hiddenCount, 
					testOldRating, 
					testNewRating, 
					testOldCoins, 
					testNewCoins, 
					isUnranked
				)				
			end
		end
	end)
	
	LocalPlayer:GetAttributeChangedSignal("IsOnArena"):Connect(function()		
		local isOnArena = LocalPlayer:GetAttribute("IsOnArena")

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
			LocalPlayer:SetAttribute("ResultShown", false)
        	ResultScene:SetSceneCameraEnabled(false)
        	ResultFrame.Cinematic.Visible = false
			ResultFrame.Dim.BackgroundTransparency = 1
			ResultFrame.Holder.CurrencyHolder.Visible = false
			CurrencyHolderHud.Visible = true
		end
	end

	showcaseFrame:GetPropertyChangedSignal("Visible"):Connect(onVisibilityChanged)
	summaryFrame:GetPropertyChangedSignal("Visible"):Connect(onVisibilityChanged)

	LocalPlayer:SetAttribute("ResultShown", false)

	ShowcaseScreen:Start()
	SummaryScreen:Start()
	ResultScene:Start()
end

function ResultScreen.ShowResult(placement, listing, remains, oldRating, newRating, oldCoins, newCoins, isUnranked)
	ResultFrame.Visible = true
	ResultFrame.Holder.CurrencyHolder.Visible = true
	CurrencyHolderHud.Visible = false
	LocalPlayer:SetAttribute("ResultShown", true)

	local resultListing = table.clone(listing)
	for hiddenPlacement = remains, 1, -1 do
		table.insert(resultListing, 1, GenerateHiddenScore(hiddenPlacement))
	end 
	
	ShowcaseScreen:ShowShowcase({
		Placement = placement,
		Listing = resultListing,
		OldRating = oldRating,
		NewRating = newRating,
		IsUnranked = isUnranked,
	})

	if CoinThread then
		task.cancel(CoinThread)
	end
	
	local coinChanges = math.max(0, newCoins - oldCoins)	-- It should not be negative by any chance
	local pos = ResultScreenUI.AbsolutePosition
	local currencyHolder = ResultFrame.Holder.CurrencyHolder
	local currencyChanges = ResultFrame.Holder.CurrencyChanges
	currencyHolder.Position = UDim2.new(0.006, -pos.X, 0.98, 0)
	currencyHolder.Value.Text = MathUtils.FormatNumber(oldCoins)
	currencyChanges.Value.Text = "+" .. MathUtils.FormatNumber(coinChanges)

	CoinThread = TweenUtils.PlayTweenSequence({
		TweenService:Create(currencyChanges.Value, TweenInfo.new(0), {
			TextTransparency = 1,
			Position = UDim2.fromScale(1.25, 0.5)
		}),
		TweenService:Create(currencyChanges.Value.UIStroke, TweenInfo.new(0), {
			Transparency = 1,
		}),
		0.5,
		true,
		TweenService:Create(currencyChanges.Value, TweenInfo.new(0.5, Enum.EasingStyle.Quart), {
			TextTransparency = 0,
			Position = UDim2.fromScale(1.5, 0.5)
		}),
		TweenService:Create(currencyChanges.Value.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quart), {
			Transparency = 0,
		}),
		1,
		true,
		TweenService:Create(currencyChanges.Value, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			TextTransparency = 1,
			Position = UDim2.fromScale(0.5, 0.5)
		}),
		TweenService:Create(currencyChanges.Value.UIStroke, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Transparency = 1,
		}),
		function()
			local animateTime = 1
			local s = time()

			while time() - s < animateTime do
				local alpha = (time() - s) / animateTime
				local value = TweenService:GetValue(alpha, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
				local currentCoin = math.lerp(oldCoins, newCoins, value)
				
				currencyHolder.Value.Text = MathUtils.FormatNumber(currentCoin)
				task.wait()
			end

			currencyHolder.Value.Text = MathUtils.FormatNumber(newCoins)
		end
	})
end

return ResultScreen
