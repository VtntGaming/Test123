-- ThrowEffect (CLIENT ModuleScript) -> inside the CombatController ModuleScript, folder "Throw", next to ThrowClient.
-- Everything you SEE for the Throw ability (runs on EVERY client; the server broadcasts ThrowStart / ThrowImpact / ThrowEnd):
--   * the held weapon disappears from the hand (client side) and a copy of it FLIES: spinning like a saber, banking,
--     glowing outline in its rarity colour, light, white-to-rarity ribbon trail, wind particles
--   * out -> hover (spins faster, sparks) -> returns to the hand -> CATCH: flash, burst, sound, camera kick
--   * every hit: sparks, sound, the weapon flashes, bystanders feel a camera shake
-- The flight path comes from SharedModules.ThrowPath (same maths as the server's hit detection).

local ThrowEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("SharedModules")
local ThrowPath = require(Shared.Throw:WaitForChild("ThrowPath"))
local WeaponConfig = require(Shared:WaitForChild("WeaponConfig"))
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local Clock = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("TimeStopClock"))

-- camera rumble comes from SmashEffect (same self-contained shake); optional
local okSmash, SmashEffect = pcall(function()
	return require(script.Parent.Parent:FindFirstChild("Smash"):FindFirstChild("SmashEffect"))
end)

local CONFIG = {
	TILT = { 12, 8 },                 -- degrees the spin plane is banked (looks dynamic, not flat)
	TRAIL = true,                     -- ribbon between both tips of the weapon -> a glowing disc while it spins
	HIGHLIGHT = true,                 -- glowing outline in the rarity colour
	LIGHT = true,
	WIND = true,                      -- wind particles

	SOUND_LAUNCH = "WeaponSwing2",    -- names inside SoundService.SFX or SoundService.Effects ("" = none)
	SOUND_FLY = "WeaponSwing",        -- repeated while it flies
	SOUND_HIT = "Rock",
	SOUND_CATCH = "WeaponSwing3",
	FLY_SOUND_INTERVAL = 0.28,

	SHAKE_DISTANCE = 80,
}

local active = {} -- [Player] = { stop = function(caught), startedAt = number, flash = function() }

-- ==========================================
-- HELPERS
-- ==========================================
local function getFolder()
	local folder = Workspace:FindFirstChild("CombatLocalEffects") -- ignored by the server ragdoll queries
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CombatLocalEffects"
		folder.Parent = Workspace
	end
	return folder
end

local function newPart(position)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = position
	part.Parent = getFolder()
	return part
end

local function findSound(name)
	if not name or name == "" then return nil end
	for _, folderName in { "SFX", "Effects" } do
		local folder = SoundService:FindFirstChild(folderName)
		local sound = folder and folder:FindFirstChild(name)
		if sound and sound:IsA("Sound") then return sound end
	end
	return nil
end

local function playSoundAt(name, position, pitch, volume)
	local source = findSound(name)
	if not source then return end
	local holder = newPart(position)
	local sound = source:Clone()
	sound.PlaybackSpeed = pitch or 1
	sound.Volume = sound.Volume * (volume or 1)
	sound.Parent = holder
	sound.Ended:Once(function() holder:Destroy() end)
	Debris:AddItem(holder, 6)
	sound:Play()
end

local function rumble(position, magnitude, duration)
	if not okSmash or not SmashEffect or not SmashEffect.Rumble then return end
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance > CONFIG.SHAKE_DISTANCE then return end
	SmashEffect.Rumble(magnitude * (1 - distance / CONFIG.SHAKE_DISTANCE * 0.7), duration)
end

local function burst(position, color, count, speed, spread, size)
	local holder = newPart(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.3, 0.7)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.SpreadAngle = spread or Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.LightEmission = 1
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size or 1), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(holder, 1.5)
end

-- thin white expanding ring (no fat colored circle)
local function ring(position, size, duration)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Material = Enum.Material.Neon
	part.Color = Color3.new(1, 1, 1)
	part.Transparency = 0.35
	part.Size = Vector3.new(0.15, 1, 1)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = getFolder()
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, size, size), Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

