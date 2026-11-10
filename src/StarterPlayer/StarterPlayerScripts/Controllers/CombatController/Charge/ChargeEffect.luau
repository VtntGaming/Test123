-- ChargeEffect (CLIENT ModuleScript) V2 -> inside the CombatController, folder "Charge", next to ChargeClient.
-- Runs on EVERY client (server broadcasts ChargeStart / ChargeEnd / ChargeImpact) and ALSO instantly on the charger
-- himself (ChargeClient starts it locally, so you see it even before the server answers).
--   * RED pulsing highlight on the charger, visible through walls  -> "dodge him!"
--   * Assets.VFX.Charge (ChargeFF + emitters) follows him; burst emitters fire once, the rest keep running
--   * NEW: red/white speed ribbon (Trail) + red energy puffs around his body (works even if the template is missing)
--   * NEW: camera rumble while the charger runs, bigger shake on every hit (self-contained, no other module needed)
--   * red after-images, light dust at the feet, dust skid at the end, impact sparks + sound on every hit

local ChargeEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local CONFIG = {
	COLOR = Color3.fromRGB(255, 45, 45),
	OUTLINE = Color3.fromRGB(255, 130, 130),
	ALWAYS_ON_TOP = true,                        -- red silhouette visible through walls so nobody misses him
	FILL_TRANSPARENCY = 0.55,
	PULSE_SPEED = 16,

	VFX_TEMPLATE = "Charge",                     -- Assets.VFX.<name> (contains the ChargeFF part)
	VFX_OFFSET = CFrame.new(0, 0, 0),            -- relative to HumanoidRootPart; only used when the template has no Weld
	BURST_NAMES = { "impact", "cresent", "crescent" }, -- emitters whose name contains one of these fire once instead of looping

	TRAIL = true,                                -- speed ribbon behind him (everybody sees it)
	AURA = true,                                 -- red energy puffs around his body
	AFTERIMAGES = true,
	AFTERIMAGE_INTERVAL = 0.06,
	DUST = true,
	START_BURST = true,                          -- dust burst + thin ring when the charge begins

	RUMBLE = 0.9,                                -- camera rumble of the CHARGER while he runs (0 = off)
	START_SOUND = "ChargeSound",                        -- name inside SoundService.SFX or SoundService.Effects ("" = none)
	HIT_SOUND = "Rock",
	SHAKE_DISTANCE = 80,                         -- other players farther than this feel no shake
	DEBUG = true,                                -- prints what the template contains / when it is missing
}

local active = {} -- [Player] = { stop = function, impacts = { ParticleEmitter }, startedAt = number }
local victimFrame = nil
local warnedTemplate = false
local shakes, sustain, shakeBound = {}, 0, false

-- ==========================================
-- CAMERA SHAKE (self-contained)
-- ==========================================
local function stepShake()
	local camera = Workspace.CurrentCamera
	if not camera or (#shakes == 0 and sustain <= 0) then return end
	local now = os.clock()
	local pos, rot = Vector3.zero, Vector3.zero
	if sustain > 0 then -- constant rumble while running
		local n = now * 30
		local nx, ny, nz = math.noise(n, 1.7, 0), math.noise(2.3, n, 1), math.noise(n, n, 3.1)
		pos += Vector3.new(nx, ny, nz) * (sustain * 0.12)
		rot += Vector3.new(ny, nx, nz) * (sustain * 0.5)
	end
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

local function bindShake()
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep("ChargeCameraShake", Enum.RenderPriority.Camera.Value + 1, stepShake)
	end
end

local function addShake(magnitude, duration, roughness)
	if magnitude <= 0.05 then return end
	table.insert(shakes, { t0 = os.clock(), duration = duration, magnitude = magnitude, roughness = roughness or 26, seed = math.random() * 100 })
	bindShake()
end

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

-- the BasePart that carries the emitters: the template itself, or ChargeFF inside the Model
local function getVfxPart(name)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfx = assets and assets:FindFirstChild("VFX")
	local template = vfx and vfx:FindFirstChild(name)
	if not template then return nil end
	if template:IsA("BasePart") then return template end
	return template:FindFirstChild("ChargeFF") or template:FindFirstChildWhichIsA("BasePart", true)
end

-- the template's own Weld says where the effect belongs relative to the character; we read the offset
local function templateOffset(part)
	local weld = part:FindFirstChildOfClass("Weld")
	if not weld then return CONFIG.VFX_OFFSET end
	local offset
	if weld.Part0 == part then
		offset = weld.C1 * weld.C0:Inverse()
	else
		offset = weld.C0 * weld.C1:Inverse()
	end
	weld:Destroy()
	return offset
end

local function isBurst(lowerName)
	for _, pattern in CONFIG.BURST_NAMES do
		if string.find(lowerName, pattern, 1, true) then return true end
	end
	return false
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
	Debris:AddItem(holder, 8)
	sound:Play()
end

local function cameraNear(position)
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - position).Magnitude <= CONFIG.SHAKE_DISTANCE
end

