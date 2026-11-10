--!nonstrict
--[[
	LOADING SCREEN (LocalScript - ReplicatedFirst)

	Features:
	  * Shows the "FreeFall" diver with the player's avatar and fall animation.
	  * Wind looping sound and particle effects during the dive.
	  * Plays LoadingIntro upon entry and Finish when loading completes.
	  * Gentle camera shake while falling, followed by a smooth cinematic reveal.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local StarterPlayer = game:GetService("StarterPlayer")

local sfxFolder = SoundService:WaitForChild("SFX")
local uiSelectSound = sfxFolder.UISelect
local gameWinSound = sfxFolder.GameWin
local smashSound = SoundService:WaitForChild("Effects").Rock:Clone()
smashSound.Volume = 1
-- ==========================================
-- CONFIG
-- ==========================================
local CONFIG = {
	FALL_ANIMATION_ID = "rbxassetid://128339318858014",
	LANDING_ANIMATION_ID = "rbxassetid://98548063446402",
	MIN_DURATION = 6,        -- the bar never fills faster than this (seconds)
	MAX_DURATION = 45,       -- safety: force-finish after this long
	ASSET_TIMEOUT = 15,      -- stop waiting for asset preloading after this long
	AVATAR_TIMEOUT = 4,      -- max time to wait for the player's avatar before revealing
	CHARACTER_TIMEOUT = 8,   -- max time to wait for the real character once the game is ready
	PRELOAD_LIMIT = 3000,

	-- intro
	COVER_FADE_TIME = 1.0,
	INTRO_CAM_TIME = 2.4,
	INTRO_FOV_BOOST = 0,

	-- camera feel (softened for a smooth drift rather than violent jitter)
	SHAKE_IDLE = 0.18,          -- reduced from 0.5
	SHAKE_PER_PROGRESS = 0.35,  -- reduced from 1.0
	SHAKE_PLUNGE = 3.0,         -- reduced from 9.0

	-- audio settings
	WIND_BASE_VOLUME = 0.5,
	WIND_BOOST_VOLUME = 0.6,
	WIND_PEAK_VOLUME = 3,
	INTRO_VOLUME = 0.5,
	FINISH_VOLUME = 0.5,

	-- exit
	SWING_TIME = 1.1,
	PLUNGE_TIME = 1.0,
	PLUNGE_DISTANCE = 110,
	PLUNGE_FOV = 128,
	BLUR_PEAK = 30,
	WIND_BOOST_RATE = 70,
	WIND_BOOST_SPEED = 3,
}

local PRELOAD_CLASSES = {
	MeshPart = true, Decal = true, Texture = true, Sound = true, Animation = true,
	ParticleEmitter = true, SurfaceAppearance = true, ImageLabel = true, ImageButton = true,
	Sky = true, SpecialMesh = true, Shirt = true, Pants = true, ShirtGraphic = true,
	Beam = true, Trail = true,
}

local RENDER_NAME = "LoadingScreenCamera"
local SINK_NAME = "LoadingScreenSink"

-- ==========================================
-- HELPERS
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function animate(duration, style, direction, step)
	local startTime = os.clock()
	while true do
		local alpha = math.clamp((os.clock() - startTime) / duration, 0, 1)
		step(TweenService:GetValue(alpha, style, direction))
		if alpha >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
end

-- ==========================================
-- SOUND SETUP (SoundService.LoadingScreen)
-- ==========================================
local loadingSoundsFolder = SoundService:WaitForChild("LoadingScreen", 5)

local introSound, finishSound, windSound
if loadingSoundsFolder then
	local introTemplate = loadingSoundsFolder:FindFirstChild("LoadingIntro")
	if introTemplate then
		introSound = introTemplate:Clone()
		introSound.Volume = CONFIG.INTRO_VOLUME
		introSound.Parent = SoundService
	end

	--local finishTemplate = loadingSoundsFolder:FindFirstChild("Finish")
	--if finishTemplate then
	--	finishSound = finishTemplate:Clone()
	--	finishSound.Volume = CONFIG.FINISH_VOLUME
	--	finishSound.Parent = SoundService
	--end

	local windTemplate = loadingSoundsFolder:FindFirstChild("Wind")
	if windTemplate then
		windSound = windTemplate:Clone()
		windSound.Looped = true
		windSound.Volume = 0
		windSound.PlaybackSpeed = 1
		windSound.Parent = SoundService
	end
end

-- ==========================================
-- UI SETUP
-- ==========================================
local template = script.Parent:WaitForChild("Loading")
local loadingUI = template:Clone()
loadingUI.DisplayOrder = 1000
loadingUI.IgnoreGuiInset = true
loadingUI.ResetOnSpawn = false
loadingUI.Enabled = true

local frame = loadingUI.Frame
local slider = frame.SliderFrame
local fill = slider.FillFrame
local sliderStroke = slider:FindFirstChildOfClass("UIStroke")
local skipButton = frame:FindFirstChild("Skip")

local cover = Instance.new("Frame")
cover.Name = "Cover"
cover.Size = UDim2.fromScale(1, 1)
cover.BackgroundColor3 = Color3.new(0, 0, 0)
cover.BorderSizePixel = 0
cover.ZIndex = 100
cover.Parent = loadingUI

local frameHome = frame.Position
local frameOff = UDim2.new(frameHome.X.Scale, frameHome.X.Offset, 1.8, 0)
frame.Position = frameOff

local fillSize = fill.Size
fill.Size = UDim2.new(0, 0, fillSize.Y.Scale, fillSize.Y.Offset)

local skipTextHome = skipButton and skipButton.TextTransparency or 0
if skipButton then
	skipButton.TextTransparency = 1
end

loadingUI.Parent = PlayerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

-- ==========================================
-- HIDE THE GAME'S OTHER GUIS WHILE LOADING
-- ==========================================
local suppressed = {}
local suppressing = true

local function suppress(gui)
	if suppressed[gui] or gui == loadingUI or not gui:IsA("ScreenGui") then
		return
	end
	local state = { enabled = gui.Enabled }
	suppressed[gui] = state
	gui.Enabled = false
	state.conn = gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if suppressing and gui.Enabled then
			state.enabled = true
			gui.Enabled = false
		end
	end)
end

for _, gui in ipairs(PlayerGui:GetChildren()) do
	suppress(gui)
end
local guiAddedConn = PlayerGui.ChildAdded:Connect(suppress)

local function restoreGuis()
	suppressing = false
	guiAddedConn:Disconnect()
	for gui, state in pairs(suppressed) do
		if state.conn then
			state.conn:Disconnect()
		end
		if gui.Parent then
			gui.Enabled = state.enabled
		end
	end
	table.clear(suppressed)
end

-- Block movement/jump while screen is active
ContextActionService:BindActionAtPriority(SINK_NAME, function()
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value,
Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
Enum.KeyCode.Space, Enum.KeyCode.Thumbstick1)

-- ==========================================
-- CAMERA (Smooth freefall drift)
-- ==========================================
local camera = workspace.CurrentCamera
while not camera do
	task.wait()
	camera = workspace.CurrentCamera
end
local gameFOV = camera.FieldOfView

local camMain = script.Parent:WaitForChild("Camera-main")
local camBack = script.Parent:WaitForChild("Camera-back", 5)
local mainCF, mainFOV = camMain.CFrame, camMain.FieldOfView
local backCF = camBack and camBack.CFrame or mainCF

local camState = {
	cf = backCF,
	fov = mainFOV + CONFIG.INTRO_FOV_BOOST,
	shake = CONFIG.SHAKE_IDLE,
}

RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, function()
	local t = os.clock() * (1 + camState.shake * 0.25)
	local s = camState.shake
	local rot = CFrame.Angles(
		math.noise(t * 0.7, 1.3) * 0.012 * s,
		math.noise(t * 0.6, 7.7) * 0.012 * s,
		math.noise(t * 0.8, 3.1) * 0.008 * s
	)
	local pos = Vector3.new(
		math.noise(t * 0.9, 2.2),
		math.noise(t * 0.8, 9.1),
		math.noise(t * 1.0, 5.5)
	) * 0.06 * s

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = camState.cf * CFrame.new(pos) * rot
	camera.FieldOfView = camState.fov
end)

