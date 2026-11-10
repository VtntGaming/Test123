-- TimeStopEffect (CLIENT ModuleScript) V3 -> CombatController.TimeStop.TimeStopEffect  (REPLACE the old one)
-- Same events as before: Init, Ready, Start, Mark, Hit, End, Cancel, CleanupCaster.
--   Ready  : telegraph (TimeReady sound fitted to ReadyTime, motes, light, slow FOV push-in)
--   Start  : flash, shockwave sphere, dimension FOV blast + camera shake, colour grade, frost on victims,
--            caster afterimages, world VFX frozen, arena music paused, 16s clock sound started
--   Mark/Hit: sparks + sound + tiny FOV/camera pulse. NO counter UI, NO ground circles anymore.
--   End    : (runs exactly once) collapse FOV + shake, resume sound, clock stopped, arena music resumed
--   Cancel : interrupted during the telegraph
-- Everything (FOV, shake, sounds, music, tweens, connections) is cleaned by End / Cancel / forceReset.

local TimeStopEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local TimeStopFreeze = require(script.Parent:WaitForChild("TimeStopFreeze"))

local localPlayer = Players.LocalPlayer

local CONFIG = {
	TINT = Color3.fromRGB(130, 175, 255),
	GOLD = Color3.fromRGB(255, 215, 90),
	FROST = Color3.fromRGB(190, 225, 255),

	AFTERIMAGE_COLORS = { Color3.fromRGB(90, 170, 255), Color3.fromRGB(255, 215, 90) },
	AFTERIMAGE_INTERVAL = 0.045,
	AFTERIMAGE_IDLE_INTERVAL = 0.22,
	AFTERIMAGE_LIFETIME = 0.55,
	AFTERIMAGE_MAX = 40,

	TITLE = "TIME STOP",
	SHOW_TITLE = false,
	SHOW_TIMER = true,
	FREEZE_VFX = true,

	-- audio
	CLOCK_SOUND = "ClockTickSound16Seconds",  -- inside SoundService.TimeStopSounds
	CLOCK_VOLUME = 10,
	MUSIC_PATH = { "Soundtrack", "ArenaTheme" }, -- paused during the stop, resumed afterwards

	-- FOV offsets in degrees, added on top of the camera's normal FOV
	FOV = {
		READY_ZOOM = -9,              -- slow push-in while the caster charges (caster)
		READY_ZOOM_OTHERS = -4,       -- everybody else in the match
		START_KICK = 38,              -- the instant time stops: the world tears open ...
		START_KICK_TIME = 0.12,
		STOP_HOLD = 12,               -- ... then settles wide and stays there for the whole stop
		STOP_SETTLE_TIME = 1.4,
		HIT_PULSE = -3,               -- every counted hit during the stop
		RESUME_PULL = -22,            -- time resumes: the dimension collapses (hard pull-in) ...
		RESUME_PULL_TIME = 0.08,
		RESUME_OVERSHOOT = 6,         -- ... slight overshoot outwards ...
		RESUME_OVERSHOOT_TIME = 0.25,
		RESUME_SETTLE_TIME = 0.8,     -- ... then back to the normal FOV
		FINISH_KICK = -8,             -- final barrage hit on the local victim
	},

	-- camera shake: magnitude (about degrees of rotation), seconds, roughness
	SHAKE = {
		START = { 5.5, 0.95, 22 },
		START_AFTER = { 2.5, 0.6, 30 },   -- second, smaller rumble right after
		END = { 6.5, 1.0, 24 },
		HIT = { 0.9, 0.15, 34 },
		VICTIM = { 3.0, 0.3, 30 },
	},
}

local activeCasters = {} -- [Player] = { clean = fn }
local stopped = nil      -- state of the current stop (nil = no stop on this client)
local readySound = nil
local clockSound = nil
local music = nil        -- { sound, wasPlaying, conn }
local colorCorrection = nil
local ghostCount = 0
local marks = {}         -- [actor] = { gui, label, scale, count }

