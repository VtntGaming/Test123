--!strict

--// Services
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

--// Modules
local Config = require(ReplicatedStorage.SharedModules.DailyRewardConfig)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)
local Signal = require(ReplicatedStorage.Utils.Signal)
local UIInteractionController = require(script.Parent.UIInteractionController)
local DailyRewardItem = require(script.DailyRewardItem)
local FX = require(script.DailyRewardFX)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainUI = PlayerGui:WaitForChild("MainGui")
local DailyRewardFrame = MainUI:WaitForChild("DailyRewardFrame")
local DailyRewardContent = DailyRewardFrame.Frame
local DailyRewardExitButton = DailyRewardFrame.ExitButton
local DailyRewardButton = MainUI.HUD.LeftButtons.ButtonList2.DailyRewardButton
local DailyRewardBadge = DailyRewardButton.Notification
local DailyOpenSound = SoundService.SFX.DailyUIOpen
local Remote = ReplicatedStorage.Events.DailyRewardRemote

--// Constants
local OPEN_BUTTON_TAG = "OpenDailyRewardButton"

--// Types
export type ServerState = {
	Claimed: number,
	NextDay: number,
	CanClaim: boolean,
	SecondsLeft: number,
	Completed: boolean,
}

type RewardItem = DailyRewardItem.DailyRewardItem

export type DailyRewardController = {
	Badge: GuiObject?,
	Cards: { [number]: RewardItem }?,
	CanClaim: boolean?,
	NotifyDaily: Signal.Signal<>,
	Init: () -> (),
	Setup: (self: DailyRewardController) -> (),
	Start: (self: DailyRewardController) -> (),
	Toggle: (forceState: boolean?) -> (),
}

--// Properties
local CurrentState: ServerState?
local StateReceivedAt = 0
local Claiming = false
local RequestedRefresh = false
local LastRefreshAt = 0
local AutoOpenDone = false
local IsSetup = false
local IsStarted = false
local BoundOpenButtons: { [GuiButton]: boolean } = {}

--// Controller
local Controller = {} :: DailyRewardController

--// Helpers
local function GetSecondsLeftNow(): number
	local state = CurrentState
	if not state then
		return 0
	end
	return math.max(0, state.SecondsLeft - (os.clock() - StateReceivedAt))
end

local function GetServerState(payload: unknown): ServerState?
	if typeof(payload) ~= "table" then
		warn("[DailyRewardController] Ignored invalid daily reward state payload")
		return nil
	end

	local data = payload :: { [string]: unknown }
	local claimed = data.claimed
	local nextDay = data.nextDay
	local canClaim = data.canClaim
	local secondsLeft = data.secondsLeft
	local completed = data.completed
	if
		typeof(claimed) ~= "number"
		or typeof(nextDay) ~= "number"
		or typeof(canClaim) ~= "boolean"
		or typeof(secondsLeft) ~= "number"
		or typeof(completed) ~= "boolean"
	then
		warn("[DailyRewardController] Ignored daily reward state with invalid fields")
		return nil
	end

	return {
		Claimed = claimed,
		NextDay = nextDay,
		CanClaim = canClaim,
		SecondsLeft = secondsLeft,
		Completed = completed,
	}
end

local function RequestState()
	Remote:FireServer("RequestState")
end

local function PromptSkip()
	local productId = Config.SkipDailyProductId
	if productId == 0 then
		NotificationUtil.Show("Info", "Skipping the wait isn't available right now.")
		return
	end

	local success, err = pcall(function()
		MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
	end)
	if not success then
		warn("[DailyRewardController] Skip prompt failed:", err)
		NotificationUtil.Show("Info", "Couldn't open the purchase prompt. Please try again.")
	end
end

local function BindOpenButton(button: Instance)
	if not button:IsA("GuiButton") or BoundOpenButtons[button] then
		return
	end

	BoundOpenButtons[button] = true
	button.Activated:Connect(function()
		Controller.Toggle(nil)
	end)
end

--// APIs
function Controller:Setup()
	if IsSetup then
		return
	end

	local cards: { [number]: RewardItem } = {}
	self.Cards = cards
	for _, descendant in DailyRewardContent:GetDescendants() do
		if descendant:IsA("Frame") then
			local day = descendant.Name:match("^Day(%d+)$")
			local dayNumber = if day then tonumber(day) else nil
			if dayNumber and dayNumber > Config.MaxDays then
				descendant.Visible = false
			end
		end
	end

	for day, _ in ipairs(Config.Rewards) do
		local item = DailyRewardItem.new(day)
		if item then
			item:Setup()
			cards[day] = item
		end
	end

	self.Badge = DailyRewardBadge
	DailyRewardFrame.Visible = false
	IsSetup = true

	self.NotifyDaily = Signal.new()
end