-- ==========================================
-- SCENE
-- ==========================================
local scene = script.Parent:WaitForChild("LoadingScreen"):Clone()
scene.Name = "ActiveLoadingScene"
local placeholder = scene:WaitForChild("FreeFall")
local wind = scene:FindFirstChild("Wind")
local windEmitter = wind and wind:FindFirstChildOfClass("ParticleEmitter")
local diverHome = placeholder:GetPivot()

local animSaves = placeholder:FindFirstChild("AnimSaves")
local fallbackSequence = animSaves and animSaves:FindFirstChild("FallDive")
fallbackSequence = fallbackSequence and fallbackSequence:Clone()

local diver = placeholder
scene.Parent = workspace

local function buildAvatar()
	local ok, result = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserIdAsync(LocalPlayer.UserId)
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if not ok or typeof(result) ~= "Instance" then
		warn("[LoadingScreen] Could not build avatar, using default model:", result)
		return nil
	end

	local model = result
	model.Name = "FreeFall"
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		model:Destroy()
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	pcall(function()
		humanoid.EvaluateStateMachine = false
	end)
	root.Anchored = true
	model:PivotTo(diverHome)
	return model
end

local function startFallAnimation(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)

	local function tryLoad(animationId)
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok or not track then return nil end
		local waited = os.clock()
		while track.Length == 0 and os.clock() - waited < 3 do
			task.wait()
		end
		if track.Length == 0 then
			track:Destroy()
			return nil
		end
		return track
	end

	local track = tryLoad(CONFIG.FALL_ANIMATION_ID)
	if not track and fallbackSequence then
		local ok, contentId = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(fallbackSequence)
		end)
		if ok and contentId then
			track = tryLoad(contentId)
		end
	end

	if track then
		track.Priority = Enum.AnimationPriority.Action4
		track.Looped = true
		track:Play(0)
	else
		warn("[LoadingScreen] Fall animation failed to load:", CONFIG.FALL_ANIMATION_ID)
	end
