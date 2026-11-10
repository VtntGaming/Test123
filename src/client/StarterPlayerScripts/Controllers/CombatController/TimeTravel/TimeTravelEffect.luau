-- TimeTravelEffect (CLIENT ModuleScript) -> CombatController.TimeTravel.TimeTravelEffect
local TimeTravelEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local AbilityConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("AbilityConfig"))
local localPlayer = Players.LocalPlayer

local CONFIG = {
	-- ghost
	GHOST_PULSE_SPEED = 1.6,
	GHOST_PULSE_AMOUNT = 0.12,
	FADE_TIME = 0.4,

	-- trail
	TRAIL_STEPS = 6,
	TRAIL_LIFETIME = 0.55,
	MAX_SNAPSHOTS = 16,

	-- screen effects
	SHOW_TITLE = false, -- Title text removed
	SHOW_HUD = true,
	HUD_Y = 0.8,

	SET_GRADE = { Brightness = 0.1, TintColor = Color3.fromRGB(170, 225, 255), Saturation = 0.25, Contrast = 0.15, Time = 0.5 },
	-- Returning to the ghost uses the same look as Time Stop: a bright flash, then a cold washed-out world that fades back.
	RETURN_GRADE = {
		FlashBrightness = 0.55,                 -- instant white flash the moment you arrive
		Tint = Color3.fromRGB(150, 175, 255),   -- cold tint while it holds
		Brightness = 0.04,
		Saturation = -0.85,
		Contrast = 0.5,
		InTime = 0.05,                          -- flash -> cold look
		HoldTime = 0.1,                        -- how long the cold look stays
		OutTime = 0.05,                          -- back to the normal picture
	},

	FOV_SET = -6,
	FOV_SET_TIME = 0.35,
	FOV_RETURN = 24,
	FOV_RETURN_TIME = 0.6,
}

local active = {}
local shake = nil
local bodyCount = 0

local function getCfg()
	return AbilityConfig.Abilities.TimeTravel or {}
end

local function colors()
	local cfg = getCfg()
	return cfg.GhostColor or Color3.fromRGB(110, 190, 255), cfg.GhostColor2 or Color3.fromRGB(190, 120, 255)
end

local function getFX()
	local folder = Workspace:FindFirstChild("TimeTravelFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TimeTravelFX"
		folder.Parent = Workspace
	end
	return folder
end

local function playSound(id, volume, parent)
	if id == nil then return end
	local soundId = tostring(id)
	if soundId == "" or soundId == "0" then return end
	if tonumber(soundId) then soundId = "rbxassetid://" .. soundId end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 1
	sound.Parent = parent or SoundService
	sound.Ended:Once(function() sound:Destroy() end)
	Debris:AddItem(sound, 15)
	sound:Play()
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
	emitter.Lifetime = NumberRange.new(0.3, 0.8)
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

local function expand(position, color, radius)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored, ball.CanCollide, ball.CanTouch, ball.CanQuery, ball.CastShadow = true, false, false, false, false
	ball.Material, ball.Color, ball.Transparency = Enum.Material.Neon, color, 0.35
	ball.Size, ball.Position = Vector3.one * 2, position
	ball.Parent = getFX()
	TweenService:Create(ball, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.one * radius * 2, Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.5)
end

local function collapse(position, color, radius)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored, ball.CanCollide, ball.CanTouch, ball.CanQuery, ball.CastShadow = true, false, false, false, false
	ball.Material, ball.Color, ball.Transparency = Enum.Material.Neon, color, 0.8
	ball.Size, ball.Position = Vector3.one * radius * 2, position
	ball.Parent = getFX()
	TweenService:Create(ball, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
		Size = Vector3.one * 1.5, Transparency = 0.1,
	}):Play()
	Debris:AddItem(ball, 0.4)
end

local grade, gradeTween, gradeThread = nil, nil, nil

local function getGrade()
	if not grade or not grade.Parent then
		grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "TimeTravelGrade"
		grade.Parent = Lighting
	end
	return grade
end

local function cancelGrade()
	if gradeTween then gradeTween:Cancel()
gradeTween = nil end
	if gradeThread then task.cancel(gradeThread)
gradeThread = nil end
end

