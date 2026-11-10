-- KOController (ModuleScript, client) - SLIDE VERSION
-- Same folder as CombatController / GameplayController.
-- Usage: KOController.Play()
--
-- Sequence (fighting-game style):
--   1. Cinematic bars + DimFrame slide in, speed lines streak across
--   2. Left half of the logo slides in from the left, right half from the right
--   3. They SLAM together in the middle -> FlashFrame, lens streak, sparks, shake, blur
--   4. Slow cinematic zoom while held
--   5. Halves slide back out to their sides

local KOController = {}

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

local Gameplay = require(script.Parent:WaitForChild("GameplayController"))
local player = Players.LocalPlayer :: Player

-- ==========================================
-- SETTINGS (tweak the feel here)
-- ==========================================
local LOGO_POS = UDim2.fromScale(0.5, 0.42)
local SLIDE_IN = 0.2        -- time for the halves to fly in (shorter = more violent)
local HOLD_TIME = 1.8       -- time the KO stays on screen after impact
local SLIDE_OUT = 0.28
local BAR_HEIGHT = 0.12     -- cinematic bars (screen scale)
local DIM = 0.55            -- background darkness (0 = black, 1 = none)
local SPEED_LINES = 16
local SPARKS = 30
local BLUR_PEAK = 24
local SPARK_MIN_TIME = 0.75
local SPARK_MAX_TIME = 1
local COLORS = {
	Color3.fromRGB(255, 70, 30),
	Color3.fromRGB(255, 160, 20),
	Color3.fromRGB(255, 235, 60),
	Color3.new(1, 1, 1),
}

local KO_SOUND_NAME = "KO" -- put this line near the other settings at the top of KOController



-- ==========================================
-- STATE
-- ==========================================
local initialized = false
local playing = false
local token = 0
local baseScale = 1

local PlayerGui = player.PlayerGui
local KOGui = PlayerGui:WaitForChild("KOFx")
local DimFrame = KOGui.Dim
local BarTop = KOGui.BarTop
local BarBottom = KOGui.BarBottom
local FlashFrame = KOGui.Flash
local FXLayer = KOGui.FxLayer
local KOHolder = KOGui.KOHolder
local HolderScale = KOHolder.HolderScale
local LeftHalf = KOHolder.LeftHalf
local RightHalf = KOHolder.RightHalf

