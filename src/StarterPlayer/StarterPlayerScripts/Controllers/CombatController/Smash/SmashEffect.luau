-- SmashEffect (CLIENT ModuleScript) -> inside the CombatController ModuleScript.
-- V3: no black shadow, no black scorch / cracks. What you SEE for the Smash ability:
--   * StartTelegraph()  TORNADO (Assets.VFX.TornadoJumpEffect) under the smasher's feet while he is in the air,
--                       follows him all the way down + a soft orange glow that grows while he charges
--   * Takeoff()         dust puff + Assets.VFX.JumpEffect at the feet
--   * Dive()            low whoosh
--   * Impact()          white shock ring + dust ring, dust dome + column, sparks, ground rocks, flying chunks,
--                       light flash, Assets.VFX.HitEffect, sound, and a self-contained camera shake

local SmashEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local CONFIG = {
	TORNADO = true,                              -- tornado under the smasher while he is in the air
	TORNADO_OFFSET = Vector3.new(0, 0.5, 0),     -- relative to the feet (studs); raise it to wrap the body
	GLOW = true,                                 -- soft orange glow on the smasher that grows while he charges
	JUMP_TEMPLATE = "JumpEffect",                -- Assets.VFX.<name> played at the feet on take-off ("" = off)
	IMPACT_TEMPLATE = "HitEffect",               -- Assets.VFX.<name> played at the landing point ("" = off)
	SCARS = false,                               -- black scorch mark + cracks on the floor (off: they looked dirty)

	SHAKE_DISTANCE = 100,       -- players farther than this feel no shake
	CASTER_SHAKE = 7,           -- shake strength for the smasher (higher = stronger)
	OTHERS_SHAKE = 5,           -- shake strength right next to the impact for everybody else
	SHAKE_TIME = 1.0,           -- seconds
	CHUNKS = 18,                -- flying rock chunks
	CRACKS = 10,                -- radial cracks (only when SCARS = true)
}

local GroundRock = nil
local shakes, shakeBound = {}, false
local telegraphs = {} -- [Player] = { stop = function, startedAt = number }

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

local function newPart(position, size)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	part.Size = size or Vector3.one
	part.Position = position
	part.Parent = getFolder()
	return part
end

local function groundInfo(position, ignore)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { getFolder(), ignore }
	local hit = Workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
	if hit and hit.Instance then
		return hit.Position, hit.Instance.Color, hit.Instance.Material
	end
	return position, Color3.fromRGB(150, 140, 125), Enum.Material.Slate
end

local function playSound(position, pitch, volume)
	local effects = SoundService:FindFirstChild("Effects")
	local source = effects and effects:FindFirstChild("Rock")
	if not source or not source:IsA("Sound") then return end
	local holder = newPart(position)
	local sfx = source:Clone()
	sfx.PlaybackSpeed = pitch or 1
	sfx.Volume = sfx.Volume * (volume or 1)
	sfx.Parent = holder
	sfx.Ended:Once(function() holder:Destroy() end)
	Debris:AddItem(holder, 8)
	sfx:Play()
end

-- ==========================================
-- VFX TEMPLATES (ReplicatedStorage.Assets.VFX)
-- ==========================================
local function getVfx(name)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfx = assets and assets:FindFirstChild("VFX")
	return vfx and vfx:FindFirstChild(name)
end

-- the BasePart that carries the emitters: the template itself, or the part inside a Model
-- (TornadoJumpEffect > Tornado-01 > Main (Attachment) > Impact1, Impact2, Windspin1..5)
local function vfxPart(template)
	if not template then return nil end
	if template:IsA("BasePart") then return template end
	return template:FindFirstChild("Tornado-01") or template:FindFirstChildWhichIsA("BasePart", true)
end

-- plays a one-shot template at a position: burst emitters Emit(), running emitters stay on for `duration`
local function playTemplate(name, position, duration)
	if not name or name == "" then return end
	local source = vfxPart(getVfx(name))
	if not source then return end

	local part = source:Clone()
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.CFrame = CFrame.new(position)
	part.Parent = getFolder()

	local running = {}
	for _, item in part:GetDescendants() do
		if item:IsA("ParticleEmitter") then
			if item.Enabled and item.Rate > 0 then
				table.insert(running, item)
			else
				item:Emit(item:GetAttribute("EmitCount") or 12)
			end
		end
	end
	task.delay(duration or 0.8, function()
		for _, emitter in running do emitter.Enabled = false end
	end)
	Debris:AddItem(part, (duration or 0.8) + 3)
end