-- ==========================================
-- CAMERA SHAKE (self-contained, additive, unbinds itself when empty)
-- ==========================================
local shakes = {}
local shakeBound = false

local function stepShake()
	local camera = Workspace.CurrentCamera
	if not camera then return end
	if #shakes == 0 then
		shakeBound = false
		RunService:UnbindFromRenderStep("TimeStopShake")
		return
	end
	local now = os.clock()
	local pos, rot = Vector3.zero, Vector3.zero
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		local alpha = (now - s.t0) / s.duration
		if alpha >= 1 then
			table.remove(shakes, i)
		else
			local attack = math.min(alpha / 0.06, 1)        -- hits hard immediately, no pop
			local fade = attack * (1 - alpha) ^ 2
			local n = now * s.roughness
			local nx, ny, nz = math.noise(n, s.seed, 0.5), math.noise(s.seed, n, 1.5), math.noise(n, n, s.seed)
			pos += Vector3.new(nx, ny, nz) * (s.magnitude * 0.2 * fade)
			rot += Vector3.new(ny, nx, nz) * (s.magnitude * 1.0 * fade)
		end
	end
	-- the default camera script rewrites CFrame every frame, so this offset never accumulates
	camera.CFrame = camera.CFrame * CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
end

local function addShake(preset)
	table.insert(shakes, { t0 = os.clock(), magnitude = preset[1], duration = preset[2], roughness = preset[3], seed = math.random() * 100 + 0.37 })
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep("TimeStopShake", Enum.RenderPriority.Camera.Value + 1, stepShake)
	end
end

-- ==========================================
-- FOV MANAGER (tweened offset added on top of the camera's FOV)
-- ==========================================
local fovOffset = Instance.new("NumberValue")
local fovTween = nil
local fovToken = 0
local fovBound = false
local fovBase, fovWritten = nil, nil

local function fovStep()
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local current = camera.FieldOfView
	if fovWritten == nil or math.abs(current - fovWritten) > 0.01 then fovBase = current end -- someone else moved it
	local playing = fovTween ~= nil and fovTween.PlaybackState == Enum.PlaybackState.Playing
	if math.abs(fovOffset.Value) < 0.01 and not playing then
		camera.FieldOfView = fovBase       -- back to exactly the original FOV
		fovOffset.Value = 0
		fovWritten = nil
		fovBound = false
		RunService:UnbindFromRenderStep("TimeStopFov")
		return
	end
	fovWritten = fovBase + fovOffset.Value
	camera.FieldOfView = fovWritten
end

local function fovTo(target, duration, style, direction)
	if fovTween then fovTween:Cancel() end
	if not fovBound then
		fovBound = true
		RunService:BindToRenderStep("TimeStopFov", Enum.RenderPriority.Camera.Value + 2, fovStep)
	end
	if duration <= 0 then
		fovOffset.Value = target
		fovTween = nil
		return
	end
	fovTween = TweenService:Create(fovOffset, TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), { Value = target })
	fovTween:Play()
end

-- steps = { { offset, seconds, style?, direction? }, ... } one after another; starting a new one cancels the old one
local function fovSequence(steps)
	fovToken += 1
	local token = fovToken
	task.spawn(function()
		for _, step in steps do
			if token ~= fovToken then return end
			fovTo(step[1], step[2], step[3], step[4])
			if step[2] > 0 then task.wait(step[2]) end
		end
	end)
end

local function fovPulse(amount)
	local hold = if stopped then CONFIG.FOV.STOP_HOLD else 0
	fovSequence({ { hold + amount, 0.03 }, { hold, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out } })
end

local function fovReset(duration)
	fovSequence({ { 0, duration or 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out } })
end

