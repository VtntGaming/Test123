--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local Config = require(ReplicatedStorage.SharedModules.DailyRewardConfig)
local EasyVisuals = require(ReplicatedStorage.Utils.EasyVisuals)
local FX = require(script.Parent.DailyRewardFX)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainUI = PlayerGui:WaitForChild("MainGui")
local DailyRewardFrame = MainUI:WaitForChild("DailyRewardFrame")
local DailyRewardContent = DailyRewardFrame.Frame
local Ref = DailyRewardContent.SmallContainer.SupportContainer.Day7
local StarParticle = DailyRewardFrame.Assets.StarParticle

--// Constants
local WHITE = Color3.fromRGB(255, 255, 255)
local DIMMED = Color3.fromRGB(105, 105, 105)
local PULSE_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local POP_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local INTRO_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local INTRO_SPIN_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

--// Types
type Reward = Config.Reward

export type FrameType = typeof(Ref)

export type DailyRewardItemState = {
	Claimed: boolean,
	IsNext: boolean,
	Claimable: boolean,
	CanSkip: boolean,
	SecondsLeft: number,
}

export type DailyRewardItem = {
	__index: DailyRewardItem,
	Day: number?,
	Frame: FrameType,
	Reward: Reward?,
	Scale: UIScale?,
	ClaimButton: GuiButton?,
	ClaimTitle: TextLabel?,
	ClaimHover: GuiObject?,
	Icon: ImageLabel?,
	Timer: TextLabel?,
	RewardLabel: TextLabel?,
	CardGradient: UIGradient?,
	DefaultGradientColor: ColorSequence?,
	ClaimGradient: UIGradient?,
	SkipGradient: UIGradient?,
	ClaimedGradient: UIGradient?,
	Pulse: Tween?,
	PopTween: Tween?,
	ClaimConnection: RBXScriptConnection?,
	PopConnection: RBXScriptConnection?,
	OnClaim: ((day: number) -> ())?,
	Introducing: boolean?,
	IntroToken: number?,
	WantPulse: boolean?,
	IsSetup: boolean,
	IsStarted: boolean,
	new: (day: number) -> DailyRewardItem?,
	Setup: (self: DailyRewardItem) -> (),
	Start: (self: DailyRewardItem, onClaim: (day: number) -> ()) -> (),
	Render: (self: DailyRewardItem, state: DailyRewardItemState) -> (),
	SetTimer: (self: DailyRewardItem, secondsLeft: number) -> (),
	PlayClaimed: (self: DailyRewardItem) -> (),
	PlayIntro: (self: DailyRewardItem, delayTime: number) -> (),
	Destroy: (self: DailyRewardItem) -> (),
}

--// Item
local Item = {} :: DailyRewardItem
Item.__index = Item

--// Helpers
local function findGradient(parent: Instance?, name: string): UIGradient?
	local gradient = parent and parent:FindFirstChild(name)
	if gradient and gradient:IsA("UIGradient") then
		return gradient
	end
	return nil
end

local function setPulse(item: DailyRewardItem, enabled: boolean)
	local scale = item.Scale
	if not scale then
		return
	end

	item.WantPulse = enabled
	if item.Pulse then
		item.Pulse:Cancel()
		item.Pulse = nil
		if not item.Introducing then
			scale.Scale = 1
		end
	end

	-- the intro tween owns the scale until it finishes, then re-applies the wanted pulse
	if enabled and not item.Introducing then
		local pulse = TweenService:Create(scale, PULSE_INFO, { Scale = 1.06 })
		item.Pulse = pulse
		pulse:Play()
	end
end

local function setClaimButton(item: DailyRewardItem, text: string, enabled: boolean)
	local claimButton = item.ClaimButton
	if claimButton then
		claimButton.Active = enabled
	end
	if item.ClaimTitle then
		item.ClaimTitle.Text = text
	end
	if item.ClaimHover then
		item.ClaimHover.Visible = not enabled
	end
end

local function setCardGradient(item: DailyRewardItem, gradient: UIGradient?)
	if true then
		return
	end
	local cardGradient = item.CardGradient
	if not cardGradient then
		return
	end

	local color = if gradient then gradient.Color else item.DefaultGradientColor
	if color then
		cardGradient.Color = color
	end
end

--// APIs
function Item.new(day: number): DailyRewardItem?
	local frame: FrameType = nil
	for _, descendant in DailyRewardContent:GetDescendants() do
		if descendant:IsA("Frame") and descendant.Name == `Day{day}` then
			frame = descendant :: FrameType
			break
		end
	end

	local reward = Config.Rewards[day]
	if not frame or not reward then
		warn(("[DailyRewardItem] Could not find a configured Day%d card in DailyRewardFrame"):format(day))
		return nil
	end

	local self = setmetatable({} :: any, Item) :: DailyRewardItem
	self.Day = day
	self.Frame = frame
	self.Reward = reward
	self.IsSetup = false
	self.IsStarted = false

	return self
end