-- ==========================================
-- CAMERA SHAKE (self-contained: noise based, decays smoothly, runs after the camera script)
-- ==========================================
local function stepShake()
	local camera = Workspace.CurrentCamera
	if not camera or #shakes == 0 then return end
	local now = os.clock()
	local pos, rot = Vector3.zero, Vector3.zero
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		local alpha = (now - s.t0) / s.duration
		if alpha >= 1 then
			table.remove(shakes, i)
		else
			local fade = (1 - alpha) ^ 2
			local n = now * s.roughness
			local nx = math.noise(n, s.seed, 0)
			local ny = math.noise(s.seed, n, 1)
			local nz = math.noise(n, n, s.seed)
			pos += Vector3.new(nx, ny, nz) * (s.magnitude * 0.25 * fade)
			rot += Vector3.new(ny, nx, nz) * (s.magnitude * 1.2 * fade)
		end
	end
	camera.CFrame = camera.CFrame
		* CFrame.new(pos)
		* CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
end

local function addShake(magnitude, duration, roughness)
	if magnitude <= 0.05 then return end
	table.insert(shakes, {
		t0 = os.clock(), duration = duration, magnitude = magnitude,
		roughness = roughness or 26, seed = math.random() * 100,
	})
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep("SmashCameraShake", Enum.RenderPriority.Camera.Value + 1, stepShake)
	end
end

local function shakeAt(position, strength)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance > CONFIG.SHAKE_DISTANCE then return end
	local falloff = 1 - distance / CONFIG.SHAKE_DISTANCE
	addShake(strength * (0.25 + 0.75 * falloff), CONFIG.SHAKE_TIME)
	addShake(strength * 0.5 * falloff, CONFIG.SHAKE_TIME * 0.45, 45) -- fast rattle on top of the slow heave
end

-- ==========================================
-- BUILDING BLOCKS
-- ==========================================
local function burst(position, color, count, speed, spread, size, lifetime)
	local holder = newPart(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = lifetime or NumberRange.new(0.5, 1)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = spread or Vector2.new(85, 85)
	emitter.Acceleration = Vector3.new(0, -25, 0)
	emitter.Drag = 3
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-120, 120)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size or 2), NumberSequenceKeypoint.new(1, (size or 2) * 3) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(holder, 2.5)
	return holder
end

-- flat expanding ring; neon = bright thin energy ring, otherwise a soft dust ring
local function ring(position, color, size, duration, thickness, neon, startTransparency)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Material = neon and Enum.Material.Neon or Enum.Material.SmoothPlastic
	part.Color = color
	part.Transparency = startTransparency or 0.3
	part.Size = Vector3.new(thickness, 1, 1)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = getFolder()
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(thickness, size, size), Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

local function flash(position, peak)
	local holder = newPart(position + Vector3.new(0, 2, 0))
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = Color3.fromRGB(255, 235, 210), 45, peak
	light.Parent = holder
	TweenService:Create(light, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
	Debris:AddItem(holder, 0.6)
end

local function chunks(position, radius, color, material)
	local folder = getFolder()
	for _ = 1, CONFIG.CHUNKS do
		local size = 0.5 + math.random() * 1.2
		local part = Instance.new("Part")
		part.Size = Vector3.new(size, size, size) * (0.8 + math.random() * 0.5)
		part.Color, part.Material = color, material
		part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = false, false, false, true
		local angle = math.random() * math.pi * 2
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * (math.random() * radius * 0.35)
		part.CFrame = CFrame.new(position + offset + Vector3.new(0, 0.6, 0)) * CFrame.Angles(math.random() * 6, math.random() * 6, 0)
		part.Parent = folder
		local out = 8 + math.random() * 24
		part.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * out, 34 + math.random() * 28, math.sin(angle) * out)
		part.AssemblyAngularVelocity = Vector3.new(math.random(-12, 12), math.random(-12, 12), math.random(-12, 12))
		task.delay(0.75, function()
			if part.Parent then
				TweenService:Create(part, TweenInfo.new(0.3), { Size = Vector3.zero, Transparency = 1 }):Play()
			end
		end)
		Debris:AddItem(part, 1.15)
	end
end

local function rocks(position, radius, ignore)
	if not GroundRock then return end
	local origin = newPart(position)
	-- Circle(Preset, RockMultiple, Scale, TimeLength, Ignore, Origin, castdis, Parent)
	local ok, err = pcall(GroundRock.Circle, "Normal", 1, math.max(0.8, radius / 10), 3.5, ignore or getFolder(), origin, 14, getFolder())
	if not ok then warn("[SmashEffect] GroundRock failed:", err) end
	Debris:AddItem(origin, 5)
end