-- ==========================================
-- HELPERS
-- ==========================================
local function getFX()
	local folder = Workspace:FindFirstChild("TimeStopFX") -- ignored by TimeStopFreeze, so our own VFX keep running
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TimeStopFX"
		folder.Parent = Workspace
	end
	return folder
end

local function getRoot(target)
	if target:IsA("BasePart") then return target end
	return target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
end

local function findTimeSound(name)
	local folder = SoundService:FindFirstChild("TimeStopSounds")
	local sound = folder and folder:FindFirstChild(name) or SoundService:FindFirstChild(name, true)
	if sound and sound:IsA("Sound") then return sound end
	return nil
end

local function playTimeSound(name, volume, pitch)
	local source = findTimeSound(name)
	if not source then return nil end
	local s = source:Clone()
	s.Volume = volume or s.Volume
	s.PlaybackSpeed = pitch or 1
	s.Parent = SoundService
	s.Ended:Once(function() s:Destroy() end)
	s:Play()
	return s
end

local function playHitSound(volume, pitch)
	local source = SoundService:FindFirstChild("Rock", true)
	if source and source:IsA("Sound") then
		local s = source:Clone()
		s.PlaybackSpeed, s.Volume, s.Parent = pitch, volume, SoundService
		s.Ended:Once(function() s:Destroy() end)
		s:Play()
	end
end

local function getColorCorrection()
	if not colorCorrection or not colorCorrection.Parent then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "TimeStopInversion"
		colorCorrection.Parent = Lighting
	end
	return colorCorrection
end

local function newPart(position)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Transparency, part.Size, part.Position = 1, Vector3.one, position
	part.Parent = getFX()
	return part
end

local function burst(position, color, count, speed, size)
	local holder = newPart(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.3, 0.7)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	emitter.LightEmission = 1
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size or 1), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(holder, 1.5)
end

-- expanding sphere (time stops) / collapsing sphere (time resumes). No flat rings anywhere.
local function shockwave(position, radius)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored, ball.CanCollide, ball.CanTouch, ball.CanQuery, ball.CastShadow = true, false, false, false, false
	ball.Material, ball.Color, ball.Transparency = Enum.Material.Neon, CONFIG.TINT, 0.35
	ball.Size, ball.Position = Vector3.one * 4, position
	ball.Parent = getFX()
	TweenService:Create(ball, TweenInfo.new(0.9, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.one * math.min(radius, 120) * 2, Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 1)
end

local function collapse(position)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored, ball.CanCollide, ball.CanTouch, ball.CanQuery, ball.CastShadow = true, false, false, false, false
	ball.Material, ball.Color, ball.Transparency = Enum.Material.Neon, CONFIG.TINT, 0.85
	ball.Size, ball.Position = Vector3.one * 90, position
	ball.Parent = getFX()
	TweenService:Create(ball, TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
		Size = Vector3.one * 2, Transparency = 0.1,
	}):Play()
	Debris:AddItem(ball, 0.45)
end

local function flash(color, startTransparency, duration)
	local pGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pGui then return end
	local gui = Instance.new("ScreenGui")
	gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = true, false, 60
	gui.Parent = pGui
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3, frame.BackgroundTransparency, frame.BorderSizePixel = color, startTransparency, 0
	frame.Parent = gui
	TweenService:Create(frame, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	Debris:AddItem(gui, duration + 0.1)
end

local function showTitle()
	local pGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pGui then return end
	local gui = Instance.new("ScreenGui")
	gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = true, false, 61
	gui.Parent = pGui
	local label = Instance.new("TextLabel")
	label.AnchorPoint, label.Position, label.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.2), UDim2.fromScale(0.5, 0.11)
	label.BackgroundTransparency = 1
	label.Font, label.TextScaled, label.Text = Enum.Font.GothamBlack, true, CONFIG.TITLE
	label.TextColor3, label.TextTransparency = CONFIG.GOLD, 1
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color, stroke.Thickness, stroke.Transparency = Color3.fromRGB(20, 30, 90), 3, 1
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 1.8
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(label, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	TweenService:Create(stroke, TweenInfo.new(0.2), { Transparency = 0 }):Play()
	task.delay(1.1, function()
		TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, TweenInfo.new(0.5), { Transparency = 1 }):Play()
	end)
	Debris:AddItem(gui, 1.8)
