-- KOController (ModuleScript, client) - SLIDE VERSION
-- Same folder as CombatController / GameplayController.
-- Usage: KOController.Play()
--
-- Sequence (fighting-game style):
--   1. Cinematic bars + dim slide in, speed lines streak across
--   2. Left half of the logo slides in from the left, right half from the right
--   3. They SLAM together in the middle -> flash, lens streak, sparks, shake, blur
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
local player = Players.LocalPlayer

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

local fxGui, dim, barTop, barBottom, flash, fxLayer
local holder, holderScale, leftClip, rightClip

local function tween(obj, time, props, style, dir)
	local t = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
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

	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui")
	local koFrame = mainGui:WaitForChild("HUD"):WaitForChild("KoFrame")
	local koLogo = koFrame:WaitForChild("KoLogo") :: ImageLabel
	koFrame.Visible = false -- hide the editor copy

	local abs = koLogo.AbsoluteSize
	local logoSize = (abs.X > 10 and abs.Y > 10) and UDim2.fromOffset(abs.X, abs.Y) or UDim2.fromOffset(455, 300)

	fxGui = Instance.new("ScreenGui")
	fxGui.Name = "KOFx"
	fxGui.ResetOnSpawn = false
	fxGui.IgnoreGuiInset = true
	fxGui.DisplayOrder = 50
	fxGui.ScreenInsets = Enum.ScreenInsets.None
	fxGui.Parent = playerGui

	dim = makeFrame("Dim", fxGui, 1)
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)

	barTop = makeFrame("BarTop", fxGui, 2)
	barTop.Size = UDim2.fromScale(1, BAR_HEIGHT)
	barTop.Position = UDim2.fromScale(0, -BAR_HEIGHT)
	barTop.BackgroundColor3 = Color3.new(0, 0, 0)
	barTop.BackgroundTransparency = 0

	barBottom = makeFrame("BarBottom", fxGui, 2)
	barBottom.Size = UDim2.fromScale(1, BAR_HEIGHT)
	barBottom.Position = UDim2.fromScale(0, 1)
	barBottom.BackgroundColor3 = Color3.new(0, 0, 0)
	barBottom.BackgroundTransparency = 0

	fxLayer = makeFrame("FxLayer", fxGui, 5)
	fxLayer.Size = UDim2.fromScale(1, 1)

	-- Logo is split into two clipped halves; each half holds the FULL image,
	-- so it works for any image size/aspect ratio.
	holder = makeFrame("KOHolder", fxGui, 10)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = LOGO_POS
	holder.Size = logoSize
	holder.Visible = false
	holderScale = Instance.new("UIScale")
	holderScale.Parent = holder

	local function half(name, isLeft)
		local clip = makeFrame(name, holder, 10)
		clip.ClipsDescendants = true
		clip.Size = UDim2.fromScale(0.5, 1)
		clip.Position = isLeft and UDim2.fromScale(0, 0) or UDim2.fromScale(0.5, 0)
		local img = Instance.new("ImageLabel")
		img.Name = "Image"
		img.Image = koLogo.Image
		img.ImageColor3 = koLogo.ImageColor3
		img.BackgroundTransparency = 1
		img.ZIndex = 10
		img.Size = UDim2.fromScale(2, 1)
		img.Position = isLeft and UDim2.fromScale(0, 0) or UDim2.fromScale(-1, 0)
		img.Parent = clip
		return clip
	end
	leftClip = half("LeftHalf", true)
	rightClip = half("RightHalf", false)

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
		line.Parent = fxLayer
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
	streak.Parent = fxLayer
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
		p.Parent = fxLayer

		-- mostly horizontal, like the two halves bursting apart
		local side = math.random() < 0.5 and -1 or 1
		local ang = math.rad(math.random(-35, 35))
		local dist = math.random(250, 800) * baseScale
		local target = origin + Vector2.new(math.cos(ang) * dist * side, math.sin(ang) * dist)
		local t = math.random(35, 70) / 100
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
		if a >= 1 or not holder.Parent then
			holder.Position = LOGO_POS
			conn:Disconnect()
			return
		end
		local amp = amplitude * (1 - a) ^ 2
		holder.Position = LOGO_POS + UDim2.fromOffset((math.random() - 0.5) * 2 * amp, (math.random() - 0.5) * 2 * amp * 0.6)
	end)
end

local function impact()
	flash.BackgroundTransparency = 0.1
	tween(flash, 0.3, { BackgroundTransparency = 1 })
	pcall(Gameplay.TriggerPresetShake, "Bump")
	shakeHolder(0.4, 26)
	lensStreak()
	sparks()
	blurPulse()
	-- quick punch (snaps back fast so it reads as an impact, not a bounce)
	holderScale.Scale = baseScale * 1.12
	tween(holderScale, 0.18, { Scale = baseScale }, Enum.EasingStyle.Quart)
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
	holderScale.Scale = baseScale
	local off = vp.X / baseScale -- far enough to start/finish fully off-screen

	if not flash then
		flash = makeFrame("Flash", fxGui, 20)
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = Color3.new(1, 1, 1)
	end
	flash.BackgroundTransparency = 1

	holder.Position = LOGO_POS
	leftClip.Position = UDim2.new(0, -off, 0, 0)
	rightClip.Position = UDim2.new(0.5, off, 0, 0)
	holder.Visible = true

	task.spawn(function()
		-- 1) Cinematic bars + dim in
		tween(barTop, 0.15, { Position = UDim2.fromScale(0, 0) })
		tween(barBottom, 0.15, { Position = UDim2.fromScale(0, 1 - BAR_HEIGHT) })
		tween(dim, 0.15, { BackgroundTransparency = DIM })
		speedLines()

		-- 2) Halves fly in (accelerate, then stop dead = impact)
		tween(leftClip, SLIDE_IN, { Position = UDim2.fromScale(0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local last = tween(rightClip, SLIDE_IN, { Position = UDim2.fromScale(0.5, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		last.Completed:Wait()
		if myToken ~= token then return end

		-- 3) SLAM
		impact()
		task.wait(0.2)
		if myToken ~= token then return end

		-- 4) Slow cinematic push-in while holding
		tween(holderScale, HOLD_TIME, { Scale = baseScale * 1.07 }, Enum.EasingStyle.Linear)
		task.wait(HOLD_TIME)
		if myToken ~= token then return end

		-- 5) Slide out to the sides
		tween(leftClip, SLIDE_OUT, { Position = UDim2.new(0, -off, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(rightClip, SLIDE_OUT, { Position = UDim2.new(0.5, off, 0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(barTop, SLIDE_OUT, { Position = UDim2.fromScale(0, -BAR_HEIGHT) })
		tween(barBottom, SLIDE_OUT, { Position = UDim2.fromScale(0, 1) })
		tween(dim, SLIDE_OUT, { BackgroundTransparency = 1 })
		task.wait(SLIDE_OUT + 0.05)

		holder.Visible = false
		playing = false
	end)

	return koSound -- CombatController waits for this sound before GameWin
end


return KOController