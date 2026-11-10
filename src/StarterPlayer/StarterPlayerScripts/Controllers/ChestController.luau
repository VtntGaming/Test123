-- ChestController (CLIENT ModuleScript) - V2 "Lucky Block style" opening
--
-- Timeline (every client plays it, the opener also gets camera work + the server ack):
--   1. THROW      chest flies along a bezier arc with a front flip (VFXUtils.Bezier)
--   2. LANDING    BOOM  -> Effects.Rock sound + dust + rocks + shake
--   3. BOUNCES    BOOM BOOM BOOM -> Rock sound each impact (pitch climbs), squash & stretch (TweenM)
--   4. CHARGE     chest rumbles, light builds up
--   5. LID OPENS  SoundService.OpenSound.LuckyBlockOpening plays, the weapon ROULETTE starts above the chest
--                 (slows down for real, teases a better rarity right before the result)
--   6. REVEAL     OpenSound.<Rarity> sound, weapon locks in + spins, Aura.<Rarity>.Flare attached,
--                 rarity burst / pillar / shockwave / rocks / shake / screen flash / banner (Legendary+)
--   7. FINISH     weapon flies into the opener's character, chest fades out
--
-- Expected layout (same as before):
--   ReplicatedStorage.SharedModules.VFXUtils: Misc, BezierCurve, TweenM (required)
--                                             GroundRock, CameraShaker (optional)
--   SoundService.Effects.Rock, SoundService.OpenSound.{LuckyBlockOpening, Common, Rare, Epic, Legendary, Mythic}
--   Aura folder: ReplicatedStorage.(Assets|Asset).(Effects|Effect).Aura.<Rarity>.Flare   (also tries Workspace.Aura)

local ChestController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer :: Player
local Events = ReplicatedStorage:WaitForChild("Events")
local OpenChestEvent = Events:WaitForChild("OpenChestEvent")
local ChestRewardEvent = Events:WaitForChild("ChestRewardEvent")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local ChestCatalog = require(SharedModules:WaitForChild("ChestCatalog"))
local Assets = ReplicatedStorage:WaitForChild("Assets")
local WeaponsFolder = Assets:WaitForChild("Weapons")

-- Misc reads workspace.visual the moment it is required, so make sure the folder exists first.
local VisualFolder = workspace:FindFirstChild("visual")
if not VisualFolder then
	VisualFolder = Instance.new("Folder")
	VisualFolder.Name = "visual"
	VisualFolder.Parent = workspace
end

local VFXUtils = SharedModules:WaitForChild("VFXUtils")
local Misc = require(VFXUtils:WaitForChild("Misc"))
local Bezier = require(VFXUtils:WaitForChild("BezierCurve"))
local TweenM = require(VFXUtils:WaitForChild("TweenM"))

local function tryRequire(name)
	local module = VFXUtils:FindFirstChild(name)
	if not module then
		warn("[ChestController] optional VFX util missing: " .. name)
		return nil
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn("[ChestController] could not load " .. name .. ": " .. tostring(result))
		return nil
	end
	return result
end

local GroundRock = tryRequire("GroundRock")
local CameraShaker = tryRequire("CameraShaker")

-- ==========================================
-- CONFIG
-- ==========================================
local CONFIG = {
	CHEST_SCALE = 2.4,     -- the thrown chest is this many times bigger than the template
	CHEST_ROTATION_Y = 90,
	THROW_DISTANCE = 12,
	THROW_TIME = 0.6,
	ARC_HEIGHT = 8,
	BOUNCES = 3,
	CHARGE_TIME = 0.5,

	SHAKE_RADIUS = 70,   -- camera shakes only if this close to the chest
	SOUND_RADIUS = 120,  -- other players hear the chest only from this far (opener always hears it)
	ROCK_PITCH = { 0.9, 1.0, 1.1, 1.2 }, -- landing + each bounce: pitch climbs = tension

	DISPLAY_SIZE = 12,     -- every weapon is normalised to this many studs (longest side)
	DISPLAY_HEIGHT = 11,   -- hover height above the open chest
	REVEAL_SCALE = 1.5,    -- final pop size multiplier (12 * 1.5 = 18 studs)
	HOLD_TIME = 3.2,       -- how long the won weapon stays after the reveal
	FLY_TIME = 0.55,       -- weapon flying into the character
	SKIP_ANIM_SPEED = 1.25,   -- skipAnim=true only: 2 = twice as fast; 0.5 = half speed (must be positive)

	BANNER_MIN_RANK = 4,   -- Legendary and up get a banner for everybody

	-- LuckyBlockOpening is slow-fast-slow, which does not fit a fast roulette -> off by default.
	-- The roulette now has its own constant fast pace; the rarity OpenSound plays on the reveal.
	PLAY_LUCKYBLOCK_SOUND = false,
	-- OpenSound.WheelSpin (~1.2s) is LOOPED for the whole roulette (restarts seamlessly while the weapons swap),
	-- its pitch climbs as the roulette goes on, and it fades out at the reveal.
	WHEEL_PITCH_START = 1.0,
	WHEEL_PITCH_END = 1.3,

	ROULETTE = {
		DURATION = 2.8,    -- how long the weapons spin (the WheelSpin sound loops for this long)
		MAX_SWAP = 0.14,   -- only the last moments brake down to this
		MIN_SWAP = 0.04,   -- very fast constant spinning
		SUSPENSE = 0.6,    -- result shown (solid, swelling) before the reveal
		GHOST = 0,         -- weapons stay fully solid while spinning (no transparency)
		ZOOM = 5,          -- camera FOV reduction during the roulette
	},
}