end

local function createHud()
	local pGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pGui then return nil end
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = "TimeStopHud", true, false, 59
	gui.Parent = pGui
	local label = Instance.new("TextLabel")
	label.AnchorPoint, label.Position, label.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.075), UDim2.fromScale(0.26, 0.04)
	label.BackgroundTransparency = 1
	label.Font, label.TextScaled, label.TextColor3 = Enum.Font.GothamBold, true, CONFIG.FROST
	label.Parent = gui
	local track = Instance.new("Frame")
	track.AnchorPoint, track.Position, track.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.105), UDim2.fromScale(0.26, 0.008)
	track.BackgroundColor3, track.BackgroundTransparency, track.BorderSizePixel = Color3.fromRGB(10, 15, 40), 0.35, 0
	track.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size, fill.BackgroundColor3, fill.BorderSizePixel = UDim2.fromScale(1, 1), CONFIG.GOLD, 0
	fill.Parent = track
	return gui, label, fill
end

-- ==========================================
-- AUDIO: ready sound, clock sound, arena music
-- ==========================================
local function stopReadySound()
	local s = readySound
	readySound = nil
	if s and s.Parent then
		TweenService:Create(s, TweenInfo.new(0.15), { Volume = 0 }):Play()
		Debris:AddItem(s, 0.2)
	end
end

local function playReadySound(readyTime, mode)
	stopReadySound()
	local source = findTimeSound("TimeReady")
	if not source then return end
	local s = source:Clone()
	s.Volume = 1.2
	s.Parent = SoundService
	readySound = s
	task.spawn(function()
		local t0 = os.clock()
		while not s.IsLoaded and os.clock() - t0 < 1.5 do task.wait() end
		if not s.Parent or readySound ~= s then return end
		local length = s.TimeLength
		if mode ~= "None" and length > readyTime + 0.05 then
			if mode == "Speed" then
				s.PlaybackSpeed = length / readyTime
			else
				s.TimePosition = length - readyTime -- "Trim": only the LAST readyTime seconds
			end
		end
		s:Play()
		if mode ~= "None" then
			task.delay(math.max(0.1, readyTime - (os.clock() - t0)), function()
				if readySound == s then stopReadySound() end
			end)
		end
	end)
end

local function stopClock(fade)
	local s = clockSound
	clockSound = nil
	if s and s.Parent then
		if (fade or 0) > 0 then
			TweenService:Create(s, TweenInfo.new(fade), { Volume = 0 }):Play()
			Debris:AddItem(s, fade + 0.05)
		else
			s:Destroy()
		end
	end
end

-- one clock sound at a time; it lives exactly as long as the stop (stopClock is called by End / reset)
local function playClock(stopDuration)
	stopClock(0)
	local source = findTimeSound(CONFIG.CLOCK_SOUND)
	if not source then return end
	local s = source:Clone()
	s.Volume = CONFIG.CLOCK_VOLUME
	s.TimePosition = 0
	s.Looped = (stopDuration or 0) > source.TimeLength + 0.1 -- only loops if the ability outlasts the sound
	s.Parent = SoundService
	clockSound = s
	s:Play()
end

local function duckMusic()
	if music then return end
	local sound = SoundService
	for _, name in CONFIG.MUSIC_PATH do
		sound = sound and sound:FindFirstChild(name)
	end
	if not sound or not sound:IsA("Sound") then return end
	local entry = { sound = sound, wasPlaying = sound.IsPlaying }
	music = entry
	if sound.IsPlaying then sound:Pause() end
	-- if a music script restarts it during the stop, pause it again
	entry.conn = sound:GetPropertyChangedSignal("Playing"):Connect(function()
		if music == entry and sound.Playing then sound:Pause() end
	end)