local function pulseGrade(preset)
	local cc = getGrade()
	cancelGrade()
	cc.Brightness, cc.TintColor, cc.Saturation, cc.Contrast = preset.Brightness, preset.TintColor, preset.Saturation, preset.Contrast
	gradeTween = TweenService:Create(cc, TweenInfo.new(preset.Time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0, TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0,
	})
	gradeTween:Play()
end

-- Return grade (like Time Stop): white flash -> cold desaturated look -> hold -> fade back to normal.
local function returnGrade()
	local preset = CONFIG.RETURN_GRADE
	local cc = getGrade()
	cancelGrade()
	cc.Brightness, cc.TintColor, cc.Saturation, cc.Contrast = preset.FlashBrightness, Color3.new(1, 1, 1), 0, 0
	gradeTween = TweenService:Create(cc, TweenInfo.new(preset.InTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = preset.Brightness, TintColor = preset.Tint, Saturation = preset.Saturation, Contrast = preset.Contrast,
	})
	gradeTween:Play()
	gradeThread = task.delay(preset.InTime + preset.HoldTime, function()
		gradeThread = nil
		if not cc.Parent then return end
		gradeTween = TweenService:Create(cc, TweenInfo.new(preset.OutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Brightness = 0, TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0,
		})
		gradeTween:Play()
	end)
end

local function resetGrade()
	local cc = getGrade()
	cancelGrade()
	gradeTween = TweenService:Create(cc, TweenInfo.new(0.3), { Brightness = 0, TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0 })
	gradeTween:Play()
end

local function flash(color, startTransparency, duration)
	local pGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pGui then return end
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = "TimeTravelFlash", true, false, 60
	gui.Parent = pGui
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3, frame.BackgroundTransparency, frame.BorderSizePixel = color, startTransparency, 0
	frame.Parent = gui
	TweenService:Create(frame, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	Debris:AddItem(gui, duration + 0.1)
end

local kickBase, kickTween = nil, nil

local function fovKick(kick, settleTime)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	if kickTween then kickTween:Cancel() end
	kickBase = kickBase or camera.FieldOfView
	camera.FieldOfView = kickBase + kick
	local tween = TweenService:Create(camera, TweenInfo.new(settleTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { FieldOfView = kickBase })
	kickTween = tween
	tween.Completed:Once(function()
		if kickTween == tween then
			kickTween, kickBase = nil, nil
		end
	end)
	tween:Play()
end

local function shakeCamera()
	if shake then pcall(shake, "Bump") end
end

local function buildBody(character, targetCFrame, color, transparency)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return nil end
	local delta = targetCFrame * root.CFrame:Inverse()
	local folder = Instance.new("Folder")
	folder.Name = "TimeTravelBody"
	folder.Parent = getFX()
	local parts = {}
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()
			if not clone then continue end
			for _, child in clone:GetChildren() do
				if not child:IsA("SpecialMesh") then child:Destroy() end
			end
			if clone:IsA("MeshPart") then clone.TextureID = "" end
			clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery, clone.Massless = true, false, false, false, true
			clone.CastShadow = false
			clone.Material, clone.Color, clone.Transparency = Enum.Material.Neon, color, transparency
			clone.CFrame = delta * part.CFrame
			clone.Parent = folder
			table.insert(parts, clone)
		end
	end
	return folder, parts
end

local function snapshot(character, cframe, color, otherColor, lifetime)
	if bodyCount >= CONFIG.MAX_SNAPSHOTS then return end
	local folder, parts = buildBody(character, cframe, color, 0.35)
	if not folder then return end
	bodyCount += 1
	for _, part in parts do
		TweenService:Create(part, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1, Color = otherColor,
		}):Play()
	end
	Debris:AddItem(folder, lifetime + 0.1)
	task.delay(lifetime, function() bodyCount = math.max(0, bodyCount - 1) end)
end

local function createHud(record, expiresAt, duration)
	if not CONFIG.SHOW_HUD then return end
	local pGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pGui then return end
	duration = math.max(duration or 6, 0.1)

	local gui = Instance.new("ScreenGui")
	gui.Name, gui.IgnoreGuiInset, gui.ResetOnSpawn, gui.DisplayOrder = "TimeTravelHud", true, false, 58
	gui.Parent = pGui

	local label = Instance.new("TextLabel")
	label.AnchorPoint, label.Position, label.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, CONFIG.HUD_Y), UDim2.fromScale(0.28, 0.04)
	label.BackgroundTransparency = 1
	label.Font, label.TextScaled, label.TextColor3 = Enum.Font.GothamBold, true, record.color
	label.Parent = gui
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Color, labelStroke.Thickness = Color3.fromRGB(15, 15, 40), 2
	labelStroke.Parent = label

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint, hint.Position, hint.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, CONFIG.HUD_Y + 0.04), UDim2.fromScale(0.28, 0.025)
	hint.BackgroundTransparency = 1
	hint.Font, hint.TextScaled, hint.TextColor3 = Enum.Font.GothamMedium, true, Color3.new(1, 1, 1)
	hint.Text = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		then "Tap the ability button again to return" else "Right click again to return"
	hint.Parent = gui
	local hintStroke = Instance.new("UIStroke")
	hintStroke.Color, hintStroke.Thickness = Color3.fromRGB(15, 15, 40), 1.5
	hintStroke.Parent = hint

	local track = Instance.new("Frame")
	track.AnchorPoint, track.Position, track.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, CONFIG.HUD_Y + 0.075), UDim2.fromScale(0.28, 0.008)
	track.BackgroundColor3, track.BackgroundTransparency, track.BorderSizePixel = Color3.fromRGB(10, 15, 40), 0.35, 0
	track.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size, fill.BackgroundColor3, fill.BorderSizePixel = UDim2.fromScale(1, 1), record.color, 0
	fill.Parent = track

	label.TextTransparency, hint.TextTransparency, labelStroke.Transparency, hintStroke.Transparency = 1, 1, 1, 1
	local fadeIn = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, fadeIn, { TextTransparency = 0 }):Play()
	TweenService:Create(hint, fadeIn, { TextTransparency = 0 }):Play()
	TweenService:Create(labelStroke, fadeIn, { Transparency = 0 }):Play()
	TweenService:Create(hintStroke, fadeIn, { Transparency = 0 }):Play()

	record.hud = gui
	table.insert(record.connections, RunService.RenderStepped:Connect(function()
		local remaining = math.max(0, (expiresAt or 0) - Workspace:GetServerTimeNow())
		label.Text = string.format("%.1f", remaining)
		fill.Size = UDim2.fromScale(math.clamp(remaining / duration, 0, 1), 1)
		fill.BackgroundColor3 = record.color2:Lerp(record.color, math.clamp(remaining / duration, 0, 1))
	end))