local function burst(position, color, count, speed, spread, size)
	local holder = newPart(position)
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.4, 0.9)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = spread or Vector2.new(85, 85)
	emitter.Acceleration = Vector3.new(0, -25, 0)
	emitter.Drag = 3
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-120, 120)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size or 1.5), NumberSequenceKeypoint.new(1, (size or 1.5) * 2.5) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = attachment
	emitter:Emit(count)
	Debris:AddItem(holder, 2)
end

-- thin white expanding ring (no fat colored circle)
local function ring(position, size, duration)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
	part.Material = Enum.Material.Neon
	part.Color = Color3.new(1, 1, 1)
	part.Transparency = 0.35
	part.Size = Vector3.new(0.2, 1, 1)
	part.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = getFolder()
	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, size, size), Transparency = 1,
	}):Play()
	Debris:AddItem(part, duration + 0.1)
end

-- red ghost copy of the character that fades out
local function afterimage(character)
	local folder = Instance.new("Folder")
	folder.Name = "ChargeAfterimage"
	folder.Parent = getFolder()
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()
			for _, child in clone:GetChildren() do
				if not child:IsA("SpecialMesh") then child:Destroy() end
			end
			clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery, clone.Massless = true, false, false, false, true
			clone.CastShadow = false
			clone.Material, clone.Color, clone.Transparency = Enum.Material.Neon, CONFIG.COLOR, 0.5
			clone.CFrame = part.CFrame
			clone.Parent = folder
			TweenService:Create(clone, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
	end
	Debris:AddItem(folder, 0.45)
end

-- light dust at the feet
local function footDust(root, character, count, speed)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, getFolder() }
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
	if not hit then return end
	local color = hit.Instance.Color:Lerp(Color3.fromRGB(215, 200, 175), 0.7)
	burst(hit.Position + Vector3.new(0, 0.3, 0), color, count, speed, Vector2.new(70, 70), 1.4)
end