end

local function restoreMusic()
	local entry = music
	music = nil
	if not entry then return end
	if entry.conn then entry.conn:Disconnect() end
	-- only resume if it was playing before AND we are still inside the match (the arena theme belongs there)
	if entry.wasPlaying and entry.sound.Parent and not entry.sound.IsPlaying and PlayerData.Get(localPlayer, "IsOnArena") then
		entry.sound:Resume()
	end
end

-- ==========================================
-- AFTERIMAGE (caster)
-- ==========================================
local function spawnGhost(character, color)
	if ghostCount >= CONFIG.AFTERIMAGE_MAX then return end
	ghostCount += 1
	local folder = Instance.new("Folder")
	folder.Name = "TimeStopAfterimage"
	folder.Parent = getFX()
	local other = if color == CONFIG.AFTERIMAGE_COLORS[1] then CONFIG.AFTERIMAGE_COLORS[2] else CONFIG.AFTERIMAGE_COLORS[1]
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()
			for _, child in clone:GetChildren() do
				if not child:IsA("SpecialMesh") then child:Destroy() end
			end
			if clone:IsA("MeshPart") then clone.TextureID = "" end
			clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery, clone.Massless = true, false, false, false, true
			clone.CastShadow = false
			clone.Material, clone.Color, clone.Transparency = Enum.Material.Neon, color, 0.35
			clone.CFrame = part.CFrame
			clone.Parent = folder
			TweenService:Create(clone, TweenInfo.new(CONFIG.AFTERIMAGE_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1, Color = other,
			}):Play()
		end
	end
	Debris:AddItem(folder, CONFIG.AFTERIMAGE_LIFETIME + 0.1)
	task.delay(CONFIG.AFTERIMAGE_LIFETIME, function() ghostCount = math.max(0, ghostCount - 1) end)
end

local function startAfterimages(character, st)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local last, lastPosition, flip = 0, root.Position, false
	table.insert(st.connections, RunService.RenderStepped:Connect(function()
		if not root.Parent then return end
		local now = os.clock()
		local moved = (root.Position - lastPosition).Magnitude
		local interval = if moved > 0.4 then CONFIG.AFTERIMAGE_INTERVAL else CONFIG.AFTERIMAGE_IDLE_INTERVAL
		if now - last >= interval then
			last, lastPosition, flip = now, root.Position, not flip
			spawnGhost(character, CONFIG.AFTERIMAGE_COLORS[if flip then 1 else 2])
		end
	end))
end

-- ==========================================
-- CLEANUP
-- ==========================================
function TimeStopEffect.CleanupCaster(player)
	local record = activeCasters[player]
	if record then
		activeCasters[player] = nil
		record.clean()
	end
end

local function cleanupStopped()
	local st = stopped
	stopped = nil
	if not st then return end
	for _, connection in st.connections do connection:Disconnect() end
	if st.hud then st.hud:Destroy() end
	for _, highlight in st.frost do
		if highlight.Parent then
			TweenService:Create(highlight, TweenInfo.new(0.3), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
			Debris:AddItem(highlight, 0.35)
		end
	end
end

local function resetGrade()
	local cc = getColorCorrection()
	TweenService:Create(cc, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
		Brightness = 0, TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0,
	}):Play()
end

-- silent hard cleanup (match ended / left the arena / error path): no stinger, no flash
local function forceReset()
	cleanupStopped()
	TimeStopFreeze.End()
	stopReadySound()
	stopClock(0.15)
	restoreMusic()
	resetGrade()
	table.clear(shakes)
	fovReset(0.3)
end

