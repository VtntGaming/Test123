-- ForceFX (CLIENT ModuleScript) -> put it INSIDE the CombatController ModuleScript (script.ForceFX).
-- Shared building blocks of PushEffect and PullEffect:
--   camera shake, particle bursts, rings that travel, wind streaks (trails), ground dust in a cone,
--   tether beam, pulsing glow, screen flash, positional sounds. Everything is code-made (no assets needed).

local ForceFX = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local shakes, shakeBound = {}, false
local flashFrame = nil

-- ==========================================
-- BASICS
-- ==========================================
function ForceFX.Folder()
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
	part.Parent = ForceFX.Folder()
	return part
end
ForceFX.NewPart = newPart

function ForceFX.HandPosition(character)
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then return hand.Position end
	local root = character:FindFirstChild("HumanoidRootPart")
	return root and (root.Position + Vector3.new(0, 1, 0)) or Vector3.zero
end

-- ==========================================
-- SOUND
-- ==========================================
local function findSound(name)
	if not name or name == "" then return nil end
	for _, folderName in { "SFX", "Effects" } do
		local folder = SoundService:FindFirstChild(folderName)
		local sound = folder and folder:FindFirstChild(name)
		if sound and sound:IsA("Sound") then return sound end
	end
	return nil
end

function ForceFX.PlaySoundAt(name, position, pitch, volume)
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
			local nx, ny, nz = math.noise(n, s.seed, 0), math.noise(s.seed, n, 1), math.noise(n, n, s.seed)
			pos += Vector3.new(nx, ny, nz) * (s.magnitude * 0.25 * fade)
			rot += Vector3.new(ny, nx, nz) * (s.magnitude * 1.2 * fade)
		end
	end
	camera.CFrame = camera.CFrame * CFrame.new(pos) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
end

function ForceFX.Shake(magnitude, duration, roughness)
	if magnitude <= 0.05 then return end
	table.insert(shakes, {
		t0 = os.clock(), duration = duration or 0.5, magnitude = magnitude,
		roughness = roughness or 26, seed = math.random() * 100,
	})
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep("ForceCameraShake", Enum.RenderPriority.Camera.Value + 1, stepShake)
	end
end

-- shake that fades with the distance between the camera and the event
function ForceFX.ShakeAt(position, magnitude, duration, maxDistance)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	maxDistance = maxDistance or 90
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance > maxDistance then return end
	ForceFX.Shake(magnitude * (0.3 + 0.7 * (1 - distance / maxDistance)), duration)
end

-- ==========================================
-- PARTICLES / SHAPES
-- ==========================================
-- direction (optional): the burst is a cone flying that way; without it the burst is a dome going up
function ForceFX.Burst(position, color, count, speed, spread, size, direction)
	local holder = newPart(position)
	if direction then holder.CFrame = CFrame.lookAt(position, position + direction) end
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.35, 0.8)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.EmissionDirection = if direction then Enum.NormalId.Front else Enum.NormalId.Top
	emitter.SpreadAngle = spread or Vector2.new(85, 85)
	emitter.Acceleration = Vector3.new(0, -12, 0)
	emitter.Drag = 3
	emitter.LightEmission = 0.6
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-120, 120)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size or 1.5), NumberSequenceKeypoint.new(1, (size or 1.5) * 2.5) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(holder, 2)
	return holder
end

-- thin disc facing `direction` (flat direction), growing / shrinking from fromSize to toSize while it
-- travels `travel` studs along the direction (negative = towards the start)
function ForceFX.Ring(position, direction, color, fromSize, toSize, duration, travel)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.2
	part.Size = Vector3.new(0.25, fromSize, fromSize)
	-- a cylinder's long axis is X: turn it so X points along `direction`
	local function frame(distance)
		local at = position + direction * distance
		return CFrame.lookAt(at, at + direction) * CFrame.Angles(0, math.pi / 2, 0)
	end
	part.CFrame = frame(0)
	part.Parent = ForceFX.Folder()
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.25, toSize, toSize), CFrame = frame(travel or 0), Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

-- flat ring lying on the ground
function ForceFX.GroundRing(position, color, size, duration, thickness)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.25
	part.Size = Vector3.new(thickness or 0.2, 1, 1)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = ForceFX.Folder()
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(thickness or 0.2, size, size), Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