function Controller:Start()
	if IsStarted then
		return
	end
	if not IsSetup then
		warn("[DailyRewardController] Cannot start before setup completes")
		return
	end
	IsStarted = true

	local cards = self.Cards
	if cards then
		for _, card in cards do
			card:Start(function(day: number)
				local state = CurrentState
				if not state or state.NextDay ~= day or state.Completed then
					return
				end

				if state.CanClaim then
					if Claiming then
						return
					end

					Claiming = true
					Remote:FireServer("Claim")
					task.delay(3, function()
						Claiming = false
					end)
					return
				end

				PromptSkip()
			end)
		end
	end

	-- The skip purchase is settled on the server; resync the cards as soon as the prompt closes so the UI never looks stuck.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
		if userId ~= LocalPlayer.UserId or productId ~= Config.SkipDailyProductId then
			return
		end
		if purchased then
			task.delay(1.5, RequestState)
			task.delay(4, RequestState)
		end
	end)

	DailyRewardExitButton.Activated:Connect(function()
		Controller.Toggle(false)
	end)

	DailyRewardButton.Activated:Connect(function()
		Controller.Toggle(nil)
	end)

	Remote.OnClientEvent:Connect(function(action: string, payload: unknown)
		if action == "State" then
			local state= GetServerState(payload)
			if not state then
				return
			end

			CurrentState = state
			StateReceivedAt = os.clock()
			Claiming = false
			RequestedRefresh = false

			local cards = Controller.Cards
			if cards then
				for day, card in cards do
					card:Render({
						Claimed = day <= state.Claimed,
						IsNext = day == state.NextDay and not state.Completed,
						Claimable = day == state.NextDay and state.CanClaim and not state.Completed,
						CanSkip = Config.SkipDailyProductId ~= 0,
						SecondsLeft = GetSecondsLeftNow(),
					})
				end
			end

			local badge = Controller.Badge
			if badge then
				badge.Visible = state.CanClaim
			end
			FX.SetAttention(DailyRewardButton, badge, state.CanClaim)
			if state.CanClaim then
				self.CanClaim = true
				self.NotifyDaily:Fire()
			end

			if not AutoOpenDone and Config.AutoOpenWhenClaimable then
				AutoOpenDone = true
				task.spawn(function()
					local deadline = os.clock() + 60
					while os.clock() < deadline do
						local loading = PlayerGui:FindFirstChild("Loading")
						if not loading or (loading:GetAttribute("GameReady") == true and LocalPlayer:GetAttribute("LoadingFinished") == true) then
							break
						end
						task.wait(0.5)
					end

					task.wait(Config.AutoOpenDelay)
					local currentState = CurrentState
					if
						currentState
						and currentState.CanClaim
						and not DailyRewardFrame.Visible
						and not LocalPlayer:GetAttribute("IsOnArena")
					then
						Controller.Toggle(true)
					end
				end)
			end
		elseif action == "Claimed" then
			if typeof(payload) ~= "table" then
				warn("[DailyRewardController] Ignored invalid daily reward claim payload")
				return
			end

			local data = payload :: { [string]: unknown }
			local day = data.day
			local name = data.name
			if typeof(day) ~= "number" or typeof(name) ~= "string" then
				warn("[DailyRewardController] Ignored daily reward claim with invalid fields")
				return
			end

			Claiming = false
			local soundFolder = SoundService:FindFirstChild("GuiSounds")
			local sound = soundFolder and soundFolder:FindFirstChild("PlaytimeRewardsSound")
			if sound and sound:IsA("Sound") then
				SoundService:PlayLocalSound(sound)
			end
			NotificationUtil.Show("Success", "Claimed " .. name .. "!")

			local cards = Controller.Cards
			local card = cards and cards[day]
			if card then
				card:PlayClaimed()
			end
		end
	end)

	for _, button in CollectionService:GetTagged(OPEN_BUTTON_TAG) do
		BindOpenButton(button)
	end
	CollectionService:GetInstanceAddedSignal(OPEN_BUTTON_TAG):Connect(BindOpenButton)

	task.spawn(function()
		while LocalPlayer:GetAttribute("DataLoaded") ~= true do
			LocalPlayer:GetAttributeChangedSignal("DataLoaded"):Wait()
		end
		RequestState()
	end)

	task.spawn(function()
		-- Keeps ticking forever: the state can arrive late, flip to "waiting" after a claim, or come back after a reset.
		while DailyRewardFrame.Parent do
			task.wait(0.25)
			local state = CurrentState
			if not state or state.CanClaim or state.Completed then
				continue
			end

			local remaining = GetSecondsLeftNow()
			local cards = Controller.Cards
			local card = cards and cards[state.NextDay]
			if card then
				card:SetTimer(remaining)
			end

			if remaining <= 0 and (not RequestedRefresh or os.clock() - LastRefreshAt > 5) then
				RequestedRefresh = true
				LastRefreshAt = os.clock()
				RequestState()
			end
		end
	end)
end

function Controller.Toggle(forceState: boolean?)
	local opening = if forceState ~= nil then forceState else not DailyRewardFrame.Visible
	UIInteractionController.ToggleFrame(DailyRewardFrame, opening)
	if opening then
		SoundService:PlayLocalSound(DailyOpenSound)
		FX.OpenWindow(DailyRewardFrame)
		local cards = Controller.Cards
		if cards then
			for day, card in cards do
				card:PlayIntro(0.12 + (day - 1) * 0.02)
			end
		end
		RequestState()
	else
		FX.CloseWindow(DailyRewardFrame)
	end
end

function Controller.Init()
	Controller:Setup()
	Controller:Start()
end

return Controller