-- ==========================================
-- 1. READY (telegraph)
-- ==========================================
function TimeStopEffect.Ready(casterPlayer, casterChar, data)
	TimeStopEffect.CleanupCaster(casterPlayer)
	local root = casterChar and casterChar:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local readyTime = data.readyTime or 2.5

	playReadySound(readyTime, data.soundMode or "Trim")
	fovSequence({ {
		if casterPlayer == localPlayer then CONFIG.FOV.READY_ZOOM else CONFIG.FOV.READY_ZOOM_OTHERS,
		readyTime, Enum.EasingStyle.Sine, Enum.EasingDirection.In,
	} })

	local folder = Instance.new("Folder")
	folder.Name = "Ready_" .. casterPlayer.Name
	folder.Parent = getFX()

	local emitters = {}
	local template = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("VFX")
		and ReplicatedStorage.Assets.VFX:FindFirstChild("Particles")
	if template and template:IsA("Model") then
		local vfx = template:Clone()
		vfx.Parent = folder
		for _, part in vfx:GetChildren() do
			if part:IsA("BasePart") then
				part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.Massless = false, false, false, false, true
				part.CFrame = root.CFrame
				local weld = Instance.new("WeldConstraint")
				weld.Part0, weld.Part1, weld.Parent = root, part, part
				for _, d in part:GetDescendants() do
					if d:IsA("ParticleEmitter") then
						d.Enabled = true
						table.insert(emitters, d)
					end
				end
			end
		end
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local motes = Instance.new("ParticleEmitter")
	motes.Rate, motes.Lifetime, motes.Speed = 70, NumberRange.new(0.6, 1.1), NumberRange.new(6, 14)
	motes.EmissionDirection, motes.SpreadAngle = Enum.NormalId.Top, Vector2.new(35, 35)
	motes.LightEmission, motes.LockedToPart = 1, false
	motes.Color = ColorSequence.new(CONFIG.TINT, CONFIG.GOLD)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	motes.Parent = attachment
	table.insert(emitters, motes)

	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = CONFIG.TINT, 4, 0
	light.Parent = root
	TweenService:Create(light, TweenInfo.new(readyTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Range = 24, Brightness = 5 }):Play()

	if casterPlayer == localPlayer then addShake(CONFIG.SHAKE.HIT) end

	local record
	record = {
		clean = function()
			for _, emitter in emitters do emitter.Enabled = false end
			TweenService:Create(light, TweenInfo.new(0.2), { Brightness = 0 }):Play()
			Debris:AddItem(light, 0.3)
			Debris:AddItem(attachment, 1.5)
			Debris:AddItem(folder, 2)
		end,
	}
	activeCasters[casterPlayer] = record
	task.delay(readyTime + 0.1, function()
		if activeCasters[casterPlayer] == record then TimeStopEffect.CleanupCaster(casterPlayer) end
	end)
end

function TimeStopEffect.Cancel(casterPlayer: Player, resetActive: boolean?)
	TimeStopEffect.CleanupCaster(casterPlayer)
	if resetActive then
		forceReset()
		return
	end
	stopReadySound()
	if not stopped then fovReset(0.3) end
end