-- a thin streak of wind: an invisible part flies along `direction` and leaves a Trail ribbon behind it
function ForceFX.WindLine(startPosition, direction, distance, duration, color, width)
	local part = newPart(startPosition)
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	local half = (width or 0.3) / 2
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Position, a1.Position = Vector3.new(0, half, 0), Vector3.new(0, -half, 0)
	a0.Parent, a1.Parent = part, part
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.3
	trail.MinLength = 0.02
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
	trail.Parent = part
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = startPosition + direction * distance,
	}):Play()
	Debris:AddItem(part, duration + 0.5)
end

-- dust kicked up on the ground along a cone, one puff after the other (inward = from far to near)
function ForceFX.DustCone(origin, direction, range, halfAngle, inward, ignore)
	local right = direction:Cross(Vector3.yAxis)
	right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ForceFX.Folder(), ignore }
	local steps = math.max(3, math.floor(range / 4))
	for i = 1, steps do
		local alpha = i / steps
		local distance = range * alpha
		local lateral = right * (math.random() * 2 - 1) * math.tan(math.rad(math.min(halfAngle, 80))) * distance * 0.6
		local point = origin + direction * distance + lateral
		local delay = (if inward then 1 - alpha else alpha) * 0.28
		task.delay(delay, function()
			local hit = Workspace:Raycast(point + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), params)
			if not hit then return end
			local color = hit.Instance.Color:Lerp(Color3.fromRGB(220, 210, 190), 0.7)
			ForceFX.Burst(hit.Position + Vector3.new(0, 0.3, 0), color, 6, 14, Vector2.new(70, 70), 1.6)
		end)
	end
end

function ForceFX.Flash(position, color, peak)
	local holder = newPart(position)
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = color, 24, peak
	light.Parent = holder
	TweenService:Create(light, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
	Debris:AddItem(holder, 0.5)
end

-- glowing rope between two parts that thins out and vanishes
function ForceFX.Tether(fromPart, toPart, color, duration)
	if not fromPart or not toPart then return end
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Parent, a1.Parent = fromPart, toPart
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Width0, beam.Width1 = 0.9, 0.9
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Segments = 14
	beam.CurveSize0, beam.CurveSize1 = 3, -3
	beam.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(0.5, color),
		ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
	})
	beam.Transparency = NumberSequence.new(0.1)
	beam.Parent = fromPart
	TweenService:Create(beam, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Width0 = 0, Width1 = 0 }):Play()
	Debris:AddItem(beam, duration + 0.1)
	Debris:AddItem(a0, duration + 0.2)
	Debris:AddItem(a1, duration + 0.2)
end

-- pulsing coloured body glow; returns stop(fadeTime)
function ForceFX.Glow(character, color, outlineColor)
	local highlight = Instance.new("Highlight")
	highlight.Adornee = character
	highlight.FillColor = color
	highlight.OutlineColor = outlineColor or color
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 0.6
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = ForceFX.Folder()
	local startedAt = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		local t = os.clock() - startedAt
		highlight.FillTransparency = 0.85 - math.clamp(t / 0.4, 0, 1) * 0.3 + math.sin(t * 22) * 0.05
	end)
	return function(fadeTime)
		connection:Disconnect()
		fadeTime = fadeTime or 0.2
		TweenService:Create(highlight, TweenInfo.new(fadeTime), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		Debris:AddItem(highlight, fadeTime + 0.1)
	end
end

function ForceFX.ScreenFlash(color, startTransparency, duration)
	if not flashFrame or not flashFrame.Parent then
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then return end
		local gui = Instance.new("ScreenGui")
		gui.Name = "ForceFlash"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 58
		gui.Parent = playerGui
		flashFrame = Instance.new("Frame")
		flashFrame.Size = UDim2.fromScale(1, 1)
		flashFrame.BorderSizePixel = 0
		flashFrame.BackgroundTransparency = 1
		flashFrame.Parent = gui
	end
	flashFrame.BackgroundColor3 = color
	flashFrame.BackgroundTransparency = startTransparency
	TweenService:Create(flashFrame, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

return ForceFX