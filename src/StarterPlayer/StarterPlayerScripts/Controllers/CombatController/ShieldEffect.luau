--!nonstrict
-- Shield visual (client): a fat 3D force-field bubble around the character.
-- Any character with the attribute ShieldActive = true gets one.
-- The server (Protection.SetShield) raises the "ShieldBreak" counter BEFORE it clears ShieldActive when a hit
-- breaks the shield -> the bubble flashes, bursts outwards, a shockwave rolls out and shards fly away.
-- If ShieldActive just turns off (expired) the bubble fades quietly.
-- Config: AbilityConfig.Abilities.Shield (Color / Size / Image).

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--// Modules
local AbilityConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("AbilityConfig"))

--// Constants
local CONFIG = AbilityConfig.Abilities.Shield or {}
local COLOR = CONFIG.Color or Color3.fromRGB(110, 200, 255)
local SIZE = CONFIG.Size or 8                -- bubble diameter in studs
local OUTER_TRANSPARENCY = 0.4               -- what other players see
local OUTER_TRANSPARENCY_OWN = 0.62          -- your own bubble is lighter so it does not block your view
local INNER_TRANSPARENCY = 0.86
local SHARD_COUNT = 18
local WHITE = Color3.new(1, 1, 1)

local LocalPlayer = Players.LocalPlayer

local ShieldEffect = {}
local shieldBreak = game:GetService("SoundService").SFX.ShieldBreak
local shieldOn = game:GetService("SoundService").SFX.ShieldOn
--// State
local folder
local active = {}    -- [character] = entry
local updating = {}  -- [entry] = true  (entries that follow their character, incl. the ones that are breaking)
local tracked = {}   -- [character] = true

local function getFolder()
	if folder and folder.Parent then return folder end
	folder = Workspace:FindFirstChild("ShieldVisuals")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ShieldVisuals"
		folder.Parent = Workspace
	end
	return folder
end

local function makePart(shape, size, material, color, transparency)
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Material = material
	part.Color = color
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = getFolder()
	return part
end

local function makeBall(diameter, material, color, transparency)
	return makePart(Enum.PartType.Ball, Vector3.one * diameter, material, color, transparency)
end

local function tween(instance, time, goal, style, direction)
	local t = TweenService:Create(instance, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

local function cleanup(entry)
	if entry.dead then return end
	entry.dead = true
	updating[entry] = nil
	for _, instance in ipairs(entry.parts) do
		if instance.Parent then instance:Destroy() end
	end
end

--// Build / animate
local function buildVisual(character, root)
	local own = character == LocalPlayer.Character
	local outerBase = if own then OUTER_TRANSPARENCY_OWN else OUTER_TRANSPARENCY

	-- outer: the animated hexagon force-field skin
	local outer = makeBall(SIZE * 0.4, Enum.Material.ForceField, COLOR, 1)
	-- inner: soft coloured body so the bubble looks thick / fat, not like a thin shell
	local inner = makeBall(SIZE * 0.4, Enum.Material.SmoothPlastic, COLOR, 1)

	local entry = {
		character = character,
		root = root,
		outer = outer,
		inner = inner,
		parts = { outer, inner },
		outerBase = outerBase,
		ready = false,
		startedAt = os.clock(),
		breakCount = character:GetAttribute("ShieldBreak") or 0,
	}

	-- optional custom shield image on top of the bubble
	local image = CONFIG.Image
	if type(image) == "string" and image ~= "" then
		local gui = Instance.new("BillboardGui")
		gui.Adornee = outer
		gui.Size = UDim2.fromScale(SIZE * 0.6, SIZE * 0.6)
		gui.LightInfluence = 0
		gui.ResetOnSpawn = false
		gui.Parent = outer
		local label = Instance.new("ImageLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Image = image
		label.ImageTransparency = 0.15
		label.Parent = gui
		entry.imageLabel = label
	end

	-- pop in
	tween(outer, 0.45, { Size = Vector3.one * SIZE, Transparency = outerBase }, Enum.EasingStyle.Back)
	tween(inner, 0.45, { Size = Vector3.one * SIZE * 0.94, Transparency = INNER_TRANSPARENCY }, Enum.EasingStyle.Back)
	task.delay(0.5, function()
		entry.ready = true
	end)

	updating[entry] = true
	shieldOn:Play()
	return entry
end

local function playBreak(entry)
	entry.ready = false
	local center = entry.root.Position + Vector3.new(0, 0.2, 0)

	-- 1) the bubble flashes bright, then bursts outwards
	entry.outer.Transparency = 0.05
	entry.outer.Color = WHITE
	tween(entry.outer, 0.4, { Size = Vector3.one * SIZE * 1.6, Transparency = 1 })
	entry.inner.Material = Enum.Material.Neon
	entry.inner.Color = WHITE
	entry.inner.Transparency = 0.25
	tween(entry.inner, 0.3, { Size = Vector3.one * SIZE * 1.3, Transparency = 1 })
	if entry.imageLabel then
		tween(entry.imageLabel, 0.25, { ImageTransparency = 1 })
	end

	-- 2) shockwave rolling out
	local wave = makeBall(SIZE * 0.9, Enum.Material.ForceField, COLOR, 0.2)
	table.insert(entry.parts, wave)
	entry.wave = wave
	tween(wave, 0.55, { Size = Vector3.one * SIZE * 2.8, Transparency = 1 })

	-- 3) shards flying away (glowing glass pieces)
	for i = 1, SHARD_COUNT do
		local direction = Vector3.new(math.random() - 0.5, math.random() * 0.8 - 0.2, math.random() - 0.5)
		if direction.Magnitude < 0.05 then direction = Vector3.yAxis end
		direction = direction.Unit

		local shard = makePart(
			Enum.PartType.Block,
			Vector3.new(0.35 + math.random() * 0.4, 0.8 + math.random() * 0.8, 0.12),
			Enum.Material.Neon,
			if i % 3 == 0 then WHITE else COLOR,
			0
		)
		shard.CFrame = CFrame.lookAt(center + direction * SIZE * 0.45, center + direction * SIZE) * CFrame.Angles(0, 0, math.random() * math.pi)
		table.insert(entry.parts, shard)

		local endPosition = center + direction * (SIZE * 0.45 + 5 + math.random() * 6) + Vector3.new(0, -1.5, 0)
		tween(shard, 0.6, {
			CFrame = CFrame.new(endPosition) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6),
			Size = shard.Size * 0.3,
			Transparency = 1,
		})
	end
	shieldBreak:Play()
	

	-- 4) sparkles
	local emitterPart = makePart(Enum.PartType.Ball, Vector3.one * 0.2, Enum.Material.SmoothPlastic, WHITE, 1)
	emitterPart.CFrame = CFrame.new(center)
	table.insert(entry.parts, emitterPart)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(WHITE, COLOR)
	emitter.LightEmission = 1
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Speed = NumberRange.new(18, 38)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = emitterPart
	emitter:Emit(45)

	task.delay(1, function() cleanup(entry) end)