-- ==========================================
-- 2. START (time stops)
-- ==========================================
function TimeStopEffect.Start(casterPlayer, casterChar, data)
	TimeStopEffect.CleanupCaster(casterPlayer)
	stopReadySound()
	cleanupStopped() -- a duplicate Start never stacks effects
	playTimeSound("TimeStop", 3, 1)
	duckMusic()
	local st = { connections = {}, frost = {} }
	stopped = st
	task.delay(1, function()
		if stopped == st then
			playClock(data.stopDuration)
		end
	end)

	local root = casterChar and casterChar:FindFirstChild("HumanoidRootPart")

	-- colour grade: bright flash -> cold desaturated world
	local cc = getColorCorrection()
	cc.Brightness, cc.TintColor, cc.Saturation, cc.Contrast = 0.55, Color3.new(1, 1, 1), 0, 0
	TweenService:Create(cc, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0.04, TintColor = CONFIG.TINT, Saturation = -0.85, Contrast = 0.5,
	}):Play()

	flash(Color3.fromRGB(220, 235, 255), 0.2, 0.65)
	if root then shockwave(root.Position, data.radius or 200) end

	-- the dimension tears open: violent FOV blast, then it settles wide and stays for the whole stop
	fovSequence({
		{ CONFIG.FOV.START_KICK, CONFIG.FOV.START_KICK_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out },
		{ CONFIG.FOV.STOP_HOLD, CONFIG.FOV.STOP_SETTLE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out },
	})
	addShake(CONFIG.SHAKE.START)
	task.delay(0.35, function()
		if stopped == st then addShake(CONFIG.SHAKE.START_AFTER) end
	end)
	if CONFIG.SHOW_TITLE and casterPlayer == localPlayer then showTitle() end

	for _, actor in data.victims or {} do
		if typeof(actor) == "Instance" and actor.Parent then
			local highlight = Instance.new("Highlight")
			highlight.Adornee = actor
			highlight.FillColor, highlight.OutlineColor = CONFIG.FROST, Color3.new(1, 1, 1)
			highlight.FillTransparency, highlight.OutlineTransparency = 0.85, 0.35
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = getFX()
			st.frost[actor] = highlight
		end
	end

	if CONFIG.SHOW_TIMER then
		local hud, label, fill = createHud()
		if hud then
			st.hud = hud
			local duration = math.max(data.stopDuration or 8, 0.1)
			table.insert(st.connections, RunService.RenderStepped:Connect(function()
				local remaining = math.max(0, (data.since or 0) + duration - time())
				label.Text = string.format("TIME STOPPED  %.1f", remaining)
				fill.Size = UDim2.fromScale(math.clamp(remaining / duration, 0, 1), 1)
			end))
		end
	end

	if casterChar then startAfterimages(casterChar, st) end

	-- Remove the data.scope == "Arena" check and radius limitation so it freezes everywhere on the map:
	if CONFIG.FREEZE_VFX then
		TimeStopFreeze.Begin({
			ignore = { 
				casterChar, 
				Workspace:FindFirstChild("TimeStopFX"),
				Workspace:FindFirstChild("CombatLocalEffects")
			},
		})
	end


	-- safety: if this player leaves the match while time is stopped, undo everything locally
	if data.scope == "Arena" then
		table.insert(st.connections, PlayerData.Observe(localPlayer, "IsOnArena", function()
			if stopped == st and not PlayerData.Get(localPlayer, "IsOnArena") then
				forceReset()
			end
		end))
	end
end

-- ==========================================
-- 3. HITS DURING THE STOP (no counter UI, no circles: sparks, sound, small camera pulse)
-- ==========================================


local function getMark(target, root)
	local m = marks[target]
	if m and m.gui.Parent then return m end
	local gui = Instance.new("BillboardGui")
	gui.Size, gui.StudsOffset, gui.AlwaysOnTop, gui.Adornee = UDim2.new(0, 110, 0, 56), Vector3.new(0, 3.2, 0), true, root
	gui.Parent = getFX()
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency = UDim2.fromScale(1, 1), 1
	label.Font, label.TextScaled = Enum.Font.GothamBlack, true
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness, stroke.Color = 2, Color3.fromRGB(20, 20, 40)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label
	m = { gui = gui, label = label, scale = scale }
	marks[target] = m
	return m