-- rank: used for the roulette teaser + banner. flash: starting transparency of the white screen flash (nil = none)
local RARITY_FX = {
	Common    = { rank = 1, shake = "SmallBump",    burst = 18,  speed = 22, ring = 14, rocks = nil,      rockScale = 1,   pillar = 0,  flash = nil },
	Rare      = { rank = 2, shake = "Bump",         burst = 32,  speed = 26, ring = 18, rocks = "Small",  rockScale = 1,   pillar = 16, flash = nil },
	Epic      = { rank = 3, shake = "BigBump",      burst = 50,  speed = 30, ring = 24, rocks = "Small",  rockScale = 1.3, pillar = 26, flash = 0.8 },
	Legendary = { rank = 4, shake = "Explosion",    burst = 80,  speed = 36, ring = 32, rocks = "Normal", rockScale = 1.2, pillar = 38, flash = 0.55 },
	Mythic    = { rank = 5, shake = "BigExplosion", burst = 130, speed = 44, ring = 42, rocks = "Normal", rockScale = 1.8, pillar = 55, flash = 0.2 },
}

local DUST_COLOR = Color3.fromRGB(190, 170, 140)
local GOLD = Color3.fromRGB(255, 225, 120)

-- ==========================================
-- GENERIC HELPERS
-- ==========================================
local function findPath(root, ...)
	local current = root
	for _, name in { ... } do
		current = current and current:FindFirstChild(name)
		if not current then return nil end
	end
	return current
end

local function newValue(class, value)
	local v = Instance.new(class)
	v.Value = value
	return v
end

local function eulerDeg(cf)
	local x, y, z = cf:ToEulerAnglesXYZ()
	return Vector3.new(math.deg(x), math.deg(y), math.deg(z))
end

-- angle a moved to b along the shortest way (degrees)
local function shortest(a, b)
	return a + ((b - a + 180) % 360) - 180
end

local function invisiblePart(position, size)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	part.Size = size or Vector3.one
	part.Position = position
	part.Parent = VisualFolder
	return part
end

local function rankOfRarity(rarity)
	return (RARITY_FX[rarity] or RARITY_FX.Common).rank
end

-- ==========================================
-- SOUND  (positional, pitch-able, self cleaning)
-- ==========================================
local function playSound(position, source, pitch, volume, isLocal)
	if not source or not source:IsA("Sound") then return end
	local holder = invisiblePart(position)
	local sfx = source:Clone()
	if not isLocal then sfx.RollOffMaxDistance = math.min(sfx.RollOffMaxDistance, CONFIG.SOUND_RADIUS) end
	if pitch then sfx.PlaybackSpeed = pitch end
	if volume then sfx.Volume = sfx.Volume * volume end
	sfx.Parent = holder
	sfx.Ended:Once(function() holder:Destroy() end)
	Debris:AddItem(holder, 15)
	sfx:Play()
end

-- looping sound (returns the Sound so it can be pitched / stopped)
local function startLoop(position, source, isLocal)
	if not source or not source:IsA("Sound") then return nil end
	local holder = invisiblePart(position)
	local sfx = source:Clone()
	if not isLocal then sfx.RollOffMaxDistance = math.min(sfx.RollOffMaxDistance, CONFIG.SOUND_RADIUS) end
	sfx.Looped = true
	sfx.Parent = holder
	Debris:AddItem(holder, 30) -- safety net
	sfx:Play()
	return sfx
end

local function stopLoop(sfx, fadeTime)
	if not sfx or not sfx.Parent then return end
	local holder = sfx.Parent
	local t = TweenService:Create(sfx, TweenInfo.new(fadeTime or 0.15), { Volume = 0 })
	t:Play()
	t.Completed:Once(function()
		sfx:Stop()
		holder:Destroy()
	end)
end

-- ==========================================
-- AURA  (Aura.<Rarity>.Flare attachment full of ParticleEmitters)
-- ==========================================
local AURA_ROOTS = {
	{ ReplicatedStorage, "Assets", "Effects", "Aura" },
	{ ReplicatedStorage, "Assets", "Effect", "Aura" },
	{ ReplicatedStorage, "Asset", "Effects", "Aura" },
	{ ReplicatedStorage, "Asset", "Effect", "Aura" },
	{ ReplicatedStorage, "Assets", "Aura" },
	{ workspace, "Aura" },
}
local auraFolder, auraWarned = nil, false

local function getAuraFolder()
	if auraFolder and auraFolder.Parent then return auraFolder end
	for _, path in AURA_ROOTS do
		local found = findPath(table.unpack(path))
		if found then
			auraFolder = found
			return found
		end
	end
	return nil
end

local function attachAura(parent, rarity)
	local folder = getAuraFolder()
	local source = folder and folder:FindFirstChild(rarity)
	if not source then
		if not auraWarned then
			auraWarned = true
			warn("[ChestController] Aura." .. rarity .. " not found - edit AURA_ROOTS at the top of the script")
		end
		return nil
	end
	source = source:FindFirstChild("Flare") or source

	local clone = source:Clone()
	local holder
	if clone:IsA("Attachment") then
		holder = clone
		holder.Parent = parent
	else
		-- Part / Model / Folder: pull every emitter onto one attachment
		holder = Instance.new("Attachment")
		holder.Parent = parent
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("ParticleEmitter") then d.Parent = holder end
		end
		clone:Destroy()
	end
	Misc.Enable({ holder }, true)
	Misc.Emit({ holder })
	return holder
end

-- ==========================================
-- CAMERA: shake + FOV (one owner at a time, so two chests never fight)
-- ==========================================
local shaker = nil
local function ensureShaker()
	if not CameraShaker then return false end
	if not shaker then
		shaker = CameraShaker.new(Enum.RenderPriority.Camera.Value + 1, function(shakeCFrame)
			local cam = workspace.CurrentCamera
			if cam then cam.CFrame = cam.CFrame * shakeCFrame end
		end)
		shaker._renderName = "ChestCameraShaker"
		shaker:Start()
	end
	return true
end

-- custom rumble (used while the weapons spin: grows with the roulette progress)
local function rumble(position, magnitude, roughness, fadeOut)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - position).Magnitude > CONFIG.SHAKE_RADIUS then return end
	if ensureShaker() then
		shaker:ShakeOnce(magnitude, roughness or 14, 0, fadeOut or 0.25, Vector3.new(0.12, 0.12, 0.12), Vector3.new(1, 1, 1))
	end
end

local function shakeCamera(preset)
	if not ensureShaker() then return end
	local ok, instance = pcall(function() return CameraShaker.Presets[preset] end)
	if ok and instance then shaker:Shake(instance) end