local function flashVictim()
	if not victimFrame or not victimFrame.Parent then
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then return end
		local gui = Instance.new("ScreenGui")
		gui.Name = "ChargeVictimFlash"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 55
		gui.Parent = playerGui
		victimFrame = Instance.new("Frame")
		victimFrame.Size = UDim2.fromScale(1, 1)
		victimFrame.BackgroundColor3 = CONFIG.COLOR
		victimFrame.BackgroundTransparency = 1
		victimFrame.BorderSizePixel = 0
		victimFrame.Parent = gui
	end
	victimFrame.BackgroundTransparency = 0.6
	TweenService:Create(victimFrame, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

-- ==========================================
-- PUBLIC
-- ==========================================
function ChargeEffect.Init(_unused) end -- kept so CombatController.Init() can still call it

-- the charge begins. Called on every client (and instantly on the charger by ChargeClient).
function ChargeEffect.Start(player: Player, character: Model, duration)
	local existing = active[player]
	if existing and os.clock() - existing.startedAt < 1.5 then return end -- already started locally
	ChargeEffect.Stop(player)

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local isLocal = player == Players.LocalPlayer :: Player
	local startedAt = os.clock()
	local running = true

	-- RED highlight: this is what tells everybody "dodge him"
	local highlight = Instance.new("Highlight")
	highlight.Adornee = character
	highlight.FillColor = CONFIG.COLOR
	highlight.OutlineColor = CONFIG.OUTLINE
	highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
	highlight.DepthMode = if CONFIG.ALWAYS_ON_TOP then Enum.HighlightDepthMode.AlwaysOnTop else Enum.HighlightDepthMode.Occluded
	highlight.Parent = getFolder()

	-- speed ribbon behind him (red -> white), visible to everybody
	local trail, trailA, trailB = nil, nil, nil
	if CONFIG.TRAIL then
		trailA, trailB = Instance.new("Attachment"), Instance.new("Attachment")
		trailA.Position, trailB.Position = Vector3.new(-1.4, 0.4, 0), Vector3.new(1.4, 0.4, 0)
		trailA.Parent, trailB.Parent = root, root
		trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = trailA, trailB
		trail.Lifetime = 0.35
		trail.LightEmission = 1
		trail.FaceCamera = true
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 235, 230)),
			ColorSequenceKeypoint.new(1, CONFIG.COLOR),
		})
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		trail.Parent = root
	end

	-- red energy puffs around his body (works without any template)
	local auraAttachment, aura = nil, nil
	if CONFIG.AURA then
		auraAttachment = Instance.new("Attachment")
		auraAttachment.Parent = root
		aura = Instance.new("ParticleEmitter")
		aura.Rate = 45
		aura.Lifetime = NumberRange.new(0.3, 0.55)
		aura.Speed = NumberRange.new(3, 9)
		aura.SpreadAngle = Vector2.new(180, 180)
		aura.LightEmission = 1
		aura.LockedToPart = false
		aura.Rotation = NumberRange.new(0, 360)
		aura.Color = ColorSequence.new(CONFIG.COLOR, Color3.fromRGB(255, 190, 170))
		aura.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(1, 0) })
		aura.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
		aura.Parent = auraAttachment
	end

	-- the Charge VFX template follows the charger
	local part, offset = nil, CONFIG.VFX_OFFSET
	local loops, pulsed, impacts, names = {}, {}, {}, {}
	local source = getVfxPart(CONFIG.VFX_TEMPLATE)
	if source then
		part = source:Clone()
		offset = templateOffset(part)
		part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
		part.CFrame = root.CFrame * offset
		part.Parent = getFolder()
		for _, item in part:GetDescendants() do
			if item:IsA("ParticleEmitter") then
				table.insert(names, item.Name)
				local lowerName = string.lower(item.Name)
				if string.find(lowerName, "impact", 1, true) then table.insert(impacts, item) end
				if isBurst(lowerName) then
					item.Enabled = false
					item:Emit(item:GetAttribute("EmitCount") or 12)
				else
					item.Enabled = true
					table.insert(loops, item)
					if item.Rate <= 0 then table.insert(pulsed, item) end -- emitters that only work through Emit()
				end
			end
		end
		if CONFIG.DEBUG and not warnedTemplate then
			warnedTemplate = true
			warn("[ChargeEffect] template '" .. CONFIG.VFX_TEMPLATE .. "' found, emitters: " .. table.concat(names, ", "))
		end
	elseif CONFIG.DEBUG and not warnedTemplate then
		warnedTemplate = true
		warn("[ChargeEffect] ReplicatedStorage.Assets.VFX." .. CONFIG.VFX_TEMPLATE .. " (with a ChargeFF part) was NOT found - using the built-in effects only")
	end

	-- start: dust burst + thin ring + sound + camera kick
	local feet = root.Position - Vector3.new(0, 2.5, 0)
	if CONFIG.START_BURST then
		footDust(root, character, 26, 30)
		ring(feet, 14, 0.35)
	end
	playSoundAt(CONFIG.START_SOUND, root.Position, 0.75, 1)
	if isLocal then
		addShake(2.2, 0.45)
		sustain = CONFIG.RUMBLE
		bindShake()
	elseif cameraNear(root.Position) then
		addShake(1.0, 0.3)
	end

	local connection
	local function stop()
		if not running then return end
		running = false
		if connection then connection:Disconnect() connection = nil end
		if isLocal then sustain = 0 end
		TweenService:Create(highlight, TweenInfo.new(0.25), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		Debris:AddItem(highlight, 0.3)
		if trail then trail.Enabled = false; Debris:AddItem(trail, 0.5) end
		if trailA then Debris:AddItem(trailA, 0.6) end
		if trailB then Debris:AddItem(trailB, 0.6) end
		if aura then aura.Enabled = false end
		if auraAttachment then Debris:AddItem(auraAttachment, 1) end
		if part then
			for _, emitter in loops do emitter.Enabled = false end
			Debris:AddItem(part, 2.5) -- let the last particles fade out
		end
		-- the skid: dust burst where he stops
		if root.Parent then footDust(root, character, 24, 28) end
		if active[player] and active[player].stop == stop then active[player] = nil end
	end
	active[player] = { stop = stop, impacts = impacts, startedAt = startedAt }

	local lastAfterimage, lastDust = 0, 0
	connection = RunService.RenderStepped:Connect(function()
		if not root.Parent then stop() return end
		local now = os.clock()
		if part then part.CFrame = root.CFrame * offset end
		highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY + math.sin((now - startedAt) * CONFIG.PULSE_SPEED) * 0.15
		if CONFIG.AFTERIMAGES and now - lastAfterimage >= CONFIG.AFTERIMAGE_INTERVAL then
			lastAfterimage = now
			afterimage(character)
		end
		if CONFIG.DUST and now - lastDust >= 0.09 then
			lastDust = now
			footDust(root, character, 5, 14)
		end
	end)

	if #pulsed > 0 then
		task.spawn(function()
			while running do
				for _, emitter in pulsed do emitter:Emit(emitter:GetAttribute("EmitCount") or 1) end
				task.wait(0.12)
			end
		end)
	end

	task.delay((duration or 1) + 0.5, stop) -- safety net, the server / ChargeClient also stop it
end

function ChargeEffect.Stop(player)
	local entry = active[player]
	if entry then entry.stop() end
end

-- somebody got plowed through. position = where it happened.
function ChargeEffect.Impact(player, position)
	local entry = active[player]
	if entry then
		for _, emitter in entry.impacts do emitter:Emit(emitter:GetAttribute("EmitCount") or 12) end
	end
	if typeof(position) ~= "Vector3" then return end
	burst(position, Color3.fromRGB(255, 235, 220), 16, 55, Vector2.new(120, 120), 0.8)
	burst(position, CONFIG.COLOR, 14, 45, Vector2.new(120, 120), 1.1)
	playSoundAt(CONFIG.HIT_SOUND, position, 0.9, 1)
	if player ~= Players.LocalPlayer and cameraNear(position) then addShake(1.8, 0.4) end -- bystanders
end

-- local charger: he hit something (count = how many so far)
function ChargeEffect.ChargerHit(count)
	addShake(2.8 + math.min(count, 4) * 0.8, 0.5)
end

-- local victim: he got hit by a charge
function ChargeEffect.Victim()
	addShake(6, 0.8)
	flashVictim()
end

return ChargeEffect