local function flash(position, peak)
	local holder = newPart(position)
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = Color3.fromRGB(235, 245, 255), 22, peak
	light.Parent = holder
	TweenService:Create(light, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
	Debris:AddItem(holder, 0.4)
end

local function handPosition(character)
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then return hand.Position end
	local root = character:FindFirstChild("HumanoidRootPart")
	return root and (root.Position + Vector3.new(0, 1, 0)) or Vector3.zero
end

-- the weapon in the hand disappears (client side only: the server never touches it) and comes back afterwards
local function hideHeld(character)
	local weapon = character:FindFirstChild("EquippedWeapon")
	if not weapon then return function() end end
	local saved = {}
	for _, item in weapon:GetDescendants() do
		if item:IsA("BasePart") or item:IsA("Decal") then
			saved[item] = { "Transparency", item.Transparency }
			item.Transparency = 1
		elseif item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Beam")
			or item:IsA("PointLight") or item:IsA("SpotLight") or item:IsA("SurfaceLight") then
			saved[item] = { "Enabled", item.Enabled }
			item.Enabled = false
		end
	end
	return function()
		for item, info in saved do
			if item.Parent then item[info[1]] = info[2] end
		end
		table.clear(saved)
	end
end

-- the flying copy: a clone of the weapon in the hand (so variants look right), anchored and bounding-box centred
local function buildModel(character, weaponName)
	local model = nil
	local held = character:FindFirstChild("EquippedWeapon")
	if held then model = held:Clone() end
	if not model then
		local info = WeaponConfig.GetWeaponInfo(weaponName or "")
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local folder = assets and assets:FindFirstChild("Weapons")
		local template = folder and (folder:FindFirstChild(weaponName or "") or (info and folder:FindFirstChild(info.BaseName)))
		if template and template:IsA("Model") then model = template:Clone() end
	end
	if not model then return nil end

	local hasPart = false
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			hasPart = true
			item.Anchored, item.CanCollide, item.CanTouch, item.CanQuery, item.Massless = true, false, false, false, true
			item.CastShadow = false
		elseif item:IsA("BaseScript") or item:IsA("Weld") or item:IsA("WeldConstraint") or item:IsA("Sound") then
			item:Destroy()
		end
	end
	if not hasPart then model:Destroy() return nil end

	model.Name = "ThrownWeapon"
	local cfg = AbilityConfig.Abilities.Throw
	model:ScaleTo(model:GetScale() * (cfg.Scale or 1.5))

	local boxCF, size = model:GetBoundingBox()
	local offset = model:GetPivot():ToObjectSpace(boxCF) -- pivot -> bounding box centre
	local length = math.max(size.X, size.Y, size.Z)
	local axis, axisVector
	if size.X >= size.Y and size.X >= size.Z then
		axis, axisVector = "X", Vector3.xAxis
	elseif size.Y >= size.Z then
		axis, axisVector = "Y", Vector3.yAxis
	else
		axis, axisVector = "Z", Vector3.zAxis
	end
	return model, offset, length, axis, axisVector
end

-- ==========================================
-- PUBLIC
-- ==========================================
function ThrowEffect.Init() end

-- params = { origin, forward, range, curve, outTime, hoverTime, returnTime, startTime (server time), weaponName }
function ThrowEffect.Launch(thrower, character, params)
	local existing = active[thrower]
	if existing and os.clock() - existing.startedAt < 1.5 then return end -- the thrower already started it locally
	ThrowEffect.Cancel(thrower)

	if not character or not character.Parent then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or type(params) ~= "table" then return end

	local cfg = AbilityConfig.Abilities.Throw
	local isLocal = thrower == Players.LocalPlayer
	local path = ThrowPath.new(params)

	local model, offset, length, axis, axisVector = buildModel(character, params.weaponName) -- clone BEFORE hiding the original
	if not model then return end
	local restoreHeld = hideHeld(character)

	local info = WeaponConfig.GetWeaponInfo(params.weaponName or "")
	local color = info and info.RarityColor or Color3.fromRGB(150, 200, 255)
	local glow = color:Lerp(Color3.new(1, 1, 1), 0.45)

	-- the axis fix makes the weapon's LONG axis horizontal, so the spin around Y looks like a propeller / saber
	local axisFix = if axis == "X" then CFrame.identity elseif axis == "Y" then CFrame.Angles(0, 0, -math.pi / 2) else CFrame.Angles(0, math.pi / 2, 0)
	local tilt = CFrame.Angles(math.rad(CONFIG.TILT[1]), 0, math.rad(CONFIG.TILT[2]))

	-- holder = bounding box centre, same orientation as the weapon: trail ends / light / wind live on it
	local holder = newPart(path.origin)
	holder.Name = "ThrowHolder"
	model.Parent = getFolder()

	local trail, trailA, trailB = nil, nil, nil
	if CONFIG.TRAIL then
		trailA, trailB = Instance.new("Attachment"), Instance.new("Attachment")
		trailA.Position, trailB.Position = axisVector * (length / 2), -axisVector * (length / 2)
		trailA.Parent, trailB.Parent = holder, holder
		trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = trailA, trailB
		trail.Lifetime = 0.22
		trail.LightEmission = 1
		trail.FaceCamera = false
		trail.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(1, glow) })
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
		trail.Parent = holder
	end

	local highlight = nil
	if CONFIG.HIGHLIGHT then
		highlight = Instance.new("Highlight")
		highlight.Adornee = model
		highlight.FillColor, highlight.OutlineColor = glow, glow
		highlight.FillTransparency, highlight.OutlineTransparency = 1, 0.15
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = model
	end

	local light = nil
	if CONFIG.LIGHT then
		light = Instance.new("PointLight")
		light.Color, light.Range, light.Brightness = glow, 16, 1.4
		light.Parent = holder
	end

	local windAttachment, wind = nil, nil
	if CONFIG.WIND then
		windAttachment = Instance.new("Attachment")
		windAttachment.Parent = holder
		wind = Instance.new("ParticleEmitter")
		wind.Rate = 28
		wind.Lifetime = NumberRange.new(0.2, 0.4)
		wind.Speed = NumberRange.new(2, 6)
		wind.SpreadAngle = Vector2.new(180, 180)
		wind.LightEmission = 1
		wind.LockedToPart = false
		wind.Color = ColorSequence.new(glow)
		wind.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
		wind.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		wind.Parent = windAttachment
	end

	-- launch: wind burst + thin ring + sound + camera kick for the thrower
	local startPosition = handPosition(character)
	burst(startPosition, Color3.new(1, 1, 1), 14, 26, Vector2.new(120, 120), 0.9)
	ring(startPosition, 9, 0.3)
	flash(startPosition, 3)
	playSoundAt(CONFIG.SOUND_LAUNCH, startPosition, 1.05, 1)
	if isLocal then rumble(startPosition, 2.0, 0.35) end

	local running = true
	local connection
	local spin = math.random() * math.pi * 2
	local nextSound = 0
	local lastPosition = path.origin

	local function stop(caught)
		if not running then return end
		running = false
		if connection then connection:Disconnect() connection = nil end
		restoreHeld()
		if wind then wind.Enabled = false end
		if trail then trail.Enabled = false end
		model:Destroy()
		Debris:AddItem(holder, 0.7) -- trail / wind finish fading on the holder
		if caught then
			local hand = handPosition(character)
			burst(hand, Color3.new(1, 1, 1), 18, 30, Vector2.new(180, 180), 1.0)
			ring(hand, 8, 0.28)
			flash(hand, 4)
			playSoundAt(CONFIG.SOUND_CATCH, hand, 0.95, 1)
			if isLocal then rumble(hand, 3.2, 0.4) end
		end
		if active[thrower] and active[thrower].stop == stop then active[thrower] = nil end
	end

	local entry = { stop = stop, startedAt = os.clock() }
	entry.flash = function()
		if highlight and highlight.Parent then
			highlight.FillTransparency = 0.25
			TweenService:Create(highlight, TweenInfo.new(0.3), { FillTransparency = 1 }):Play()
		end
		if light then
			light.Brightness = 4
			TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 1.4 }):Play()
		end
	end
	active[thrower] = entry

	connection = RunService.RenderStepped:Connect(function(dt)
		if not character.Parent or not root.Parent then stop(false) return end

		-- Subtract time paused during TimeStop so the trajectory freezes
		local now = time()
		local t = ThrowPath.Elapsed(params.startTime or now, now, path.scope)
		local hand = handPosition(character)
		local position, phase = path:At(t, hand)

		if phase == "Done" then stop(true) return end
		if phase == "Wait" then return end

		-- Do not spin while time is stopped
		local hovering = phase == "Hover"
		if not Clock.IsStopped(path.scope) then
			spin += dt * (cfg.SpinSpeed or 26) * (if hovering then 1.5 else 1)
		end

		local base = CFrame.new(position) * tilt * CFrame.Angles(0, spin, 0) * axisFix
		model:PivotTo(base * offset:Inverse())
		holder.CFrame = base

		if not Clock.IsStopped(path.scope) and now >= nextSound then
			nextSound = now + CONFIG.FLY_SOUND_INTERVAL
			playSoundAt(CONFIG.SOUND_FLY, position, if hovering then 1.35 else 0.95 + math.random() * 0.2, 0.7)
		end
		lastPosition = position
	end)

	-- Render cleanup follows the scoped path's Done phase; wall-clock timers would expire during a pause.
