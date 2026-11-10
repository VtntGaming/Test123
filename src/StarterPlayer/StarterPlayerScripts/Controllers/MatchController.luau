local MatchController = {}

-- ==========================================
-- SERVICES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")
local PlayLoserSoundEvent = Events:WaitForChild("PlayLoserSoundEvent")

local SFX = SoundService:WaitForChild("SFX")
local gameOver = SFX:WaitForChild("GameOver")


local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local ArenaDropEvent = Events:WaitForChild("ArenaDropEvent")
local LANDING_ANIMATION_ID = "rbxassetid://98548063446402" 
local FALLING_ANIMATION_ID = "rbxassetid://128339318858014"
local countdownImages = {
	[3] = "rbxassetid://83789668018993",
	[2] = "rbxassetid://127099148817226",
	[1] = "rbxassetid://94327717856403",
	[0] = "rbxassetid://137507105742412"
}

local countdownUI = nil
local countdownImage = nil
local countdownSound = nil

-- ==========================================
-- LOGIC
-- ==========================================
local annouce30sec = false
local landingTrack
local fallingTrack
local dropToken = 0


local function onGameStateUpdated(state, timerValue)
	if state == "Starting" then
		if not LocalPlayer:GetAttribute("IsOnArena") then return end 
		countdownUI.Visible = true
		countdownImage.Image = countdownImages[timerValue] or ""

		local targetScale = 1

		if timerValue == 0 then
			targetScale = 2
		end

		TweenUtils.PlayTweenSequence({
			TweenService:Create(countdownImage.UIScale, TweenInfo.new(0), {
				Scale = 0
			}),
			TweenService:Create(countdownImage, TweenInfo.new(0), {
				Rotation = -180
			}),
			true,
			TweenService:Create(countdownImage.UIScale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = targetScale
			}),
			TweenService:Create(countdownImage, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Rotation = 0
			}),
			0.7,
			true,
			TweenService:Create(countdownImage.UIScale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Scale = 0
			}),
			TweenService:Create(countdownImage, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Rotation = 180
			}),
		})

		if timerValue == 3 then
			countdownSound:Play()
		elseif timerValue == 0 then
			task.delay(1, function() countdownUI.Visible = false end)
		end
	else
		countdownUI.Visible = false
	end
	
	do -- announcement sound
		if state == "Playing"
			and timerValue <= 30
			and timerValue > 27 -- incase package loss
			and not annouce30sec
		then
			annouce30sec = true
			local sound = SoundService.SFX:FindFirstChild("30SecondsLeft")
			if sound then
				sound:Play()
				warn(`Annouced 30 sec left`)
			end
		elseif state == "Starting" or state == "Waiting" then
			annouce30sec = false
		end
	end
end

-- ==========================================
-- INIT
-- ==========================================
local function shakeCamera(duration, intensity)
	local camera = workspace.CurrentCamera
	local startTime = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		if elapsed >= duration then conn:Disconnect() return end
		local fade = 1 - elapsed / duration
		camera.CFrame *= CFrame.Angles(
			math.rad((math.random() - 0.5) * intensity * fade),
			math.rad((math.random() - 0.5) * intensity * fade),
			0
		)
	end)
end

local function loadTrack(animator, animationId, priority, looped)
	local anim = Instance.new("Animation")
	anim.AnimationId = animationId
	local track = animator:LoadAnimation(anim)
	track.Priority = priority
	track.Looped = looped
	return track
end

--local function stopFalling()
--	if fallingTrack and fallingTrack.IsPlaying then
--		fallingTrack:Stop(0.1)
--	end
--end


local function onArenaDrop(action, duration)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then return end

	if action == "Land" then
		dropToken += 1
		--stopFalling()

		if not landingTrack or landingTrack.Parent ~= animator then
			landingTrack = loadTrack(animator, LANDING_ANIMATION_ID, Enum.AnimationPriority.Action4, false)
		end
		landingTrack:Play(0.05)
		shakeCamera(0.35, 4)

	elseif action == "Cancel" then
		dropToken += 1
		--stopFalling()
	end
end


function MatchController.Init()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	countdownUI = playerGui:WaitForChild("MainGui"):WaitForChild("CountdownFrame")
	countdownImage = countdownUI:WaitForChild("Image")
	countdownSound = SoundService:WaitForChild("SFX"):WaitForChild("ArenaCountdown")

	countdownUI.Visible = false

	UpdateGameStateEvent.OnClientEvent:Connect(onGameStateUpdated)
	PlayLoserSoundEvent.OnClientEvent:Connect(function()
		gameOver:Play()
	end)
	ArenaDropEvent.OnClientEvent:Connect(onArenaDrop)
end

return MatchController