end
local function playLandingAnimation()
	local character = LocalPlayer.Character
	if not character then
		character = LocalPlayer.CharacterAdded:Wait()
	end

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
		or Instance.new("Animator", humanoid)

	local animation = Instance.new("Animation")
	animation.AnimationId = CONFIG.LANDING_ANIMATION_ID

	local success, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if success and track then
		track.Priority = Enum.AnimationPriority.Action4
		track.Looped = false
		track:Play(0.05)
	else
		warn("[LoadingScreen] Failed to load landing animation")
	end

	animation:Destroy()
end

local builderDone = false
task.spawn(function()
	local model = buildAvatar()
	if model then
		placeholder:Destroy()
		model.Parent = scene
		diver = model
	end
	startFallAnimation(diver)
	builderDone = true
end)

-- ==========================================
-- PROGRESS SOURCES
-- ==========================================
local assetsFrac, assetsDone = 0, false

task.spawn(function()
	pcall(function()
		if not game:IsLoaded() then
			game.Loaded:Wait()
		end
		local list = {}
		local function collect(root)
			for _, descendant in ipairs(root:GetDescendants()) do
				if #list >= CONFIG.PRELOAD_LIMIT then return end
				if PRELOAD_CLASSES[descendant.ClassName]
					and not descendant:IsDescendantOf(scene)
					and not descendant:IsDescendantOf(loadingUI) then
					table.insert(list, descendant)
				end
			end
		end
		collect(workspace)
		collect(ReplicatedStorage)
		collect(Lighting)
		collect(PlayerGui)

		local total = #list
		if total > 0 then
			local completed = 0
			ContentProvider:PreloadAsync(list, function()
				completed += 1
				assetsFrac = completed / total
			end)
		end
	end)
	assetsFrac, assetsDone = 1, true
end)

local skipRequested = false
if skipButton then
	skipButton.Activated:Connect(function()
		skipRequested = true
	end)
end

-- ==========================================
-- CLEANUP
-- ==========================================
local function fullCleanup()
	restoreGuis()
	pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
	pcall(function() ContextActionService:UnbindAction(SINK_NAME) end)

	if introSound then introSound:Stop(); introSound:Destroy() end
	if uiSelectSound then uiSelectSound:Stop() end
	if gameWinSound then gameWinSound:Stop() end
	--if finishSound then finishSound:Stop(); finishSound:Destroy() end
	if windSound then windSound:Stop(); windSound:Destroy() end
	if scene then scene:Destroy() end
	if blur then blur:Destroy() end

	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = gameFOV
	loadingUI:Destroy()