end

-- the server (or the thrower's client) says: it is over. caught = false -> vanish immediately (ragdolled etc.)
function ThrowEffect.Cancel(thrower)
	local entry = active[thrower]
	if entry then entry.stop(false) end
end

-- the weapon hit something at `position`
function ThrowEffect.Impact(thrower, position)
	local entry = active[thrower]
	if entry then entry.flash() end
	if typeof(position) ~= "Vector3" then return end
	burst(position, Color3.new(1, 1, 1), 16, 55, Vector2.new(180, 180), 0.9)
	burst(position, Color3.fromRGB(255, 220, 160), 10, 40, Vector2.new(180, 180), 1.1)
	ring(position, 7, 0.25)
	flash(position, 3)
	playSoundAt(CONFIG.SOUND_HIT, position, 1.25, 0.9)
	if thrower ~= Players.LocalPlayer then rumble(position, 1.6, 0.3) end -- bystanders
end

-- local thrower: his weapon hit something (count = how many so far)
function ThrowEffect.ThrowerHit(count)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then rumble(root.Position, 2.4 + math.min(count, 4) * 0.7, 0.35) end
end

-- local victim: got hit by a thrown weapon
function ThrowEffect.Victim()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then rumble(root.Position, 4.5, 0.5) end
end

return ThrowEffect