function Item:Setup()
	if self.IsSetup then
		return
	end
	self.IsSetup = true

	local frame = self.Frame
	local reward = self.Reward
	local day = self.Day
	if not frame or not reward or not day then
		warn("[DailyRewardItem] Cannot set up an item after it has been destroyed")
		return
	end
	frame.Visible = true

	local scale = frame:FindFirstChildOfClass("UIScale")
	if not scale then
		local newScale = Instance.new("UIScale")
		newScale.Parent = frame
		scale = newScale
	end
	self.Scale = scale

	local title = frame:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = `Day {day}`
	end

	local rewardLabel = frame:FindFirstChild("Reward")
	if rewardLabel and rewardLabel:IsA("TextLabel") then
		rewardLabel.Text = reward.Label
		rewardLabel.TextColor3 = reward.Color:Lerp(WHITE, 0.35)
		self.RewardLabel = rewardLabel
	end

	local icon = frame:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.Image = reward.Image
		self.Icon = icon
	end

	local canvasGroup = frame:FindFirstChild("CanvasGroup")
	local sunburst = canvasGroup and canvasGroup:FindFirstChild("Sunburst")
	if sunburst and sunburst:IsA("ImageLabel") then
		sunburst.ImageColor3 = reward.Color
	end

	local claimButton = frame:FindFirstChild("Claim")
	if claimButton and claimButton:IsA("GuiButton") then
		self.ClaimButton = claimButton

		local claimTitle = claimButton:FindFirstChild("Title")
		if claimTitle and claimTitle:IsA("TextLabel") then
			self.ClaimTitle = claimTitle
		end

		local claimHover = claimButton:FindFirstChild("Hover")
		if claimHover and claimHover:IsA("GuiObject") then
			self.ClaimHover = claimHover
		end
	else
		warn(("[DailyRewardItem] Day%d has no Claim button"):format(day))
	end

	local timer = frame:FindFirstChild("Timer")
	if timer and timer:IsA("TextLabel") then
		self.Timer = timer
	end

	local cardGradient = frame:FindFirstChildOfClass("UIGradient")
	if cardGradient then
		self.CardGradient = cardGradient
		self.DefaultGradientColor = cardGradient.Color
	end

	local rewardWindow = frame:FindFirstAncestor("DailyRewardFrame")
	local states = rewardWindow and rewardWindow:FindFirstChild("States")
	self.ClaimGradient = findGradient(states, "Claim")
	self.SkipGradient = findGradient(states, "Skip")
	self.ClaimedGradient = findGradient(states, "Claimed")
end