-- dark scorch circle + radial cracks burned into the floor (only when CONFIG.SCARS = true)
local function scarring(position, radius)
	local folder = getFolder()
	local up = Vector3.new(0, 0.07, 0)

	local scorch = Instance.new("Part")
	scorch.Shape = Enum.PartType.Cylinder
	scorch.Anchored, scorch.CanCollide, scorch.CanTouch, scorch.CanQuery, scorch.CastShadow = true, false, false, false, false
	scorch.Material = Enum.Material.Slate
	scorch.Color = Color3.fromRGB(25, 22, 20)
	scorch.Transparency = 0.25
	scorch.Size = Vector3.new(0.06, 1, 1)
	scorch.CFrame = CFrame.new(position + up) * CFrame.Angles(0, 0, math.pi / 2)
	scorch.Parent = folder
	TweenService:Create(scorch, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.06, radius * 0.85, radius * 0.85),
	}):Play()
	task.delay(2.4, function()
		if scorch.Parent then TweenService:Create(scorch, TweenInfo.new(1), { Transparency = 1 }):Play() end
	end)
	Debris:AddItem(scorch, 3.6)

	for i = 1, CONFIG.CRACKS do
		local angle = (i / CONFIG.CRACKS) * math.pi * 2 + (math.random() - 0.5) * 0.4
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local length = radius * (0.55 + math.random() * 0.5)
		local width = 0.25 + math.random() * 0.3
		local origin = position + up * 1.5
		local crack = Instance.new("Part")
		crack.Anchored, crack.CanCollide, crack.CanTouch, crack.CanQuery, crack.CastShadow = true, false, false, false, false
		crack.Material = Enum.Material.Slate
		crack.Color = Color3.fromRGB(12, 10, 10)
		crack.Size = Vector3.new(width, 0.05, 0.1)
		crack.CFrame = CFrame.lookAt(origin, origin + direction)
		crack.Parent = folder
		TweenService:Create(crack, TweenInfo.new(0.22 + math.random() * 0.12, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = Vector3.new(width, 0.05, length),
			CFrame = CFrame.lookAt(origin, origin + direction) * CFrame.new(0, 0, -length / 2),
		}):Play()
		task.delay(2.6, function()
			if crack.Parent then TweenService:Create(crack, TweenInfo.new(1), { Transparency = 1 }):Play() end
		end)
		Debris:AddItem(crack, 3.8)
	end
end

-- ==========================================
-- PUBLIC
-- ==========================================
function SmashEffect.Init(_unused)
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 5)
	local vfx = shared and shared:WaitForChild("VFXUtils", 5)
	local module = vfx and vfx:FindFirstChild("GroundRock")
	if module then
		local ok, result = pcall(require, module)
		GroundRock = ok and result or nil
	end
end

-- dust puff + JumpEffect at the feet when the smasher jumps
function SmashEffect.Takeoff(position)
	local ground, color = groundInfo(position)
	burst(ground + Vector3.new(0, 0.4, 0), color:Lerp(Color3.fromRGB(230, 220, 200), 0.6), 16, 24, Vector2.new(80, 80), 1.8)
	ring(ground, Color3.new(1, 1, 1), 10, 0.35, 0.2, true, 0.5)
	playTemplate(CONFIG.JUMP_TEMPLATE, ground + Vector3.new(0, 0.5, 0), 0.8)
	playSound(ground, 1.4, 0.5)
	shakeAt(ground, 1.2)
end

-- low whoosh when the smasher starts diving
function SmashEffect.Dive(position)
	local sfx = SoundService:FindFirstChild("SFX")
	local source = sfx and sfx:FindFirstChild("Dash")
	if not source or not source:IsA("Sound") then return end
	local holder = newPart(position)
	local sound = source:Clone()
	sound.PlaybackSpeed = 0.6
	sound.Parent = holder
	sound.Ended:Once(function() holder:Destroy() end)
	Debris:AddItem(holder, 4)
	sound:Play()
end