end

-- ==========================================
-- MAIN
-- ==========================================
local function run()
	local waitStart = os.clock()
	while not builderDone and os.clock() - waitStart < CONFIG.AVATAR_TIMEOUT do
		task.wait()
	end

	-- ---------- INTRO ----------
	local revealClock = os.clock()
	local introDone = false

	-- Start intro audio and looping wind sound
	if introSound then
		introSound:Play()
	end
	if windSound then
		windSound:Play()
		TweenService:Create(windSound, TweenInfo.new(CONFIG.COVER_FADE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
			Volume = CONFIG.WIND_BASE_VOLUME
		}):Play()
	end

	task.spawn(function()
		animate(CONFIG.COVER_FADE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, function(a)
			cover.BackgroundTransparency = a
		end)
		cover:Destroy()
	end)

	task.spawn(function()
		local startFOV = mainFOV + CONFIG.INTRO_FOV_BOOST
		animate(CONFIG.INTRO_CAM_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, function(a)
			camState.cf = backCF:Lerp(mainCF, a)
			camState.fov = lerp(startFOV, mainFOV, a)
		end)
		introDone = true
	end)

	task.delay(0.9, function()
		TweenService:Create(frame, TweenInfo.new(0.9, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = frameHome }):Play()
		if skipButton then
			TweenService:Create(skipButton, TweenInfo.new(0.6), { TextTransparency = skipTextHome }):Play()
		end
	end)

	-- ---------- LOADING LOOP ----------
	local shown = 0
	local gameReadyClock
	while true do
		local dt = RunService.RenderStepped:Wait()
		local now = os.clock()
		local elapsed = now - revealClock

		local clientProgress = loadingUI:GetAttribute("Progress") or 0
		local gameReady = loadingUI:GetAttribute("GameReady") == true
		if gameReady and not gameReadyClock then
			gameReadyClock = now
		end

		local character = LocalPlayer.Character
		local charReady = (character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil)
			or (gameReadyClock ~= nil and now - gameReadyClock > CONFIG.CHARACTER_TIMEOUT)
		local assetsOk = assetsDone or elapsed > CONFIG.ASSET_TIMEOUT

		local real = 0.1 * (game:IsLoaded() and 1 or 0)
			+ 0.2 * (assetsOk and 1 or assetsFrac)
			+ 0.6 * (gameReady and 1 or clientProgress)
			+ 0.1 * (charReady and 1 or 0)

		local target = math.min(real, elapsed / CONFIG.MIN_DURATION)
		if skipRequested or elapsed > CONFIG.MAX_DURATION then
			target = 1
		end

		local speed = skipRequested and 14 or 5
		shown += (target - shown) * (1 - math.exp(-speed * dt))
		if target >= 0.999 and shown > 0.995 then
			shown = 1
		end

		fill.Size = UDim2.new(shown, 0, fillSize.Y.Scale, fillSize.Y.Offset)
		camState.shake = CONFIG.SHAKE_IDLE + shown * CONFIG.SHAKE_PER_PROGRESS

		if shown >= 1 then
			break
		end
	end

	-- ---------- EXIT ----------
	while not introDone do
		task.wait()
	end

	-- 1) Play Finish sound, fade out intro sound, pulse bar
	if gameWinSound and uiSelectSound then
		uiSelectSound:Play()
		uiSelectSound.Ended:Connect(function()
			gameWinSound:Play()
		end)
	end
	if introSound and introSound.IsPlaying then
		TweenService:Create(introSound, TweenInfo.new(CONFIG.SWING_TIME, Enum.EasingStyle.Sine), { Volume = 0 }):Play()
	end

	local pulse = Instance.new("UIScale")
	pulse.Parent = slider
	TweenService:Create(pulse, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true), { Scale = 1.1 }):Play()
	if sliderStroke then
		TweenService:Create(sliderStroke, TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true), {
			Color = Color3.new(1, 1, 1),
			Thickness = sliderStroke.Thickness * 4,
		}):Play()
	end
	if skipButton then
		skipButton.Active = false
		TweenService:Create(skipButton, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
	end
	task.wait(0.4)

	-- 2) Drop UI, accelerate wind sound and particles
	TweenService:Create(frame, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Position = frameOff }):Play()
	if windEmitter then
		windEmitter.Rate = CONFIG.WIND_BOOST_RATE
		local speedRange = windEmitter.Speed
		windEmitter.Speed = NumberRange.new(speedRange.Min * CONFIG.WIND_BOOST_SPEED, speedRange.Max * CONFIG.WIND_BOOST_SPEED)
	end
	if windSound then
		TweenService:Create(windSound, TweenInfo.new(CONFIG.SWING_TIME + CONFIG.PLUNGE_TIME + 1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Volume = CONFIG.WIND_PEAK_VOLUME,
			PlaybackSpeed = 2
		}):Play()
	end

	-- 3) Camera swings behind diver
	local swingFromCF, swingFromFOV, swingFromShake = camState.cf, camState.fov, camState.shake
	local swingFOV = mainFOV + 12

	animate(CONFIG.SWING_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut, function(a)
		camState.cf = swingFromCF:Lerp(backCF, a)
		camState.fov = lerp(swingFromFOV, swingFOV, a)
		camState.shake = lerp(swingFromShake, 1.2, a)
	end)

	-- 4) Cinematic plunge (no glass/shatter transition)
	blur = Instance.new("BlurEffect")
	blur.Name = "LoadingScreenBlur"
	blur.Size = 0
	blur.Parent = Lighting

	local plungeDir = backCF.LookVector
	local diverBase = diver:GetPivot()
	local cinematicFrame = loadingUI.Cinematic
	animate(CONFIG.PLUNGE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In, function(a)
		local offset = plungeDir * (CONFIG.PLUNGE_DISTANCE * a)
		camState.cf = backCF + offset
		diver:PivotTo(diverBase + offset)
		camState.fov = lerp(swingFOV, CONFIG.PLUNGE_FOV, a)
		camState.shake = lerp(1.2, CONFIG.SHAKE_PLUNGE, a)
		if blur and blur.Parent then
			blur.Size = CONFIG.BLUR_PEAK * a
		end
		cinematicFrame.Up.Position = UDim2.fromScale(0.5, a * 0.5)
		cinematicFrame.Down.Position = UDim2.fromScale(0.5, 1 - a * 0.5)
	end)

	-- 5) Switch to the real character
	LocalPlayer:SetAttribute("LoadingFinished", true)
	RunService:UnbindFromRenderStep(RENDER_NAME)
	ContextActionService:UnbindAction(SINK_NAME)
	if scene then
		scene:Destroy()
		scene = nil
	end

	restoreGuis()

	camera.CameraType = Enum.CameraType.Custom
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	camera.FieldOfView = CONFIG.PLUNGE_FOV

	-- Play landing as the loading screen starts revealing the game
	task.spawn(function()
		playLandingAnimation()
	end)

	-- 6) Smoothly restore the normal camera and fade out the blur
	local blurEffect = blur
	local revealDuration = 0.65
	local revealStartFOV = CONFIG.PLUNGE_FOV
	task.spawn(function()
		animate(revealDuration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, function(a)
			camera.FieldOfView = lerp(revealStartFOV, gameFOV, a)
			if blurEffect and blurEffect.Parent then
				blurEffect.Size = CONFIG.BLUR_PEAK * (1 - a)
			end
		end)
	end)

	task.wait(revealDuration)
	if blurEffect then
		blurEffect:Destroy()
	end
	blur = nil
	if windSound then
		windSound:Stop()
		windSound:Destroy()
		windSound = nil
	end
	if character then
		local SmashEffect = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers"):WaitForChild("CombatController"):WaitForChild("Smash"):WaitForChild("SmashEffect"))
		SmashEffect.Impact(character:GetPivot().Position - Vector3.new(0, 10, 0), 10, nil, true)
	end
	-- SoundService:PlayLocalSound(smashSound)
	animate(2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, function(a)
		local progress = 1 - a
		camera.FieldOfView = lerp(30, 70, a)
		cinematicFrame.Up.Position = UDim2.fromScale(0.5, progress * 0.5)
		cinematicFrame.Down.Position = UDim2.fromScale(0.5, 1 - progress * 0.5)
	end)

	loadingUI:Destroy()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	warn("[LoadingScreen] Failed, falling back to the game:\n" .. tostring(err))
	fullCleanup()
end