end

local function fadeOut(entry)
	entry.ready = false
	tween(entry.outer, 0.35, { Size = Vector3.one * SIZE * 0.85, Transparency = 1 })
	tween(entry.inner, 0.35, { Size = Vector3.one * SIZE * 0.8, Transparency = 1 })
	if entry.imageLabel then
		tween(entry.imageLabel, 0.3, { ImageTransparency = 1 })
	end
	task.delay(0.5, function() cleanup(entry) end)
end

local function detach(character, destroyNow)
	local entry = active[character]
	if not entry then return end
	active[character] = nil
	if destroyNow then
		cleanup(entry)
	elseif (character:GetAttribute("ShieldBreak") or 0) > entry.breakCount then
		playBreak(entry)
	else
		fadeOut(entry)
	end
end

local function attach(character)
	if active[character] then return end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 3)
	if not root or not root:IsA("BasePart") then return end
	-- the attribute may have changed while we were waiting
	if character:GetAttribute("ShieldActive") ~= true or active[character] then return end
	active[character] = buildVisual(character, root)
end

local function trackCharacter(character)
	if tracked[character] then return end
	tracked[character] = true

	local function refresh()
		if character:GetAttribute("ShieldActive") == true then
			attach(character)
		else
			detach(character, false)
		end
	end
	character:GetAttributeChangedSignal("ShieldActive"):Connect(refresh)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			detach(character, true)
			tracked[character] = nil
		end
	end)
	refresh()
end

local function trackPlayer(player)
	player.CharacterAdded:Connect(trackCharacter)
	if player.Character then task.spawn(trackCharacter, player.Character) end
end

--// Follow the characters (also while a bubble is breaking)
local function update()
	local now = os.clock()
	for entry in pairs(updating) do
		local root = entry.root
		if entry.dead or not root.Parent then
			cleanup(entry)
			continue
		end
		local position = root.Position + Vector3.new(0, 0.2, 0)
		-- slowly turning bubble makes the force-field hexagons crawl
		local turn = CFrame.Angles(0, now * 0.7, 0)
		entry.outer.CFrame = CFrame.new(position) * turn
		entry.inner.CFrame = CFrame.new(position)
		if entry.wave then entry.wave.CFrame = CFrame.new(position) end

		if entry.ready then
			-- gentle breathing
			local breathe = 1 + math.sin((now - entry.startedAt) * 4) * 0.03
			entry.outer.Size = Vector3.one * SIZE * breathe
			entry.inner.Size = Vector3.one * SIZE * 0.94 * breathe
			entry.outer.Transparency = entry.outerBase + math.sin((now - entry.startedAt) * 3) * 0.05
		end
	end
end

-- Bots (no Player object): BotController hands their character over so the same bubble is drawn
function ShieldEffect.Track(character)
	task.spawn(trackCharacter, character)
end

local initialized = false
function ShieldEffect.Init()
	if initialized then return end
	initialized = true
	RunService.RenderStepped:Connect(update)
	Players.PlayerAdded:Connect(trackPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		trackPlayer(player)
	end
end

return ShieldEffect