end

      
local function punch(m, from)
	m.scale.Scale = from
	TweenService:Create(m.scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

function TimeStopEffect.Mark(target, _count)
	local root = target and getRoot(target)
	if not root then return end
	playHitSound(0.7, 0.9 + math.min((_count or 1) * 0.04, 0.5))
	local m = getMark(target, root)
	m.label.Text = "x" .. tostring(_count)
	m.label.TextColor3 = Color3.fromRGB(255, 65, 65):Lerp(CONFIG.GOLD, math.clamp(_count / 10, 0, 1))
	punch(m, 1.6)
	burst(root.Position + Vector3.new(0, 1, 0), CONFIG.GOLD, 8, 28, 0.7)
	local highlight = stopped and stopped.frost[target]
	if highlight and highlight.Parent then
		highlight.FillColor, highlight.FillTransparency = Color3.fromRGB(255, 120, 120), 0.4
		TweenService:Create(highlight, TweenInfo.new(0.25), { FillColor = CONFIG.FROST, FillTransparency = 0.85 }):Play()
	end
	if stopped then
		fovPulse(CONFIG.FOV.HIT_PULSE)
		addShake(CONFIG.SHAKE.HIT)
	end
	if target == localPlayer.Character then addShake(CONFIG.SHAKE.VICTIM) end
end

function TimeStopEffect.RemoveMark(target: Instance)	
	local root = target and getRoot(target)
	if not root then return end
	local mark = getMark(target, root)
	local gui = mark and mark.gui
	if gui then
		gui:Destroy()
	end

	mark[target] = nil
end

-- barrage after the stop: index / total
function TimeStopEffect.Hit(target, index, total)
	local root = target and getRoot(target)
	if not root then return end
	local alpha = index / math.max(total, 1)
	playHitSound(0.85, 0.95 + alpha * 0.55)
	burst(root.Position + Vector3.new(0, 1, 0), Color3.fromRGB(255, 240, 200), 12, 40, 0.8)

	local camera = Workspace.CurrentCamera
	local near = camera ~= nil and (camera.CFrame.Position - root.Position).Magnitude < 60
	if target == localPlayer.Character then
		addShake(CONFIG.SHAKE.VICTIM)
	elseif near and index % 2 == 0 then
		addShake(CONFIG.SHAKE.HIT)
	end

	if index >= total then
		burst(root.Position, CONFIG.GOLD, 30, 70, 1.4)
		burst(root.Position, Color3.new(1, 1, 1), 18, 50, 1)
		if near then addShake(CONFIG.SHAKE.VICTIM) end
		if target == localPlayer.Character and not stopped then
			fovSequence({ { CONFIG.FOV.FINISH_KICK, 0.05 }, { 0, 0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out } })
		end
		task.delay(0.8, function()
			local current = marks[target]
			if current then
				current.gui:Destroy()
				marks[target] = nil
			end
		end)
	end
end

-- ==========================================
-- 4. END (time resumes). Runs exactly once per stop: a second TimeStopEnd finds stopped == nil and returns.
-- ==========================================
function TimeStopEffect.End(casterPlayer, _data)
	if not stopped then return end
	local root = casterPlayer and casterPlayer.Character and casterPlayer.Character:FindFirstChild("HumanoidRootPart")
	cleanupStopped()
	TimeStopFreeze.End()
	stopClock(0.2)
	restoreMusic()
	playTimeSound("TimeResume", 1.3, 1)

	local cc = getColorCorrection()
	cc.Brightness = 0.25
	TweenService:Create(cc, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
		Brightness = 0, TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0,
	}):Play()
	flash(Color3.fromRGB(255, 245, 220), 0.6, 0.4)
	if root then collapse(root.Position) end

	-- the dimension collapses: hard pull-in, small overshoot, then exactly back to the original FOV
	fovSequence({
		{ CONFIG.FOV.RESUME_PULL, CONFIG.FOV.RESUME_PULL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out },
		{ CONFIG.FOV.RESUME_OVERSHOOT, CONFIG.FOV.RESUME_OVERSHOOT_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out },
		{ 0, CONFIG.FOV.RESUME_SETTLE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out },
	})
	addShake(CONFIG.SHAKE.END)
end

function TimeStopEffect.Init(_shakeFn)
	-- kept for compatibility with CombatController.Init: camera shake is now built in
end

return TimeStopEffect