end

local function shakeNear(preset, position)
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - position).Magnitude <= CONFIG.SHAKE_RADIUS then
		shakeCamera(preset)
	end
end

local fov = { active = 0, base = 70 }
local function fovBegin()
	local cam = workspace.CurrentCamera
	if fov.active == 0 and cam then fov.base = cam.FieldOfView end
	fov.active += 1
end
local function fovSet(delta, time, style, direction)
	local cam = workspace.CurrentCamera
	if not cam then return end
	TweenService:Create(cam, TweenInfo.new(time, style or Enum.EasingStyle.Sine, direction or Enum.EasingDirection.Out), { FieldOfView = fov.base - delta }):Play()
end
local function fovEnd(animationSpeed)
	fov.active = math.max(0, fov.active - 1)
	if fov.active == 0 then
		fovSet(0, 0.5 / (animationSpeed or 1), Enum.EasingStyle.Elastic)
	end
end

-- ==========================================
-- SCREEN FX (white flash + banner)
-- ==========================================
local fxGui, flashFrame, bannerHolder = nil, nil, nil
local function ensureGui()
	if fxGui and fxGui.Parent then return end
	fxGui = Instance.new("ScreenGui")
	fxGui.Name, fxGui.ResetOnSpawn, fxGui.IgnoreGuiInset, fxGui.DisplayOrder = "ChestFX", false, true, 50

	flashFrame = Instance.new("Frame")
	flashFrame.Size, flashFrame.BackgroundColor3, flashFrame.BackgroundTransparency = UDim2.fromScale(1, 1), Color3.new(1, 1, 1), 1
	flashFrame.BorderSizePixel, flashFrame.ZIndex, flashFrame.Active = 0, 10, false
	flashFrame.Parent = fxGui

	bannerHolder = Instance.new("Frame")
	bannerHolder.AnchorPoint, bannerHolder.Position, bannerHolder.Size = Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0.12), UDim2.fromScale(0.8, 0.3)
	bannerHolder.BackgroundTransparency = 1
	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment, layout.Padding = Enum.HorizontalAlignment.Center, UDim.new(0, 4)
	layout.Parent = bannerHolder
	bannerHolder.Parent = fxGui

	fxGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function screenFlash(startTransparency, animationSpeed)
	ensureGui()
	flashFrame.BackgroundTransparency = startTransparency
	TweenService:Create(flashFrame, TweenInfo.new(0.7 / (animationSpeed or 1), Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
end

local function showBanner(text, color, animationSpeed)
	local speed = animationSpeed or 1
	ensureGui()
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 40)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextSize = 30
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	label.Parent = bannerHolder
	TweenService:Create(label, TweenInfo.new(0.35 / speed, Enum.EasingStyle.Back), { TextTransparency = 0, TextStrokeTransparency = 0 }):Play()
	task.delay(4 / speed, function()
		local t = TweenService:Create(label, TweenInfo.new(0.5 / speed), { TextTransparency = 1, TextStrokeTransparency = 1 })
		t:Play()
		t.Completed:Wait()
		label:Destroy()
	end)
end

-- ==========================================
-- VFX BUILDING BLOCKS
-- ==========================================
-- Particle burst built in code, fired with Misc.Emit (reads the EmitCount attribute). Returns the holder part.
local function burst(position, color, count, speed)
	local holder = invisiblePart(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(speed * 0.6 * CONFIG.CHEST_SCALE, speed * CONFIG.CHEST_SCALE)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Drag = 2
	emitter.LightEmission = 1
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6 * CONFIG.CHEST_SCALE), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter:SetAttribute("EmitCount", count)
	emitter.Parent = attachment

	Misc.Emit({ attachment })
	Misc.Debris(holder, 2)
	return holder
end

local function flashLight(holder, color, peak, animationSpeed)
	local speed = animationSpeed or 1
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = color, 22 * CONFIG.CHEST_SCALE, 0
	light.Parent = holder
	TweenM.new({
		{ ins = light, twinfo = TweenInfo.new(0.08 / speed, Enum.EasingStyle.Quad), prop = { Brightness = peak } },
		{ ins = light, twinfo = TweenInfo.new(0.6 / speed, Enum.EasingStyle.Quad), prop = { Brightness = 0 } },
	}):Play(true)
end

-- flat neon ring that expands on the ground
local function shockwave(position, color, size, duration)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored, ring.CanCollide, ring.CanTouch, ring.CanQuery, ring.CastShadow = true, false, false, false, false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.25, 1, 1)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = VisualFolder
	TweenM.new({
		{ ins = ring, twinfo = TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), prop = { Size = Vector3.new(0.25, size, size) }, nowait = true },
		{ ins = ring, twinfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), prop = { Transparency = 1 } },
	}):Play(true)
	Misc.Debris(ring, duration + 0.3)
end

-- vertical light beam: grows, then fades (tier-based height)
local function lightPillar(position, color, height, duration)
	if height <= 0 then return end
	local pillar = Instance.new("Part")
	pillar.Anchored, pillar.CanCollide, pillar.CanTouch, pillar.CanQuery, pillar.CastShadow = true, false, false, false, false
	pillar.Material = Enum.Material.Neon
	pillar.Color = color
	pillar.Transparency = 0.35
	pillar.Size = Vector3.new(1.2, 0.5, 1.2)
	pillar.CFrame = CFrame.new(position + Vector3.new(0, 0.25, 0))
	pillar.Parent = VisualFolder
	TweenM.new({
		{ ins = pillar, twinfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			prop = { Size = Vector3.new(2.4 * CONFIG.CHEST_SCALE, height, 2.4 * CONFIG.CHEST_SCALE), CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0)) } },
		{ ins = pillar, twinfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			prop = { Transparency = 1, Size = Vector3.new(0.2, height, 0.2) } },
	}):Play(true)
	Misc.Debris(pillar, duration + 0.5)
end