-- The smasher is in the air: TORNADO under his feet (follows him all the way down) + a growing orange glow.
-- Runs on every client (the server broadcasts SmashStart); the smasher also starts it locally for instant feedback.
function SmashEffect.StartTelegraph(caster: Player, character: Model, radius)
	local existing = telegraphs[caster]
	if existing and os.clock() - existing.startedAt < 1.5 then return end -- the smasher already started it
	SmashEffect.StopTelegraph(caster)

	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return end

	local standOffset = humanoid.HipHeight + root.Size.Y / 2
	if humanoid.RigType == Enum.HumanoidRigType.R6 then standOffset += 2 end
	local function feetPosition()
		return root.Position - Vector3.new(0, standOffset, 0) + CONFIG.TORNADO_OFFSET
	end

	local startedAt = os.clock()
	local running = true

	-- soft glow on the smasher
	local glow = nil
	if CONFIG.GLOW then
		glow = Instance.new("Highlight")
		glow.Adornee = character
		glow.FillColor = Color3.fromRGB(255, 170, 60)
		glow.OutlineColor = Color3.fromRGB(255, 240, 200)
		glow.FillTransparency = 0.9
		glow.OutlineTransparency = 0.5
		glow.DepthMode = Enum.HighlightDepthMode.Occluded
		glow.Parent = getFolder()
	end

	-- tornado: Impact* emitters burst once, everything else (Windspin*) keeps running while he is in the air
	local tornado, loops, pulsed = nil, {}, {}
	local template = CONFIG.TORNADO and vfxPart(getVfx("TornadoJumpEffect")) or nil
	if template then
		tornado = template:Clone()
		tornado.Anchored, tornado.CanCollide, tornado.CanTouch, tornado.CanQuery, tornado.CastShadow = true, false, false, false, false
		tornado.CFrame = CFrame.new(feetPosition())
		tornado.Parent = getFolder()
		for _, item in tornado:GetDescendants() do
			if item:IsA("ParticleEmitter") then
				if string.find(item.Name, "Impact") then
					item.Enabled = false
					item:Emit(item:GetAttribute("EmitCount") or 15)
				else
					item.Enabled = true
					table.insert(loops, item)
					if item.Rate <= 0 then table.insert(pulsed, item) end -- emitters that only work through Emit()
				end
			end
		end
	end

	local connection
	local function stop()
		if not running then return end
		running = false
		if connection then connection:Disconnect() connection = nil end
		if glow then
			TweenService:Create(glow, TweenInfo.new(0.25), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
			Debris:AddItem(glow, 0.3)
		end
		if tornado then
			for _, emitter in loops do emitter.Enabled = false end
			Debris:AddItem(tornado, 2.5) -- let the last particles fade out
		end
		if telegraphs[caster] and telegraphs[caster].stop == stop then telegraphs[caster] = nil end
	end
	telegraphs[caster] = { stop = stop, startedAt = startedAt }

	connection = RunService.RenderStepped:Connect(function()
		if not root.Parent then stop() return end
		local charge = math.clamp((os.clock() - startedAt) / 2.2, 0, 1)
		if tornado then tornado.CFrame = CFrame.new(feetPosition()) end
		if glow then glow.FillTransparency = 0.9 - 0.35 * charge + math.sin(os.clock() * 14) * 0.04 end
	end)

	if #pulsed > 0 then
		task.spawn(function()
			while running do
				for _, emitter in pulsed do emitter:Emit(emitter:GetAttribute("EmitCount") or 1) end
				task.wait(0.35)
			end
		end)
	end

	-- the other players also see the take-off dust (the smasher plays his own from SmashClient)
	if caster ~= Players.LocalPlayer :: Player then
		SmashEffect.Takeoff(root.Position - Vector3.new(0, standOffset, 0))
	end

	task.delay(7, stop)
end

function SmashEffect.StopTelegraph(caster)
	local entry = telegraphs[caster]
	if entry then entry.stop() end
end

-- the landing. position = ground point, radius = hit radius, ignore = smasher's character, isCaster = local smasher
function SmashEffect.Impact(position: Vector3, radius: number, ignore: boolean?, isCaster: boolean?)
	local ground, color, material = groundInfo(position, ignore)
	local dust = color:Lerp(Color3.fromRGB(215, 200, 175), 0.75) -- light dust, never dark

	flash(ground, 7)
	ring(ground, Color3.new(1, 1, 1), radius * 2.4, 0.4, 0.3, true, 0.15)       -- thin bright shock ring
	ring(ground, dust, radius * 3, 0.8, 0.5, false, 0.35)                        -- big soft dust ring
	burst(ground + Vector3.new(0, 0.5, 0), dust, 45, 40, Vector2.new(85, 85), 3.2)                       -- dust dome
	burst(ground + Vector3.new(0, 0.5, 0), dust, 14, 55, Vector2.new(14, 14), 4.5, NumberRange.new(0.7, 1.2)) -- dust column
	burst(ground + Vector3.new(0, 0.6, 0), Color3.new(1, 1, 1), 16, 60, Vector2.new(60, 60), 0.6)         -- white sparks
	playTemplate(CONFIG.IMPACT_TEMPLATE, ground + Vector3.new(0, 0.5, 0), 0.8)
	if CONFIG.SCARS then scarring(ground, radius) end
	rocks(ground, radius, ignore)
	chunks(ground, radius, color, material)

	playSound(ground, 0.75, 1.2)
	task.delay(0.06, playSound, ground, 0.55, 1)

	if isCaster then
		addShake(CONFIG.CASTER_SHAKE, CONFIG.SHAKE_TIME)
		addShake(CONFIG.CASTER_SHAKE * 0.5, CONFIG.SHAKE_TIME * 0.45, 45)
	else
		shakeAt(ground, CONFIG.OTHERS_SHAKE)
	end
end

-- small camera rumble (used while the smasher hangs in the air: tension builds up)
function SmashEffect.Rumble(magnitude, duration)
	addShake(magnitude, duration or 0.3, 18)
end

return SmashEffect