local function tween(obj: Instance, t: number?, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tween = TweenService:Create(obj, TweenInfo.new(t or 0, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

local function viewport()
	local cam = Workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

local function makeFrame(name, parent, z)
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 1
	f.ZIndex = z
	f.Parent = parent
	return f
end

-- ==========================================
-- INIT: own overlay, independent from HUD layout
-- ==========================================
function KOController.Init()
	if initialized then return end
	initialized = true

	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.J and UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) then
			KOController.Play()
		end
	end)
end

-- ==========================================
-- EFFECT PIECES
-- ==========================================
local function speedLines()
	local vp = viewport()
	local band0, band1 = vp.Y * 0.25, vp.Y * 0.6
	for i = 1, SPEED_LINES do
		local fromLeft = i % 2 == 0
		local len = math.random(350, 800) * baseScale
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(fromLeft and 1 or 0, 0.5)
		line.Size = UDim2.fromOffset(len, math.random(2, 5))
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BackgroundTransparency = 0.15
		line.BorderSizePixel = 0
		line.ZIndex = 8
		local y = math.random(band0, band1)
		line.Position = UDim2.fromOffset(fromLeft and -50 or vp.X + 50, y)
		line.Parent = FXLayer
		local t = SLIDE_IN * (0.9 + math.random() * 0.4)
		tween(line, t, { Position = UDim2.fromOffset(fromLeft and vp.X * 0.55 or vp.X * 0.45, y) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(t * 0.6, function()
			if line.Parent then tween(line, t, { BackgroundTransparency = 1 }) end
		end)
		Debris:AddItem(line, t * 2)
	end
end

local function lensStreak()
	local vp = viewport()
	local streak = Instance.new("Frame")
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Position = LOGO_POS
	streak.Size = UDim2.fromOffset(0, 14)
	streak.BackgroundColor3 = Color3.fromRGB(255, 245, 200)
	streak.BorderSizePixel = 0
	streak.ZIndex = 9
	streak.Parent = FXLayer
	tween(streak, 0.35, { Size = UDim2.fromOffset(vp.X * 1.3, 2), BackgroundTransparency = 1 }, Enum.EasingStyle.Quart)
	Debris:AddItem(streak, 0.4)
end

local function sparks()
	local vp = viewport()
	local origin = Vector2.new(vp.X * LOGO_POS.X.Scale, vp.Y * LOGO_POS.Y.Scale)
	for _ = 1, SPARKS do
		local size = math.random(8, 16)
		local p = Instance.new("Frame")
		p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Size = UDim2.fromOffset(size, size)
		p.Rotation = 45
		p.Position = UDim2.fromOffset(origin.X, origin.Y)
		p.BackgroundColor3 = COLORS[math.random(#COLORS)]
		p.BorderSizePixel = 0
		p.ZIndex = 9
		p.Parent = FXLayer

		-- mostly horizontal, like the two halves bursting apart
		local side = math.random() < 0.5 and -1 or 1
		local ang = math.rad(math.random(-35, 35))
		local dist = math.random(250, 800) * baseScale
		local target = origin + Vector2.new(math.cos(ang) * dist * side, math.sin(ang) * dist)
		local t = math.lerp(SPARK_MIN_TIME, SPARK_MAX_TIME, math.random())
		tween(p, t, { Position = UDim2.fromOffset(target.X, target.Y), Rotation = 45 + math.random(-300, 300) }, Enum.EasingStyle.Quart)
		tween(p, t, { BackgroundTransparency = 1, Size = UDim2.fromOffset(2, 2) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(p, t + 0.1)
	end
end

local function blurPulse()
	local blur = Lighting:FindFirstChild("Blur")
	if blur and blur:IsA("BlurEffect") then
		local originalSize, originalEnabled = blur.Size, blur.Enabled
		blur.Enabled = true
		tween(blur, 0.05, { Size = BLUR_PEAK })
		task.delay(0.5, function()
			local t = tween(blur, 0.6, { Size = originalSize })
			t.Completed:Once(function() blur.Enabled = originalEnabled end)
		end)
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Contrast = 0.35
	cc.Saturation = 0.5
	cc.Brightness = 0.1
	cc.Parent = Lighting
	tween(cc, 0.7, { Contrast = 0, Saturation = 0, Brightness = 0 })
	Debris:AddItem(cc, 0.8)
end

local function shakeHolder(duration, amplitude)
	local start = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local a = (os.clock() - start) / duration
		if a >= 1 or not KOHolder.Parent then
			KOHolder.Position = LOGO_POS
			conn:Disconnect()
			return
		end
		local amp = amplitude * (1 - a) ^ 2
		KOHolder.Position = LOGO_POS + UDim2.fromOffset((math.random() - 0.5) * 2 * amp, (math.random() - 0.5) * 2 * amp * 0.6)
	end)
end

local function impact()
	FlashFrame.BackgroundTransparency = 0.1
	tween(FlashFrame, 0.3, { BackgroundTransparency = 1 })
	pcall(Gameplay.TriggerPresetShake, "Bump")
	shakeHolder(0.4, 26)
	lensStreak()
	sparks()
	blurPulse()
	-- quick punch (snaps back fast so it reads as an impact, not a bounce)
	HolderScale.Scale = baseScale * 1.12
	tween(HolderScale, 0.18, { Scale = baseScale }, Enum.EasingStyle.Quart)
	local sfx = SoundService:FindFirstChild("SFX")
	local hit = sfx and sfx:FindFirstChild("KOImpact") -- optional Sound in SoundService.SFX
	if hit and hit:IsA("Sound") then hit:Play() end
end

-- ==========================================
-- PUBLIC
-- ==========================================
function KOController.Play(): Sound?
	KOController.Init()
	if playing then return nil end

	local sfx = SoundService:FindFirstChild("SFX")
	local yay = sfx and sfx:FindFirstChild("Yay")
	if yay and yay:IsA("Sound") then yay:Stop() end

	-- KO sound plays immediately, together with the slide-in
	local koSound = sfx and sfx:FindFirstChild(KO_SOUND_NAME)
	if koSound and koSound:IsA("Sound") then koSound:Play() else koSound = nil end

	playing = true
	token += 1
	local myToken = token

	local vp = viewport()
	baseScale = math.clamp(vp.X / 1400, 0.5, 1)
	HolderScale.Scale = baseScale
	local off = vp.X / baseScale -- far enough to start/finish fully off-screen

	if not FlashFrame then
		FlashFrame = makeFrame("Flash", KOGui, 20)
		FlashFrame.Size = UDim2.fromScale(1, 1)
		FlashFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	end
	FlashFrame.BackgroundTransparency = 1

	KOHolder.Position = LOGO_POS
	LeftHalf.Position = UDim2.new(0, -off, 0, 0)
	RightHalf.Position = UDim2.new(0.5, off, 0, 0)
	LeftHalf.Image.ImageTransparency = 0
	RightHalf.Image.ImageTransparency = 0
	KOHolder.Visible = true

	task.spawn(function()
		-- 1) Cinematic bars + DimFrame in
		tween(BarTop, 0.15, { Position = UDim2.fromScale(0, 0) })
		tween(BarBottom, 0.15, { Position = UDim2.fromScale(0, 1 - BAR_HEIGHT) })
		tween(DimFrame, 0.15, { BackgroundTransparency = DIM })
		speedLines()

		-- 2) Halves fly in (accelerate, then stop dead = impact)
		tween(LeftHalf, SLIDE_IN, { Position = UDim2.fromScale(0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local last = tween(RightHalf, SLIDE_IN, { Position = UDim2.fromScale(0.5, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		last.Completed:Wait()
		if myToken ~= token then return end

		-- 3) SLAM
		impact()
		task.wait(0.2)
		if myToken ~= token then return end

		-- 4) Slow cinematic push-in while holding
		tween(HolderScale, HOLD_TIME, { Scale = baseScale * 1.07 }, Enum.EasingStyle.Linear)
		task.wait(HOLD_TIME)
		if myToken ~= token then return end

		-- 5) Slide out to the sides
		tween(LeftHalf.Image, SLIDE_OUT, {ImageTransparency = 1})
		tween(RightHalf.Image, SLIDE_OUT, {ImageTransparency = 1})
		-- tween(LeftHalf, SLIDE_OUT, { Position = UDim2.new(0, -off, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		-- tween(RightHalf, SLIDE_OUT, { Position = UDim2.new(0.5, off, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(BarTop, SLIDE_OUT, { Position = UDim2.fromScale(0, -BAR_HEIGHT) })
		tween(BarBottom, SLIDE_OUT, { Position = UDim2.fromScale(0, 1) })
		tween(DimFrame, SLIDE_OUT, { BackgroundTransparency = 1 })
		task.wait(SLIDE_OUT + 0.05)

		KOHolder.Visible = false
		playing = false
	end)

	return koSound -- CombatController waits for this sound before GameWin
end


return KOController