function Item:Start(onClaim: (day: number) -> ())
	if self.IsStarted then
		return
	end
	self.IsStarted = true
	self.OnClaim = onClaim

	local claimButton = self.ClaimButton
	if not claimButton then
		return
	end

	FX.AttachButtonFeel(claimButton, 1.08)

	self.ClaimConnection = claimButton.Activated:Connect(function()
		local day = self.Day
		if not self.ClaimButton or not self.ClaimButton.Active or not day then
			return
		end
		if self.OnClaim then
			self.OnClaim(day)
		end
	end)

	local subBurst = self.Frame.CanvasGroup.Sunburst
	TweenService:Create(subBurst, TweenInfo.new(20, 
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.InOut,
		-1
	), {
		Rotation = 360
	}):Play()

	if self.Day == 7 or self.Day == 4 then
		local gradientStroke = self.Frame.UIStroke.UIGradient
		local gradientFill = self.Frame.UIGradient

		local stars = {}

		task.spawn(function()
			while true do
				local dt = task.wait()

				local rotationChange = dt * 360 / 8
				gradientStroke.Rotation += rotationChange

				if self.Day == 7 then
					local shadow  = self.Frame.UIShadow
					local h, s, v = shadow.Color:ToHSV()
					local shadowRainbowRate = dt / 4
					shadow.Color = Color3.fromHSV((h + shadowRainbowRate) % 1, s, v)

					for i = #stars, 1, -1 do
						local star = stars[i] :: typeof(StarParticle)
	
						local position = star.Position
						local posX = position.X.Scale
						local posY = position.Y.Scale
	
						posY -= dt / 4
						star.Position = UDim2.fromScale(posX, posY)
						star.Rotation += rotationChange
	
						if posY <= 0.25 then
							local trans = 1 - posY / 0.25
							star.ImageTransparency = trans
						elseif star.ImageTransparency > 0 then
							star.ImageTransparency = math.max(star.ImageTransparency - (dt / 0.5), 0)
						end

						local starH, starS, starV = star.ImageColor3:ToHSV()
						star.ImageColor3 = Color3.fromHSV((starH + dt / 8) % 1, starS, starV)
	
						if posY < -0.5 then
							star:Destroy()
							table.remove(stars, i)
						end
					end
				end	
			end
		end)

		if self.Day == 7 then
			task.spawn(function()
				EasyVisuals.new(self.Frame, "Rainbow", 0.25, 2)
				EasyVisuals.new(self.Frame.Title, "Rainbow", 0.25, 2)
				gradientFill.Rotation = -5
				TweenService:Create(self.Frame.Highlight, TweenInfo.new(
					0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true
				), {Rotation = 16}):Play()
				
				while true do
					task.wait(0.15 + math.random() * 0.5)
					local star = StarParticle:Clone()
					local size = 0.2 + math.random() * 0.1
					local posX = math.random()
					local posY = 0.9 + math.random() * 0.35
					local rotation = math.random() * 360
					star.Position = UDim2.fromScale(posX, posY)
					star.Size = UDim2.fromScale(size, size)
					star.Rotation = rotation
					star.ImageTransparency = 1
					star.Visible = true
					star.ImageColor3 = Color3.fromHSV(math.random(), 0.5, 1)
					star.Parent = self.Frame :: any
					stars[#stars + 1] = star
				end
			end)
		end
	end
end

function Item:Render(state: DailyRewardItemState)
	local frame = self.Frame
	if not frame then
		return
	end

	frame:SetAttribute("Claimable", state.Claimable)
	setPulse(self, state.Claimable)
	FX.SetCardAmbient(frame, if state.Claimable then "Claim" elseif state.IsNext and not state.Claimed then "Next" else "None")
	
	if self.Icon then
		self.Icon.ImageColor3 = if state.Claimed then DIMMED else WHITE
	end
	if self.Timer then
		self.Timer.Text = ""
	end

	if state.Claimed then
		setClaimButton(self, "CLAIMED", false)
		setCardGradient(self, self.ClaimedGradient)
	elseif state.Claimable then
		setClaimButton(self, "CLAIM", true)
		setCardGradient(self, self.ClaimGradient)
	elseif state.IsNext then
		if state.CanSkip then
			setClaimButton(self, "SKIP", true)
			setCardGradient(self, self.SkipGradient)
		else
			setClaimButton(self, "SOON", false)
			setCardGradient(self, nil)
		end
		self:SetTimer(state.SecondsLeft)
	else
		setClaimButton(self, "LOCKED", false)
		setCardGradient(self, nil)
	end
end

function Item:SetTimer(secondsLeft: number)
	local timer = self.Timer
	if timer then
		local remaining = math.max(0, math.ceil(secondsLeft))
		local text = string.format("%02d:%02d:%02d", remaining // 3600, (remaining % 3600) // 60, remaining % 60)
		if timer.Text ~= text then
			local hadText = timer.Text ~= ""
			timer.Text = text
			if hadText and DailyRewardFrame.Visible then
				FX.TimerTick(timer)
			end
		end
	end
end

function Item:PlayIntro(delayTime: number)
	local scale = self.Scale
	local frame = self.Frame
	local day = self.Day
	if not scale or not frame or not day then
		return
	end

	local token = (self.IntroToken or 0) + 1
	self.IntroToken = token
	self.Introducing = true

	if self.Pulse then
		self.Pulse:Cancel()
		self.Pulse = nil
	end
	if self.PopConnection then
		self.PopConnection:Disconnect()
		self.PopConnection = nil
	end
	if self.PopTween then
		self.PopTween:Cancel()
	end

	scale.Scale = 0
	frame.Rotation = if day % 2 == 0 then 12 else -12

	task.delay(delayTime, function()
		if self.IntroToken ~= token or not self.Frame or not self.Scale then
			return
		end

		TweenService:Create(frame, INTRO_SPIN_INFO, { Rotation = 0 }):Play()
		local grow = TweenService:Create(scale, INTRO_INFO, { Scale = 1 })
		grow.Completed:Once(function()
			if self.IntroToken ~= token then
				return
			end
			self.Introducing = false
			scale.Scale = 1
			setPulse(self, self.WantPulse == true)
		end)
		grow:Play()
	end)
end

function Item:PlayClaimed()
	local scale = self.Scale
	local frame = self.Frame
	if not scale then
		return
	end

	self.IntroToken = (self.IntroToken or 0) + 1
	self.Introducing = false
	if frame then
		frame.Rotation = 0
		local reward = self.Reward
		FX.Burst(DailyRewardFrame, frame, if reward then reward.Color else WHITE)
	end

	setPulse(self, false)
	scale.Scale = 1
	if self.PopConnection then
		self.PopConnection:Disconnect()
		self.PopConnection = nil
	end
	if self.PopTween then
		self.PopTween:Cancel()
	end

	local popTween = TweenService:Create(scale, POP_INFO, { Scale = 1.18 })
	self.PopTween = popTween
	self.PopConnection = popTween.Completed:Once(function(playbackState)
		self.PopConnection = nil
		if playbackState == Enum.PlaybackState.Completed and self.Frame and self.Scale == scale then
			local resetTween = TweenService:Create(scale, POP_INFO, { Scale = 1 })
			self.PopTween = resetTween
			resetTween:Play()
		end
	end)
	popTween:Play()
end

function Item:Destroy()
	if not self.Frame then
		return
	end

	if self.Frame then
		FX.SetCardAmbient(self.Frame, "None")
	end
	self.IntroToken = (self.IntroToken or 0) + 1
	if self.ClaimConnection then
		self.ClaimConnection:Disconnect()
	end
	if self.PopConnection then
		self.PopConnection:Disconnect()
	end
	if self.Pulse then
		self.Pulse:Cancel()
	end
	if self.PopTween then
		self.PopTween:Cancel()
	end
	table.clear(self)
end

return Item