end

local function removeRecord(player, fadeTime)
	local record = active[player]
	if not record then return end
	active[player] = nil
	for _, connection in record.connections do connection:Disconnect() end
	if record.hud then record.hud:Destroy() end
	if fadeTime and fadeTime > 0 then
		if record.emitter then record.emitter.Enabled = false end
		for _, part in record.parts do
			if part.Parent then
				TweenService:Create(part, TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Transparency = 1, Color = record.color2,
				}):Play()
			end
		end
		if record.light then TweenService:Create(record.light, TweenInfo.new(fadeTime), { Brightness = 0 }):Play() end
		Debris:AddItem(record.folder, fadeTime + 0.1)
	else
		record.folder:Destroy()
	end
end

local function cleanupAll()
	for player in active do removeRecord(player, 0) end
	resetGrade()
end

function TimeTravelEffect.Set(player, character, data)
	if typeof(player) ~= "Instance" or typeof(character) ~= "Instance" or type(data) ~= "table" then return end
	local cframe = data.cframe
	if typeof(cframe) ~= "CFrame" then return end
	removeRecord(player, 0)

	local cfg = getCfg()
	local color, color2 = colors()
	local baseTransparency = cfg.GhostTransparency or 0.55
	local folder, parts = buildBody(character, cframe, color, baseTransparency)
	if not folder then return end

	local anchor = Instance.new("Part")
	anchor.Name = "GhostAnchor"
	anchor.Anchored, anchor.CanCollide, anchor.CanTouch, anchor.CanQuery, anchor.CastShadow = true, false, false, false, false
	anchor.Transparency, anchor.Size, anchor.CFrame = 1, Vector3.one, cframe
	anchor.Parent = folder
	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local motes = Instance.new("ParticleEmitter")
	motes.Rate, motes.Lifetime, motes.Speed = 22, NumberRange.new(0.8, 1.4), NumberRange.new(2, 5)
	motes.EmissionDirection, motes.SpreadAngle = Enum.NormalId.Top, Vector2.new(40, 40)
	motes.LightEmission, motes.LockedToPart = 1, false
	motes.Color = ColorSequence.new(color, color2)
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	motes.Parent = attachment

	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = color, 14, 2
	light.Parent = anchor

	local record = {
		folder = folder, parts = parts, connections = {}, color = color, color2 = color2,
		cframe = cframe, emitter = motes, light = light, anchor = anchor,
	}
	active[player] = record

	local t0 = os.clock()
	table.insert(record.connections, RunService.Heartbeat:Connect(function()
		local pulse = math.sin((os.clock() - t0) * CONFIG.GHOST_PULSE_SPEED * math.pi * 2) * CONFIG.GHOST_PULSE_AMOUNT
		for _, part in parts do
			if part.Parent then part.Transparency = math.clamp(baseTransparency + pulse, 0, 1) end
		end
	end))

	burst(cframe.Position, color, 14, 22, 0.8)
	expand(cframe.Position, color, 9)

	local sounds = cfg.Sounds or {}
	if player == localPlayer then
		playSound(sounds.Set, 4)
		pulseGrade(CONFIG.SET_GRADE)
		fovKick(CONFIG.FOV_SET, CONFIG.FOV_SET_TIME)
		createHud(record, data.expiresAt, data.duration)
	else
		playSound(sounds.Set, 1, anchor)
	end

	task.delay((data.duration or 6) + 1, function()
		if active[player] == record then TimeTravelEffect.End(player, false) end
	end)
	table.insert(record.connections, character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(Workspace) and active[player] == record then removeRecord(player, 0) end
	end))