local function groundRocks(preset, position, scale)
	if not GroundRock then return end
	local origin = invisiblePart(position)
	-- Circle(Preset, RockMultiple, Scale, TimeLength, Ignore, Origin, castdis, Parent)
	local ok, err = pcall(GroundRock.Circle, preset, 1, scale, 3, VisualFolder, origin, 14, VisualFolder)
	if not ok then warn("[ChestController] GroundRock failed:", err) end
	Misc.Debris(origin, 5)
end

-- ==========================================
-- CHEST RIG (every part anchored, driven by one pose function: position + squash/stretch + lid angle)
-- ==========================================
local function buildRig(clone, scale)
	local base = clone:FindFirstChild("Base") or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
	if not base then return nil end

	local rig = { base = base, parts = {}, offsets = {}, sizes = {}, lid = {}, baseHeight = base.Size.Y, lidAngle = 0, lastScale = Vector3.one }
	local baseCF = base.CFrame

	for _, p in ipairs(clone:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery, p.Massless = true, false, false, false, true
			rig.sizes[p] = p.Size
			rig.offsets[p] = baseCF:ToObjectSpace(p.CFrame)
			table.insert(rig.parts, p)
		end
	end

	-- the lid = "Top" (+ everything inside it); hinge on its -X edge like the old version
	local topObj = clone:FindFirstChild("Top")
	local topPart = topObj and (topObj:IsA("BasePart") and topObj or topObj:FindFirstChildWhichIsA("BasePart", true))
	if topObj and topPart and topPart ~= base then
		rig.top = topPart
		if topObj:IsA("BasePart") then rig.lid[topObj] = true end
		for _, d in ipairs(topObj:GetDescendants()) do
			if d:IsA("BasePart") then rig.lid[d] = true end
		end
		rig.hinge = rig.offsets[topPart] * CFrame.new((-topPart.Size.X / 2) + 0.25 * scale, (-topPart.Size.Y / 2) + 0.75 * scale, 0)
	end

	-- cf = where the Base goes, scale = squash/stretch (bottom of the chest stays on the floor)
	function rig:Pose(cf, scale)
		self.moveParts = self.moveParts or {}
		self.moveFrames = self.moveFrames or {}
		table.clear(self.moveParts)
		table.clear(self.moveFrames)
		scale = scale or Vector3.one
		cf = cf * CFrame.new(0, -(1 - scale.Y) * self.baseHeight / 2, 0)

		local lidRot = nil
		if self.hinge and self.lidAngle ~= 0 then
			lidRot = self.hinge * CFrame.Angles(0, 0, self.lidAngle) * self.hinge:Inverse()
		end
		local resize = scale ~= self.lastScale
		self.lastScale = scale

		for _, p in ipairs(self.parts) do
			if not p.Parent then continue end
			local rel = self.offsets[p]
			if lidRot and self.lid[p] then rel = lidRot * rel end
			if resize then p.Size = self.sizes[p] * scale end
			table.insert(self.moveParts, p)
			table.insert(self.moveFrames, cf * (CFrame.new(rel.Position * scale) * rel.Rotation))
		end
		if #self.moveParts > 0 then workspace:BulkMoveTo(self.moveParts, self.moveFrames, Enum.BulkMoveMode.FireCFrameChanged) end
	end

	return rig
end

-- ==========================================
-- WEAPON DISPLAY (real 3D model hovering above the chest, so Aura particles show)
-- ==========================================
local Display = {}
Display.__index = Display

local function createWeaponModel(name)
	local template = WeaponsFolder:FindFirstChild(name)
	if not template then return nil end
	local model = template:Clone()
	if not model:IsA("Model") then
		local wrap = Instance.new("Model")
		model.Parent = wrap
		model = wrap
	end
	local hasPart = false
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			hasPart = true
			d.Anchored, d.CanCollide, d.CanTouch, d.CanQuery, d.Massless = true, false, false, false, true
			d:SetAttribute("OrigT", d.Transparency)
		elseif d:IsA("BaseScript") then
			d:Destroy()
		end
	end
	if not hasPart then
		model:Destroy()
		return nil
	end
	return model
end

local function newDisplay(origin, isLocal: boolean)
	local anchor = invisiblePart(origin)
	anchor.Name = "ChestRewardAnchor"
	return setmetatable({
		anchor = anchor, origin = origin, model = nil, angle = 0, bob = false, posOverride = nil,
		spin = newValue("NumberValue", 5),
		pop = newValue("NumberValue", 1),
		mul = newValue("NumberValue", 1),
		lift = newValue("NumberValue", 0.4),
		norm = 1, curScale = 1, offset = CFrame.identity, bboxRot = CFrame.identity,
		IsLocal = isLocal,
		LocalPlayerCameraProgress = 0,
	}, Display)
end

function Display:Set(name, ghost)
	if self.model then self.model:Destroy() self.model = nil end
	local model = createWeaponModel(name)
	if not model then return false end

	local _, size = model:GetBoundingBox()
	local norm = model:GetScale() * CONFIG.DISPLAY_SIZE / math.max(size.X, size.Y, size.Z, 0.1)
	model:ScaleTo(norm)

	local bboxCF = model:GetBoundingBox()
	self.norm, self.curScale = norm, norm
	self.offset = model:GetPivot():ToObjectSpace(bboxCF) -- pivot -> bounding box centre
	self.bboxRot = bboxCF.Rotation
	self.model = model

	if ghost and ghost > 0 then self:SetGhost(ghost) end
	self:Place(CFrame.new(self.anchor.Position))
	model.Parent = VisualFolder

	-- rarity-coloured outline: flickers through the rarity colours while the roulette spins
	local winfo = WeaponConfig.GetWeaponInfo(name)
	local glow = Instance.new("Highlight")
	glow.Adornee = model
	glow.FillTransparency = 1
	glow.OutlineColor = winfo and winfo.RarityColor or Color3.new(1, 1, 1)
	glow.OutlineTransparency = 0.1
	glow.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	glow.Parent = model
	return true
end

function Display:Place(cFrame: CFrame)
	local model = self.model
	if not model then return end
	local s = self.norm * self.pop.Value * self.mul.Value
	if math.abs(s - self.curScale) > 1e-4 then
		model:ScaleTo(s)
		self.curScale = s
	end
	local f = s / self.norm
	local off = CFrame.new(self.offset.Position * f) * self.offset.Rotation
	-- spin around the bounding-box centre, not around the model pivot
	model:PivotTo(cFrame * CFrame.Angles(0, self.angle, 0) * self.bboxRot * off:Inverse())
end

function Display:Update(dt)
	local animationSpeed = self.AnimationSpeed or 1
	self.angle += dt * self.spin.Value * animationSpeed
	local pos = self.posOverride :: Vector2
	if not pos then
		local bob = self.bob and math.sin(os.clock() * 2.2 * animationSpeed) * 0.18 or 0
		pos = self.origin + Vector3.new(0, self.lift.Value + bob, 0)
	end
	self.anchor.Position = pos
	local progress = self.LocalPlayerCameraProgress
	local cFrame = CFrame.new(pos)
	if progress > 0 then
		cFrame = cFrame:Lerp(workspace.CurrentCamera.CFrame * CFrame.new(0, 0, -15), progress)
	end
	self:Place(cFrame)
end

function Display:SetGhost(amount)
	if not self.model then return end
	for _, p in ipairs(self.model:GetDescendants()) do
		if p:IsA("BasePart") then
			local orig = p:GetAttribute("OrigT") or 0
			p.Transparency = orig + (1 - orig) * amount
		end
	end
end

function Display:Solidify(time)
	if not self.model then return end
	for _, p in ipairs(self.model:GetDescendants()) do
		if p:IsA("BasePart") then
			TweenService:Create(p, TweenInfo.new(time, Enum.EasingStyle.Quad), { Transparency = p:GetAttribute("OrigT") or 0 }):Play()
		end
	end
end

function Display:Destroy()
	if self.model then self.model:Destroy() self.model = nil end
	Misc.Debris(self.anchor, 2.5) -- stays a moment so the aura particles can fade out
end

-- name label that pops in above the weapon
local function makeLabel(anchor, displayName, rarity, color, isLocal, animationSpeed)
	local gui
	if isLocal then
		gui = Instance.new("ScreenGui")
		gui.Name = "ChestRewardLabel"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	else
		gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(460, 120)
		gui.StudsOffset = Vector3.new(0, CONFIG.DISPLAY_SIZE * 0.85 + 1, 0)
		gui.AlwaysOnTop, gui.LightInfluence, gui.MaxDistance = true, 0, 90
		gui.Adornee = anchor
		gui.Parent = anchor
	end

	local box = Instance.new("Frame")
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = isLocal and UDim2.fromScale(0.5, 0.2) or UDim2.fromScale(0.5, 0.5)
	box.Size = isLocal and UDim2.fromScale(0.6, 0.2) or UDim2.fromScale(1, 1)
	box.BackgroundTransparency = 1
	box.Parent = gui
	if isLocal then
		local aspectRatio = Instance.new("UIAspectRatioConstraint")
		aspectRatio.AspectRatio = 460 / 120
		aspectRatio.Parent = box
	end
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = box

	local function text(y, h, str, col, size)
		local l = Instance.new("TextLabel")
		l.Position, l.Size = UDim2.fromScale(0, y), UDim2.fromScale(1, h)
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.FredokaOne
		l.TextScaled = true
		l.Text = str
		l.TextColor3 = col
		l.Parent = box
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = size
		stroke.Color = Color3.fromRGB(20, 20, 20)
		stroke.Parent = l
	end
	text(0, 0.32, string.upper(rarity), color, 2)
	text(0.32, 0.68, displayName, Color3.new(1, 1, 1), 3)

	TweenService:Create(scale, TweenInfo.new(0.45 / (animationSpeed or 1), Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	return gui, scale
end

-- ==========================================
-- WEAPON POOL (roulette)
-- ==========================================
local weaponNamesCache = nil
local function getAllWeaponNames()
	if weaponNamesCache then return weaponNamesCache end
	local names = {}
	local function add(name)
		if WeaponsFolder:FindFirstChild(name) then table.insert(names, name) end
	end
	for baseName in WeaponConfig.BaseWeapons do
		add(baseName)
		for _, variants in WeaponConfig.RarityVariants or {} do
			for _, variant in variants do add(baseName .. variant) end
		end
	end
	weaponNamesCache = names
	return names
end

local function rankOfWeapon(name)
	local info = WeaponConfig.GetWeaponInfo(name)
	return rankOfRarity(info and info.Rarity or "Common")
end

-- near-miss: a weapon of a higher rarity than the result, shown right before the lock-in
local function pickTeaser(wonRank)
	local pool = {}
	for _, name in ipairs(getAllWeaponNames()) do
		if rankOfWeapon(name) > wonRank then table.insert(pool, name) end
	end
	return #pool > 0 and pool[math.random(#pool)] or nil
end

-- ==========================================
-- THE SEQUENCE
-- ==========================================
local function flyWeaponIntoOpener(display, openerPlayer, root, isLocal, rarityColor, animationSpeed)
	local flyTime = CONFIG.FLY_TIME / (animationSpeed or 1)
	display.bob = false
	display.spin.Value = 10
	local from = display.anchor.Position
	local camera = workspace.CurrentCamera
	if isLocal and camera then
		from = (camera.CFrame * CFrame.new(0, 0, -15)).Position
	end
	display.LocalPlayerCameraProgress = 0
	local mid = (from + (root.Position + Vector3.new(0, 1.5, 0))) / 2 + Vector3.new(0, 5, 0)
	local flyStart = os.clock()
	local target = from
	repeat
		local liveRoot = openerPlayer.Character and openerPlayer.Character:FindFirstChild("HumanoidRootPart")
		target = liveRoot and (liveRoot.Position + Vector3.new(0, 1.5, 0)) or (from + Vector3.new(0, 6, 0))
		local a = math.clamp((os.clock() - flyStart) / flyTime, 0, 1)
		local e = a * a
		display.posOverride = Misc.Bezier(from, mid, target, e)
		display.mul.Value = math.max(0.05, CONFIG.REVEAL_SCALE * (1 - e * 0.95))
		task.wait()
	until os.clock() - flyStart >= flyTime
	burst(target, rarityColor, 14, 14)
end

local function playChestOpenAnimation(openerPlayer: Player, chestName, startCF, wonWeaponName, code, skipAnim)
	local isLocal = (openerPlayer == LocalPlayer)
	local animationSpeed = 1
	local configuredSpeed = CONFIG.SKIP_ANIM_SPEED
	if skipAnim == true and type(configuredSpeed) == "number" and configuredSpeed > 0 and configuredSpeed < math.huge then
		animationSpeed = configuredSpeed
	end

	-- tells the server the reveal happened so it grants the weapon (server also has a timeout)
	local acked = false
	local function ack()
		if acked or not isLocal or not code then return end
		acked = true
		ChestRewardEvent:FireServer(code)
	end

	local fovHeld = false
	local function releaseFov()
		if fovHeld then
			fovHeld = false
			fovEnd(animationSpeed)
		end
	end
	if isLocal and skipAnim ~= true then
		fovHeld = true
		fovBegin()
	end

	local junk = {} -- cleaned up if anything errors

	local ok, err = pcall(function()
		local char = openerPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then
			ack()
			releaseFov()
			return
		end
		local info = wonWeaponName and WeaponConfig.GetWeaponInfo(wonWeaponName) or nil
		local rarity = info and info.Rarity or "Common"
		local rarityColor = info and info.RarityColor or GOLD
		local fx = RARITY_FX[rarity] or RARITY_FX.Common
		local raritySound = findPath(SoundService, "OpenSound", rarity)

		local function revealAndFinish(display, updateConn, hasModel, ground, targetCF, clone)
			-- ---------- 6) REVEAL ----------
			ack() -- the server grants the weapon now
			local pos = display.anchor.Position

			if not hasModel then
				-- weapon model missing: still do the rarity effects on the chest, then clean up
				burst(pos, rarityColor, fx.burst, fx.speed)
				releaseFov()
				updateConn:Disconnect()
				display:Destroy()
				if clone then Misc.Debris(clone, 1 / animationSpeed) end
				return
			end

			display.mul.Value = 1.1
			TweenService:Create(display.mul, TweenInfo.new(0.7 / animationSpeed, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Value = CONFIG.REVEAL_SCALE }):Play()
			TweenService:Create(display.spin, TweenInfo.new(1.2 / animationSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 3 }):Play()
			display.bob = true

			-- white flash on the weapon itself
			local hl = Instance.new("Highlight")
			hl.Adornee, hl.FillColor, hl.FillTransparency, hl.OutlineColor, hl.OutlineTransparency = display.model, Color3.new(1, 1, 1), 0, rarityColor, 0
			hl.Parent = display.model
			TweenService:Create(hl, TweenInfo.new(0.4 / animationSpeed, Enum.EasingStyle.Quad), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
			Misc.Debris(hl, 0.6 / animationSpeed)

			-- sound: OpenSound.<Rarity> (same system as the Lucky Block)
			playSound(pos, raritySound, nil, nil, isLocal)

			-- rarity effects
			local holder = burst(pos, rarityColor, fx.burst, fx.speed)
			flashLight(holder, rarityColor, 6 + fx.ring * 0.15, animationSpeed)
			shockwave(ground + Vector3.new(0, 0.2, 0), rarityColor, fx.ring * CONFIG.CHEST_SCALE, 0.55 / animationSpeed)
			lightPillar(ground, rarityColor, fx.pillar, 1.4 / animationSpeed)
			if fx.rocks then groundRocks(fx.rocks, targetCF.Position, fx.rockScale * CONFIG.CHEST_SCALE) end
			shakeNear(fx.shake, pos)
			if isLocal then
				if fx.flash then screenFlash(fx.flash, animationSpeed) end
				fovSet(-6, 0.1 / animationSpeed, Enum.EasingStyle.Quad)
				task.delay(0.15 / animationSpeed, releaseFov)
			end

			-- aura (Aura.<Rarity>.Flare) follows the weapon
			local aura = attachAura(display.anchor, rarity)
			if aura then table.insert(junk, aura) end

			local label, labelScale = makeLabel(display.anchor, info and info.DisplayName or wonWeaponName, rarity, rarityColor, isLocal, animationSpeed)
			table.insert(junk, label)

			if fx.rank >= CONFIG.BANNER_MIN_RANK then
				local who = isLocal and "You" or openerPlayer.DisplayName
				showBanner(who .. " found " .. (info and info.DisplayName or wonWeaponName) .. "!", rarityColor, animationSpeed)
			end

			if clone then
				-- chest melts away
				task.delay(0.8 / animationSpeed, function()
					for _, p in ipairs(clone:GetDescendants()) do
						if p:IsA("BasePart") then
							TweenService:Create(p, TweenInfo.new(0.6 / animationSpeed, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
						end
					end
					Misc.Debris(clone, 1.2 / animationSpeed)
				end)
			end

			task.wait(CONFIG.HOLD_TIME / animationSpeed)

			-- ---------- 7) FINISH: weapon flies into the opener ----------
			TweenService:Create(labelScale, TweenInfo.new(0.25 / animationSpeed, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 }):Play()
			Misc.Debris(label, 0.4 / animationSpeed)

			flyWeaponIntoOpener(display, openerPlayer, root, isLocal, rarityColor, animationSpeed)
			if aura then Misc.Enable({ aura }, false) end
			updateConn:Disconnect()
			display:Destroy()
			if clone then Misc.Debris(clone, 1 / animationSpeed) end
			releaseFov()
		end

		if skipAnim == true then
			if not wonWeaponName then ack(); return end
			local display = newDisplay(startCF.Position, isLocal)
			table.insert(junk, display.anchor)
			local hasModel = display:Set(wonWeaponName, 0)
			if display.model then table.insert(junk, display.model) end
			display.AnimationSpeed = animationSpeed
			display.lift.Value = CONFIG.DISPLAY_HEIGHT
			display.LocalPlayerCameraProgress = if isLocal and workspace.CurrentCamera then 1 else 0
			display:Update(0)
			local updateConn = RunService.Heartbeat:Connect(function(dt) display:Update(dt) end)
			table.insert(junk, updateConn)
			if isLocal then
				fovHeld = true
				fovBegin()
			end
			local ground = Vector3.new(startCF.Position.X, root.Position.Y - 3, startCF.Position.Z)
			revealAndFinish(display, updateConn, hasModel, ground, startCF, nil)
			return
		end
		local chestInfo = ChestCatalog.Get(chestName)
		local template = chestInfo and chestInfo.ModelPath
		if not template then
			ack()
			releaseFov()
			return
		end

		local rockSound = findPath(SoundService, "Effects", "Rock")
		local lbSound = findPath(SoundService, "OpenSound", "LuckyBlockOpening")
		local tickSound = findPath(SoundService, "Effects", "Press") -- optional roulette tick

		-- ---------- build chest ----------
		local clone = template:Clone()
		clone:ScaleTo(CONFIG.CHEST_SCALE * clone:GetScale())
		clone:PivotTo(startCF)
		clone.Parent = VisualFolder
		table.insert(junk, clone)

		local rig = buildRig(clone, CONFIG.CHEST_SCALE)
		if not rig then
			ack()
			releaseFov()
			clone:Destroy()
			return
		end
		local base, H = rig.base, rig.baseHeight

		local targetPos = root.Position + (root.CFrame.LookVector * CONFIG.THROW_DISTANCE)
		local groundY = root.Position.Y - 3 + (H / 2)
		local targetCF = CFrame.lookAt(Vector3.new(targetPos.X, groundY, targetPos.Z), Vector3.new(root.Position.X, groundY, root.Position.Z))
			* CFrame.Angles(0, math.rad(CONFIG.CHEST_ROTATION_Y), 0)
		local ground = targetCF.Position - Vector3.new(0, H / 2, 0)

		-- every time the chest hits the floor: BOOM (index 0 = landing, 1..n = bounces)
		local function impact(index)
			playSound(ground, rockSound, CONFIG.ROCK_PITCH[index + 1] or 1.2, nil, isLocal)
			burst(ground + Vector3.new(0, 0.3, 0), DUST_COLOR, 12 + index * 6, 12 + index * 2)
			if index == 0 then
				groundRocks("Small", targetCF.Position, CONFIG.CHEST_SCALE)
				shakeNear("Bump", ground)
			else
				shakeNear(index >= CONFIG.BOUNCES and "Bump" or "SmallBump", ground)
			end
		end

		-- ---------- 1) THROW (bezier arc + front flip via a proxy part) ----------
		local startBase = base.CFrame
		local p1, p3 = startBase.Position, targetCF.Position
		local p2 = (p1 + p3) / 2 + Vector3.new(0, CONFIG.ARC_HEIGHT, 0)
		local o1, e3 = eulerDeg(startBase), eulerDeg(targetCF)
		local o3 = Vector3.new(shortest(o1.X, e3.X) + 360, shortest(o1.Y, e3.Y), shortest(o1.Z, e3.Z))
		local o2 = (o1 + o3) / 2

		local proxy = invisiblePart(p1)
		proxy.CFrame = startBase
		table.insert(junk, proxy)
		Bezier.Quadratic(proxy, p1, p2, p3, o1, o2, o3, CONFIG.THROW_TIME)
		local follow = RunService.Heartbeat:Connect(function() rig:Pose(proxy.CFrame) end)
		local waited = 0
		while not proxy:GetAttribute("BezierFinished") and waited < CONFIG.THROW_TIME + 1 do
			waited += task.wait()
		end
		follow:Disconnect()
		proxy:Destroy()
		rig:Pose(targetCF)
		impact(0)

		-- ---------- 2) BOUNCES: squash & stretch, BOOM on every impact ----------
		local aCF, aScale = newValue("CFrameValue", targetCF), newValue("Vector3Value", Vector3.one)
		local function updatePose() rig:Pose(aCF.Value, aScale.Value) end
		local c1, c2 = aCF.Changed:Connect(updatePose), aScale.Changed:Connect(updatePose)

		local steps = {}
		for i = 1, CONFIG.BOUNCES do
			local dur, jumpH = 0.25, (0.8 + (i * 0.4)) * CONFIG.CHEST_SCALE
			local angle = math.rad(7 + (i * 3)) * ((i % 2 == 0) and 1 or -1)
			-- up: stretch
			table.insert(steps, { ins = aCF, twinfo = TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				prop = { Value = targetCF * CFrame.new(0, jumpH, 0) * CFrame.Angles(angle, 0, 0) }, nowait = true, fov = i })
			table.insert(steps, { ins = aScale, twinfo = TweenInfo.new(dur, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				prop = { Value = Vector3.new(0.8, 1.4, 0.8) } })
			-- down: squash
			table.insert(steps, { ins = aCF, twinfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				prop = { Value = targetCF * CFrame.Angles(-angle / 2, 0, 0) }, nowait = true })
			table.insert(steps, { ins = aScale, twinfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				prop = { Value = Vector3.new(1.3, 0.6, 1.3) }, impact = i })
			-- settle
			table.insert(steps, { ins = aCF, twinfo = TweenInfo.new(0.1, Enum.EasingStyle.Sine), prop = { Value = targetCF }, nowait = true })
			table.insert(steps, { ins = aScale, twinfo = TweenInfo.new(0.1, Enum.EasingStyle.Sine), prop = { Value = Vector3.one }, times = 0.1 })
		end

		local bounce = TweenM.new(steps)
		bounce.onstep = function(step)
			if step.fov and isLocal then fovSet(step.fov * 6, 0.5, Enum.EasingStyle.Sine) end
			if step.impact then task.delay(0.08, impact, step.impact) end -- lands a hair after the squash starts
		end
		bounce:Play(false)

		c1:Disconnect() c2:Disconnect() aCF:Destroy() aScale:Destroy()
		rig:Pose(targetCF)

		-- ---------- 3) CHARGE: chest rumbles, light builds ----------
		local chargeLight = Instance.new("PointLight")
		chargeLight.Color, chargeLight.Range, chargeLight.Brightness = GOLD, 14 * CONFIG.CHEST_SCALE, 0
		chargeLight.Parent = base
		TweenService:Create(chargeLight, TweenInfo.new(CONFIG.CHARGE_TIME), { Brightness = 4 }):Play()

		local t0 = os.clock()
		while os.clock() - t0 < CONFIG.CHARGE_TIME do
			local a = (os.clock() - t0) / CONFIG.CHARGE_TIME
			local amp = 0.04 + 0.12 * a
			rig:Pose(targetCF * CFrame.new((math.random() - 0.5) * amp * 2, 0, (math.random() - 0.5) * amp * 2) * CFrame.Angles(0, 0, (math.random() - 0.5) * amp * 0.4))
			task.wait()
		end
		rig:Pose(targetCF)

		-- ---------- 4) LID OPENS + LuckyBlockOpening sound ----------
		local chestTop = targetCF.Position + Vector3.new(0, H / 2, 0)
		local soundLen = (lbSound and lbSound.TimeLength > 0) and lbSound.TimeLength or 5.1
		if CONFIG.PLAY_LUCKYBLOCK_SOUND then playSound(chestTop, lbSound, nil, nil, isLocal) end

		local lidHolder = burst(chestTop + Vector3.new(0, 1, 0) * CONFIG.CHEST_SCALE, GOLD, 30, 22)
		flashLight(lidHolder, GOLD, 5)
		shakeNear("Bump", chestTop)
		TweenService:Create(chargeLight, TweenInfo.new(0.8), { Brightness = 0 }):Play()

		if rig.top then
			local lidValue = newValue("NumberValue", 0)
			lidValue.Changed:Connect(function(v)
				rig.lidAngle = v
				rig:Pose(targetCF)
			end)
			TweenM.new({
				{ ins = lidValue, twinfo = TweenInfo.new(0.8, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), prop = { Value = math.rad(75) } },
			}):Play(true)
			Misc.Debris(lidValue, 2)
		end

		-- no reward (should not happen): just clean up
		if not wonWeaponName then
			ack()
			releaseFov()
			Misc.Debris(clone, 2)
			return
		end

		-- ---------- 5) ROULETTE ----------
		local display = newDisplay(chestTop, isLocal)
		table.insert(junk, display.anchor)
		display:Update(0)
		local s = time()
		local await = 2
		local animTime = 1
		local updateConn = RunService.Heartbeat:Connect(function(dt)
			display:Update(dt)
			if isLocal then
				local elapsed = time() - s
				local alpha = math.clamp((elapsed - await) / animTime, 0, 1)
				local value = TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				display.LocalPlayerCameraProgress = value
			end
		end)
		table.insert(junk, updateConn)

		TweenService:Create(display.lift, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = CONFIG.DISPLAY_HEIGHT }):Play()

		local R = CONFIG.ROULETTE
		local wheelSound = findPath(SoundService, "OpenSound", "WheelSpin")
		local rouletteDur = R.DURATION
		if isLocal then fovSet(R.ZOOM, rouletteDur + R.SUSPENSE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut) end

		local all = getAllWeaponNames()
		local teaser = pickTeaser(fx.rank)
		local teased, lastName, swaps = false, nil, 0
		local startR = os.clock()

		-- WheelSpin loops for as long as the weapons swap
		local wheelLoop = startLoop(chestTop, wheelSound, isLocal)
		if wheelLoop then table.insert(junk, wheelLoop.Parent) end

		while #all > 0 and os.clock() - startR < rouletteDur do
			local progress = math.clamp((os.clock() - startR) / rouletteDur, 0, 1)
			local name
			if teaser and not teased and progress > 0.85 then
				name, teased = teaser, true
			else
				repeat name = all[math.random(#all)] until name ~= lastName or #all < 2
			end
			lastName = name
			swaps += 1

			display:Set(name, R.GHOST)
			display.pop.Value = 0.65
			TweenService:Create(display.pop, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = 1 }):Play()

			-- every swap: a little rumble that grows as the roulette goes on
			rumble(chestTop, 0.35 + progress * 1.6, 14, 0.15)
			-- every few swaps: sparks in the colour of the weapon that is showing
			if swaps % 3 == 0 then
				local winfo = WeaponConfig.GetWeaponInfo(name)
				burst(display.anchor.Position, winfo and winfo.RarityColor or GOLD, 6, 12)
			end

			if wheelLoop then
				wheelLoop.PlaybackSpeed = CONFIG.WHEEL_PITCH_START + (CONFIG.WHEEL_PITCH_END - CONFIG.WHEEL_PITCH_START) * progress
			end
			if isLocal then playSound(chestTop, tickSound, 1 + progress * 0.5, 0.6, true) end

			-- fast the whole time, brakes only at the very end
			task.wait(R.MIN_SWAP + (R.MAX_SWAP - R.MIN_SWAP) * progress ^ 5)
		end

		stopLoop(wheelLoop, 0.2)

		-- the result is shown solid, swells and shakes harder = anticipation, then the reveal
		local hasModel = display:Set(wonWeaponName, R.GHOST)
		TweenService:Create(display.spin, TweenInfo.new(R.SUSPENSE, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 14 }):Play()
		TweenService:Create(display.mul, TweenInfo.new(R.SUSPENSE, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 1.3 }):Play()
		local suspenseStart = os.clock()
		while os.clock() - suspenseStart < R.SUSPENSE do
			rumble(chestTop, 1.2 + ((os.clock() - suspenseStart) / R.SUSPENSE) * 2.5, 18, 0.2)
			task.wait(0.12)
		end

		revealAndFinish(display, updateConn, hasModel, ground, targetCF, clone)
	end)

	if not ok then
		warn("[ChestController] opening animation failed: " .. tostring(err))
		ack() -- never let the player lose the weapon because of a visual error
		releaseFov()
		for _, j in junk do
			if typeof(j) == "Instance" then j:Destroy()
			elseif typeof(j) == "RBXScriptConnection" then j:Disconnect() end
		end
	end
end

-- ==========================================
-- INIT
-- ==========================================
function ChestController.Init()
	OpenChestEvent.OnClientEvent:Connect(function(...)
		task.spawn(playChestOpenAnimation, ...)
	end)
end

return ChestController