end

function TimeTravelEffect.Return(player, character, data)
	if typeof(player) ~= "Instance" or typeof(character) ~= "Instance" or type(data) ~= "table" then return end
	local from, to = data.from, data.to
	if typeof(from) ~= "CFrame" or typeof(to) ~= "CFrame" then return end
	local cfg = getCfg()
	local color, color2 = colors()

	for step = 0, CONFIG.TRAIL_STEPS do
		local alpha = step / CONFIG.TRAIL_STEPS
		local first, second = color, color2
		if step % 2 == 1 then first, second = color2, color end
		snapshot(character, from:Lerp(to, alpha), first, second, CONFIG.TRAIL_LIFETIME * (0.45 + 0.55 * alpha))
	end

	--collapse(from.Position + Vector3.new(0, 1, 0), color2, 12)
	--expand(to.Position + Vector3.new(0, 1, 0), color, 16)
	--burst(from.Position + Vector3.new(0, 1, 0), color2, 24, 40, 1)
	--burst(to.Position + Vector3.new(0, 1, 0), color, 30, 50, 1.2)

	local sounds = cfg.Sounds or {}
	if player == localPlayer then
		playSound(sounds.Return, 1.2)
		returnGrade()
		--flash(Color3.fromRGB(97, 92, 113), 0.25, 0.55)
		fovKick(CONFIG.FOV_RETURN, CONFIG.FOV_RETURN_TIME)
		shakeCamera()
	else
		local holder = newPart(to.Position)
		playSound(sounds.Return, 1, holder)
		Debris:AddItem(holder, 15)
	end
end

function TimeTravelEffect.End(player, returned)
	local record = active[player]
	if not record then return end
	if returned then
		removeRecord(player, 0.12)
		return
	end
	burst(record.cframe.Position, record.color2, 12, 18, 0.7)
	local sounds = getCfg().Sounds or {}
	if player == localPlayer then
		playSound(sounds.Expire, 1)
	else
		playSound(sounds.Expire, 1, record.anchor)
	end
	removeRecord(player, CONFIG.FADE_TIME)
end

function TimeTravelEffect.Init(shakeFn)
	shake = shakeFn
	local function check()
		if not (PlayerData.Get(localPlayer, "IsOnArena") or PlayerData.Get(localPlayer, "IsInTrainingArea")) then
			cleanupAll()
		end
	end
	PlayerData.Observe(localPlayer, "IsOnArena", check)
	PlayerData.Observe(localPlayer, "IsInTrainingArea", check)
end

return TimeTravelEffect
