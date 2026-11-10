-- Presents moon behavior using logical Player data access.
local Moon = {}
local ObjectPool = require(game:GetService("ReplicatedStorage"):WaitForChild("Utils"):WaitForChild("ObjectPool"))
Moon.__index = Moon
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local PlayerData = require(ReplicatedStorage.PlayerData)
local Config = require(script.Config)
local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)
local EffectTransition = require(script.Parent.Helper.EffectTransition)
local TransitionEffects = require(script.TransitionEffects)

local function findPath(root, path)
	local current = root
	for _, name in path do
		current = current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function isMovable(instance)
	return instance and (instance:IsA("Model") or instance:IsA("BasePart"))
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validateEasing(settings)
	assert(
		typeof(settings.EasingStyle) == "EnumItem" and settings.EasingStyle.EnumType == Enum.EasingStyle,
		"Moon motion requires an EasingStyle"
	)
	assert(
		typeof(settings.EasingDirection) == "EnumItem" and settings.EasingDirection.EnumType == Enum.EasingDirection,
		"Moon motion requires an EasingDirection"
	)
end

local function validate()
	validateEasing(Config.Blackhole)
	local force = Config.Blackhole.Force
	assert(
		type(force) == "table"
			and finite(force.StartFraction)
			and finite(force.FullFraction)
			and force.StartFraction >= 0
			and force.StartFraction < force.FullFraction
			and force.FullFraction <= 1,
		"Moon Blackhole.Force requires 0 <= StartFraction < FullFraction <= 1"
	)
	assert(finite(force.Value) and force.Value >= 0, "Moon Blackhole.Force.Value must be finite and nonnegative")
	validateEasing(force)
	local transition = Config.Blackhole.Transition
	assert(type(transition) == "table", "Moon Blackhole.Transition must be a table")
	for _, key in { "Delay", "Time", "FadeTime", "EffectsFadeTime" } do
		assert(
			finite(transition[key]) and transition[key] >= 0,
			"Moon Blackhole.Transition." .. key .. " must be finite and nonnegative"
		)
	end
	assert(
		finite(transition.ScaleFinal) and transition.ScaleFinal > 0,
		"Moon Blackhole.Transition.ScaleFinal must be positive"
	)
	validateEasing(transition)
	assert(
		finite(transition.SkyboxChangeFraction)
			and transition.SkyboxChangeFraction >= 0
			and transition.SkyboxChangeFraction <= 1,
		"Moon Blackhole.Transition.SkyboxChangeFraction must be between 0 and 1"
	)
	assert(
		finite(Config.Objects.MaxSpawnsPerFrame)
			and Config.Objects.MaxSpawnsPerFrame >= 1
			and Config.Objects.MaxSpawnsPerFrame % 1 == 0,
		"Moon MaxSpawnsPerFrame must be a positive integer"
	)
	for _, settings in Config.Objects.Groups do
		assert(
			typeof(settings.SpawnRate) == "NumberRange"
				and settings.SpawnRate.Min >= 0 and settings.SpawnRate.Max < math.huge,
			"Moon SpawnRate must be a finite nonnegative range"
		)
		assert(
			typeof(settings.SpawnRateRandom) == "NumberRange"
				and settings.SpawnRateRandom.Min > 0 and settings.SpawnRateRandom.Max < math.huge,
			"Moon SpawnRateRandom must be a positive finite multiplier range"
		)
		validateEasing({
			EasingStyle = settings.SpawnRateEasingStyle,
			EasingDirection = settings.SpawnRateEasingDirection,
		})
		assert(
			typeof(settings.TravelSpeed) == "NumberRange"
				and settings.TravelSpeed.Min > 0
				and settings.TravelSpeed.Max < math.huge,
			"Moon object TravelSpeed must be a positive finite range"
		)
		assert(
			finite(settings.MaxActive) and settings.MaxActive >= 0 and settings.MaxActive % 1 == 0,
			"Moon MaxActive must be a nonnegative integer"
		)
		validateEasing(settings)
		if settings.FadeOut then
			assert(
				finite(settings.FadeOut.StartFraction)
					and settings.FadeOut.StartFraction >= 0
					and settings.FadeOut.StartFraction < 1,
				"Moon object FadeOut.StartFraction must satisfy 0 <= value < 1"
			)
			validateEasing(settings.FadeOut)
		end
		if settings.Scale ~= nil then
			assert(
				typeof(settings.Scale) == "NumberRange" and settings.Scale.Min >= 0 and settings.Scale.Max < math.huge,
				"Moon object Scale must be a finite nonnegative range"
			)
		end
		if settings.FinalScale ~= nil then
			assert(
				settings.Scale ~= nil
					and typeof(settings.FinalScale) == "NumberRange"
					and settings.FinalScale.Min >= 0
					and settings.FinalScale.Max < math.huge,
				"Moon object FinalScale requires Scale and a finite nonnegative range"
			)
		end
	end
end

local function registerEffects(transition, root, speed, minimumRate, minTimeScale, planeEmitters)
	transition:Register(root, speed, minimumRate, minTimeScale)
	for _, instance in root:GetDescendants() do
		transition:Register(instance, speed, minimumRate, minTimeScale)
		if planeEmitters and instance:IsA("ParticleEmitter") then
			planeEmitters[instance] = true
		end
	end
end

function Moon.new(arena, player)
	validate()
	local self = setmetatable({
		arena = arena,
		random = Random.new(),
		groups = {},
		spawns = {},
		stops = {},
		age = 0,
		transitionState = "Traveling",
		effectRoots = {},
		retiredEffects = {},
		sceneSounds = {},
	}, Moon)
	self.effects = EffectTransition.new(Config, player)
	self.planeEmitters = {}
	self.player = player
	local finalFolder = findPath(arena, Config.FinalLightingPath)
	local transitionFolder = findPath(arena, Config.FinalTransitionPath)
	for _, instance in arena:GetDescendants() do
		if instance:IsA("Sound") then
			if (finalFolder and instance:IsDescendantOf(finalFolder))
				or (transitionFolder and instance:IsDescendantOf(transitionFolder)) then
				instance:Stop() -- Final audio starts only when expansion is complete.
			else
				self.sceneSounds[instance] = instance.Volume
			end
		end
	end
	if transitionFolder then
		self.transitionEffects = TransitionEffects.new(transitionFolder, Config)
	end
	local lobbyHidden = findPath(arena, Config.LobbyHiddenPath)
	if lobbyHidden and lobbyHidden:IsA("BasePart") then
		self.lobbyHidden, self.lobbyHiddenTransparency = lobbyHidden, lobbyHidden.Transparency
	end
	self:RefreshPlayer()
	local dynamic = findPath(arena, Config.DynamicEffectsPath)
	local misc = findPath(arena, Config.MiscPath)
	if not dynamic then
		return self
	end
	self.dynamic = dynamic
	local vfx = dynamic:FindFirstChild(Config.VFXs.Name)
	if vfx then
		table.insert(self.effectRoots, vfx)
		registerEffects(self.effects, vfx, Config.VFXs.ParticleSpeed, nil, nil, self.planeEmitters)
	end
	local portal = dynamic:FindFirstChild(Config.Portal.Name)
	if portal then
		table.insert(self.effectRoots, portal)
		registerEffects(
			self.effects,
			portal,
			nil,
			Config.Portal.MinimumEmitRate,
			Config.Portal.MinTimeScale,
			self.planeEmitters
		)
	end
	local blackhole = dynamic:FindFirstChild(Config.Blackhole.Name)
	local blackholeStop = misc and misc:FindFirstChild(Config.Blackhole.StopName)
	if isMovable(blackhole) and blackholeStop and blackholeStop:IsA("BasePart") then
		self.blackhole, self.blackholeStart = blackhole, blackhole:GetPivot()
		self.blackholeEndZ = blackholeStop.Position.Z
		self.blackholeOriginalParent = blackhole.Parent
		if blackhole:IsA("Model") then
			self.blackholeOriginalScale = blackhole:GetScale()
		end
		self.blackholeBackup = blackhole:Clone()
		if self.blackholeBackup then
			for _, instance in self.blackholeBackup:GetDescendants() do
				if instance:IsA("Sound") then
					instance:Stop()
				end
			end
		end
	end
	if misc then
		for _, part in misc:GetChildren() do
			if part:IsA("BasePart") then
				if part.Name == Config.Objects.SpawnName then
					table.insert(self.spawns, part)
				end
				if part.Name == Config.Objects.DestroyName then
					table.insert(self.stops, part)
				end
			end
		end
	end
	local runtime = ReplicatedStorage:FindFirstChild("Runtime")
	if not runtime then
		runtime = Instance.new("Folder")
		runtime.Name = "Runtime"
		runtime.Parent = ReplicatedStorage
	end
	self.storage = Instance.new("Folder")
	self.storage.Name = "MoonEffects"
	self.storage.Parent = runtime
	if self.blackholeBackup then
		self.blackholeBackup.Parent = self.storage
	end
	self.objects = Instance.new("Folder")
	self.objects.Name = "MoonObjects"
	self.objects.Parent = dynamic
	for _, settings in Config.Objects.Groups do
		local container = dynamic:FindFirstChild(settings.Name)
		local group = { settings = settings, templates = {}, active = {}, clock = 0, originalParent = container }
		table.insert(self.groups, group)
		if container then
			local stored = Instance.new("Folder")
			stored.Name = settings.Name
			stored.Parent = self.storage
			-- Collect direct movable children, including Sparkles' existing Part/Star names.
			for _, template in container:GetChildren() do
				if isMovable(template) then
					table.insert(group.templates, template)
					template.Parent = stored
				end
			end
		end
	end
	self:_initLighting()
	self:_updateLighting()
	return self
end

function Moon:_initLighting()
	local final = findPath(self.arena, Config.FinalLightingPath)
	local default = findPath(ReplicatedStorage, Config.DefaultLightingPath)
	if not final or not default then
		return
	end
	self.lightingCache = Instance.new("Folder")
	self.lightingCache.Name = "LightingCache"
	self.lightingCache.Parent = self.storage
	self.lightingSources, self.lightingOwned, self.lightingOriginals = {}, {}, {}
	for _, class in { "Sky", "Atmosphere" } do
		local normal, changed = default:FindFirstChildOfClass(class), final:FindFirstChildOfClass(class)
		if normal and changed then
			local normalCopy, finalCopy = normal:Clone(), changed:Clone()
			normalCopy.Parent, finalCopy.Parent = self.lightingCache, self.lightingCache
			self.lightingSources[class] = { default = normalCopy, final = finalCopy }
		end
	end
end

function Moon:_setLighting(final)
	if not self.lightingSources then
		return
	end
	for class, sources in self.lightingSources do
		local owned = self.lightingOwned[class]
		if owned then
			owned:Destroy()
		end
		-- Keep server-owned originals for teardown. Never touch post-processing effects.
		for _, child in Lighting:GetChildren() do
			if child:IsA(class) then
				table.insert(self.lightingOriginals, child)
				child.Parent = self.lightingCache
			end
		end
		local copy = (if final then sources.final else sources.default):Clone()
		self.lightingOwned[class] = copy
		copy.Parent = Lighting
	end
	self.finalLighting = final
end

function Moon:_setPlaneParticles(planeB)
	if self.finalized then
		planeB = true
	end
	if self.planeB == planeB then
		return
	end
	self.planeB = planeB
	for emitter in self.planeEmitters do
		self.effects:SetParticleEnabled(emitter, not planeB)
	end
end

function Moon:_updateLighting()
	if self.destroyed or self.player ~= Players.LocalPlayer then
		return
	end
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local final = self.finalized == true
	if
		not self.finalized
		and root
		and root:IsA("BasePart")
		and self.arena:IsDescendantOf(workspace)
		and self.blackhole
		and self.blackhole:IsDescendantOf(self.arena)
	then
		local direction = if self.blackholeEndZ < self.blackholeStart.Position.Z then -1 else 1
		final = (self.blackhole:GetPivot().Position.Z - root.Position.Z) * direction > 0
	end
	self:_setPlaneParticles(final)
	-- Lock the Final sky/atmosphere during expansion without changing plane particles.
	final = final or self.transitionLighting == true
	if not self.lightingSources then
		return
	end
	-- Leave the initial server lighting alone until the first crossing.
	local refresh = final ~= self.finalLighting and (final or self.finalLighting ~= nil)
	if self.finalLighting ~= nil then
		for class in self.lightingSources do
			local owned = self.lightingOwned[class]
			if not owned or owned.Parent ~= Lighting then
				refresh = true
			end
			for _, child in Lighting:GetChildren() do
				if child:IsA(class) and child ~= owned then
					refresh = true
				end
			end
		end
	end
	if refresh then
		self:_setLighting(final)
	end
end

function Moon:_restoreLighting()
	if not self.lightingOwned then
		return
	end
	for _, owned in self.lightingOwned do
		owned:Destroy()
	end
	for i = #self.lightingOriginals, 1, -1 do
		local original = self.lightingOriginals[i]
		if original.Parent == self.lightingCache and not Lighting:FindFirstChildOfClass(original.ClassName) then
			original.Parent = Lighting
		end
	end
	-- Incoming lighting from the next arena takes precedence over old originals.
	self.lightingCache:Destroy()
	self.lightingCache, self.lightingSources, self.lightingOwned, self.lightingOriginals = nil, nil, nil, nil
	self.finalLighting = nil
end

local function fadeSequence(sequence, alpha)
	local points = {}
	for _, point in sequence.Keypoints do
		table.insert(
			points,
			NumberSequenceKeypoint.new(
				point.Time,
				point.Value + (1 - point.Value) * alpha,
				point.Envelope * (1 - alpha)
			)
		)
	end
	return NumberSequence.new(points)
end

function Moon:_spawn(group)
	if self.destroyed or self.finalized or #group.templates == 0 or #self.spawns == 0 or #self.stops == 0 then
		return
	end
	local template = group.templates[self.random:NextInteger(1, #group.templates)]
	group.pools = group.pools or {}
	local pool = group.pools[template]
	if not pool then
		pool = ObjectPool.fromTemplate(template, { Name = "Moon_" .. group.settings.Name, MaxIdle = math.max(1, math.ceil(group.settings.MaxActive / #group.templates)) })
		group.pools[template] = pool
	end
	local object, _, lease = pool:Acquire()
	if not object then
		return
	end
	local spawn = self.spawns[self.random:NextInteger(1, #self.spawns)]
	local stop = self.stops[self.random:NextInteger(1, #self.stops)]
	local size = spawn.Size * 0.5
	local start = spawn.CFrame:PointToWorldSpace(
		Vector3.new(
			self.random:NextNumber(-size.X, size.X),
			self.random:NextNumber(-size.Y, size.Y),
			self.random:NextNumber(-size.Z, size.Z)
		)
	)
	local rotation = CFrame.Angles(
		self.random:NextNumber(0, math.pi * 2),
		self.random:NextNumber(0, math.pi * 2),
		self.random:NextNumber(0, math.pi * 2)
	)
	-- These are client visuals; anchor every part and remove physics interactions.
	local fadeVisuals = if group.settings.FadeOut then {} else nil
	local function prepare(part)
		if part:IsA("BasePart") then
			part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
		end
		if fadeVisuals and (part:IsA("BasePart") or part:IsA("Decal") or part:IsA("Texture")
			or part:IsA("ParticleEmitter") or part:IsA("Beam") or part:IsA("Trail")) then
			table.insert(fadeVisuals, { instance = part, transparency = part.Transparency })
		end
	end
	prepare(object)
	for _, descendant in object:GetDescendants() do
		prepare(descendant)
	end
	object:PivotTo(CFrame.new(start) * rotation)
	local baseScale, startScale, finalScale
	if group.settings.Scale and object:IsA("Model") then
		baseScale = object:GetScale()
		startScale = group.settings.Scale.Min
		local range = group.settings.FinalScale
		finalScale = if range then self.random:NextNumber(range.Min, range.Max) else group.settings.Scale.Max
		object:ScaleTo(baseScale * math.max(startScale, 0.001))
	end
	object.Parent = self.objects
	local travel = group.settings.TravelSpeed
	local alpha = math.clamp(self.age / (GameConfig.MatchTimeLimit * Config.FullFraction), 0, 1)
	local speed = travel.Min + (travel.Max - travel.Min) * alpha
	table.insert(group.active, {
		object = object,
		pool = pool,
		lease = lease,
		start = start,
		rotation = rotation,
		endZ = stop.Position.Z,
		age = 0,
		baseScale = baseScale,
		startScale = startScale,
		finalScale = finalScale,
		fadeVisuals = fadeVisuals,
		-- Easing varies instantaneous velocity; TravelSpeed sets average trip speed.
		duration = math.abs(stop.Position.Z - start.Z) / speed,
	})
	--warn(`alpha: {alpha}, duration: {group.active[#group.active].duration}`)
end

function Moon:_spawnRate(group)
	local settings = group.settings
	-- Spawn density progresses over the full match duration, independently of travel.
	local progress = if GameConfig.MatchTimeLimit > 0 then math.clamp(self.age / GameConfig.MatchTimeLimit, 0, 1) else 1
	local eased = math.clamp(TweenService:GetValue(progress, settings.SpawnRateEasingStyle, settings.SpawnRateEasingDirection), 0, 1)
	local range = settings.SpawnRate
	local baseRate = range.Min + (range.Max - range.Min) * eased
	if not group.spawnRateMultiplier then
		local randomRange = settings.SpawnRateRandom
		group.spawnRateMultiplier = self.random:NextNumber(randomRange.Min, randomRange.Max)
	end
	return baseRate * group.spawnRateMultiplier
end

function Moon:_updateGroup(group, dt)
	if self.destroyed or self.finalized then
		return
	end
	group.moveParts = group.moveParts or {}
	group.moveFrames = group.moveFrames or {}
	table.clear(group.moveParts)
	table.clear(group.moveFrames)
	for i = #group.active, 1, -1 do
		local data = group.active[i]
		data.age += dt
		if data.object.Parent ~= self.objects then
			data.pool:Release(data.object, data.lease)
			table.remove(group.active, i)
		else
			local progress = if data.duration > 0 then math.clamp(data.age / data.duration, 0, 1) else 1
			local alpha = TweenService:GetValue(progress, group.settings.EasingStyle, group.settings.EasingDirection)
			if data.fadeVisuals then
				local settings = group.settings.FadeOut
				local fadeProgress = math.clamp((alpha - settings.StartFraction) / (1 - settings.StartFraction), 0, 1)
				local fade = math.clamp(TweenService:GetValue(fadeProgress, settings.EasingStyle, settings.EasingDirection), 0, 1)
				if data.fade ~= fade then
					data.fade = fade
					for _, visual in data.fadeVisuals do
						if visual.instance.Parent then
							local original = visual.transparency
							visual.instance.Transparency = if typeof(original) == "NumberSequence"
								then fadeSequence(original, fade)
								else original + (1 - original) * fade
						end
					end
				end
			end
			if data.baseScale then
				local multiplier = data.startScale + (data.finalScale - data.startScale) * alpha
				data.object:ScaleTo(data.baseScale * math.max(multiplier, 0.001))
			end
			local position = Vector3.new(data.start.X, data.start.Y, data.start.Z + (data.endZ - data.start.Z) * alpha)
			local frame = CFrame.new(position) * data.rotation
			if data.object:IsA("BasePart") then
				if progress < 1 then
					table.insert(group.moveParts, data.object)
					table.insert(group.moveFrames, frame * data.object.PivotOffset:Inverse())
				end
			else
				data.object:PivotTo(frame)
			end
			if progress >= 1 then
				data.pool:Release(data.object, data.lease)
				table.remove(group.active, i)
			end
		end
	end
	if #group.moveParts > 0 then workspace:BulkMoveTo(group.moveParts, group.moveFrames, Enum.BulkMoveMode.FireCFrameChanged) end
	if #group.templates == 0 or #self.spawns == 0 or #self.stops == 0 then
		return
	end
	local rate = self:_spawnRate(group)
	if rate <= 0 then return end
	-- Accumulate spawn progress, so changing rates never resets the pending spawn.
	group.clock = math.min(group.clock + dt * rate, Config.Objects.MaxSpawnsPerFrame)
	local budget = math.min(math.floor(group.clock), Config.Objects.MaxSpawnsPerFrame)
	for _ = 1, budget do
		if #group.active >= group.settings.MaxActive then
			group.clock = math.min(group.clock, 1)
			break
		end
		group.clock -= 1
		self:_spawn(group)
		group.spawnRateMultiplier = nil -- Sample the next interval on the next update.
	end
end

function Moon:_clearForce()
	if self.pullForce then
		self.pullForce:Destroy()
	end
	if self.pullAttachment then
		self.pullAttachment:Destroy()
	end
	self.pullForce, self.pullAttachment, self.pullRoot = nil, nil, nil
end

function Moon:_updateForce(elapsed, total)
	-- Every client affects only its own character, which it normally simulates.
	if
		self.destroyed
		or self.finalized
		or self.player ~= Players.LocalPlayer
		or PlayerData.Get(self.player, "IsOnArena") ~= true
		or elapsed == nil
		or not finite(total)
		or total <= 0
		or not self.blackhole
		or not self.blackhole:IsDescendantOf(self.arena)
	then
		self:_clearForce()
		return
	end
	local settings = Config.Blackhole.Force
	local fraction = math.clamp(elapsed / total, 0, 1)
	local alpha =
		math.clamp((fraction - settings.StartFraction) / (settings.FullFraction - settings.StartFraction), 0, 1)
	local acceleration = settings.Value
		* math.clamp(TweenService:GetValue(alpha, settings.EasingStyle, settings.EasingDirection), 0, 1)
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if
		acceleration <= 0
		or not root
		or not root:IsA("BasePart")
		or not humanoid
		or humanoid.Health <= 0
		or not finite(root.AssemblyMass)
		or root.AssemblyMass <= 0
	then
		self:_clearForce()
		return
	end
	if
		self.pullRoot ~= root
		or not self.pullForce
		or self.pullForce.Parent ~= root
		or not self.pullAttachment
		or self.pullAttachment.Parent ~= root
	then
		self:_clearForce()
		self.pullRoot = root
		self.pullAttachment = Instance.new("Attachment")
		self.pullAttachment.Name = "MoonBlackholePullAttachment"
		self.pullAttachment.Parent = root
		self.pullForce = Instance.new("VectorForce")
		self.pullForce.Name = "MoonBlackholePull"
		self.pullForce.Attachment0 = self.pullAttachment
		self.pullForce.RelativeTo = Enum.ActuatorRelativeTo.World
		self.pullForce.ApplyAtCenterOfMass = true
		self.pullForce.Force = Vector3.zero
		self.pullForce.Parent = root
	end
	local offset = self.blackhole:GetPivot().Position - root.Position
	-- F = mass * acceleration gives the same pull strength for different masses.
	-- warn(`acceleration {acceleration}, mass {root.AssemblyMass}`)
	self.pullForce.Force = if offset.Magnitude > 0.0001
		then offset.Unit * acceleration * root.AssemblyMass
		else Vector3.zero
end

function Moon:_beginExpansion()
	if self.expansionStarted then
		return
	end
	self.expansionStarted = true
	if self.transitionEffects then self.transitionEffects:Start() end
	self.blackholeCollisions = {}
	for _, instance in self.blackhole:GetDescendants() do
		if instance:IsA("BasePart") then
			self.blackholeCollisions[instance] = { instance.CanCollide, instance.CanTouch, instance.CanQuery }
			instance.CanCollide, instance.CanTouch, instance.CanQuery = false, false, false
		end
	end
end

function Moon:_enterFinal()
	if self.finalized then
		return
	end
	self.finalized = true
	self.transitionState = "Fading"
	self.forceElapsed, self.forceTotal = nil, nil
	self:_clearForce()
	self.effects:Destroy() -- Stops the old audio and clears Portal/VFXs particles.
	for _, instance in self.effectRoots do
		if instance:IsDescendantOf(self.arena) then
			self.retiredEffects[instance] = instance.Parent
			instance.Parent = self.storage
		end
	end
	for _, group in self.groups do
		for _, data in group.active do
			data.pool:Release(data.object, data.lease)
		end
		table.clear(group.active)
		for _, pool in group.pools or {} do pool:Destroy() end
		group.pools = nil
		group.clock = 0
	end
	if self.objects then
		self.objects:Destroy()
		self.objects = nil
	end
	local final = findPath(self.arena, Config.FinalLightingPath)
	if final then
		-- Final reference sounds must also be audible in the lobby.
		self.finalEffects = EffectTransition.new(Config, nil, true)
		for _, instance in final:GetDescendants() do
			if instance:IsA("Sound") or instance:IsA("ObjectValue") then
				self.finalEffects:Register(instance)
			end
		end
		self.finalEffects:Update(1, 1)
	end
	for sound in self.sceneSounds do
		if sound.Parent then
			sound:Stop()
			sound.Volume = 0
		end
	end
	self.blackholeFade = {}
	for _, instance in self.blackhole:GetDescendants() do
		if instance:IsA("ParticleEmitter") then
			self.blackholeFade[instance] = {
				kind = "particle",
				rate = instance.Rate,
				enabled = instance.Enabled,
				transparency = instance.Transparency,
			}
		elseif instance:IsA("BasePart") or instance:IsA("Decal") then
			self.blackholeFade[instance] = { kind = "surface", transparency = instance.Transparency }
		elseif instance:IsA("Beam") or instance:IsA("Trail") then
			self.blackholeFade[instance] = { kind = "sequence", transparency = instance.Transparency }
		elseif instance:IsA("Light") then
			self.blackholeFade[instance] = { kind = "light", brightness = instance.Brightness }
		end
	end
	self:_updateLighting() -- All clients remain in Final, regardless of position.
end

function Moon:_fadeBlackhole(progress)
	for instance, original in self.blackholeFade do
		if instance.Parent then
			if original.kind == "particle" then
				instance.Rate = original.rate * (1 - progress)
				instance.Transparency = fadeSequence(original.transparency, progress)
				if progress >= 1 then
					instance.Enabled = false
					instance:Clear()
				end
			elseif original.kind == "sequence" then
				instance.Transparency = fadeSequence(original.transparency, progress)
			elseif original.kind == "surface" then
				instance.Transparency = original.transparency + (1 - original.transparency) * progress
			elseif original.kind == "light" then
				instance.Brightness = original.brightness * (1 - progress)
			end
		end
	end
	if progress >= 1 then
		self.blackhole:Destroy()
		self.blackhole, self.blackholeFade, self.blackholeCollisions = nil, nil, nil
		self.transitionState = "Final"
		self.lobbyHidden.Transparency = 1
	end
end

function Moon:_updateBlackhole()
	if not self.blackhole or not self.blackhole:IsDescendantOf(self.arena) then
		return
	end
	local travelTime = GameConfig.MatchTimeLimit * Config.FullFraction
	local transition = Config.Blackhole.Transition
	local transitionAge = self.age - travelTime
	if transitionAge < 0 then
		local alpha = TweenService:GetValue(
			math.clamp(self.age / travelTime, 0, 1),
			Config.Blackhole.EasingStyle,
			Config.Blackhole.EasingDirection
		)
		self.blackhole:PivotTo(
			self.blackholeStart + Vector3.zAxis * ((self.blackholeEndZ - self.blackholeStart.Position.Z) * alpha)
		)
		if self.blackhole:IsA("Model") then
			self.blackhole:ScaleTo(
				Config.Blackhole.Scale.Min + (Config.Blackhole.Scale.Max - Config.Blackhole.Scale.Min) * alpha
			)
		end
		return
	end
	self.blackhole:PivotTo(self.blackholeStart + Vector3.zAxis * (self.blackholeEndZ - self.blackholeStart.Position.Z))
	if transitionAge < transition.Delay then
		self.transitionState = "Waiting"
		if self.blackhole:IsA("Model") then
			self.blackhole:ScaleTo(Config.Blackhole.Scale.Max)
		end
		return
	end
	self:_beginExpansion()
	local expansionAge = transitionAge - transition.Delay
	local progress = if transition.Time > 0 then math.clamp(expansionAge / transition.Time, 0, 1) else 1
	if progress >= transition.SkyboxChangeFraction then
		self.transitionLighting = true
	end
	local eased = math.clamp(TweenService:GetValue(progress, transition.EasingStyle, transition.EasingDirection), 0, 1)
	if self.blackhole:IsA("Model") then
		self.blackhole:ScaleTo(
			Config.Blackhole.Scale.Max + (transition.ScaleFinal - Config.Blackhole.Scale.Max) * eased
		)
	end
	if progress < 1 then
		self.transitionState = "Expanding"
		return
	end
	self:_enterFinal()
	local fadeAge = expansionAge - transition.Time
	local fade = if transition.FadeTime > 0 then math.clamp(fadeAge / transition.FadeTime, 0, 1) else 1
	self:_fadeBlackhole(fade)
end

function Moon:Update(elapsed, total, dt)
	if self.destroyed then
		return
	end
	if not self.finalized then
		self.effects:Update(elapsed, total)
		self.forceElapsed, self.forceTotal = elapsed, total
	end
	self.age += dt
	self:_updateBlackhole()
	-- This fade keeps running even after the blackhole itself has been destroyed.
	if self.finalized and self.transitionEffects then
		local transition = Config.Blackhole.Transition
		local fadeAge = self.age - (GameConfig.MatchTimeLimit * Config.FullFraction + transition.Delay + transition.Time)
		local progress = if transition.EffectsFadeTime > 0 then math.clamp(fadeAge / transition.EffectsFadeTime, 0, 1) else 1
		self.transitionEffects:Fade(progress)
	end
	self:_updateForce(elapsed, total)
	self:_updateLighting()
	if self.finalized then
		return
	end
	for _, group in self.groups do
		self:_updateGroup(group, dt)
	end
end

function Moon:Reset()
	if not self.destroyed then
		self.effects:Reset()
		self.forceElapsed, self.forceTotal = nil, nil
		self:_clearForce()
	end
end

function Moon:RefreshPlayer()
	if not self.destroyed then
		self.effects:RefreshPlayer()
		self:_updateForce(self.forceElapsed, self.forceTotal)
		self:_updateLighting()
		if self.lobbyHidden and self.lobbyHidden:IsDescendantOf(self.arena) then
			--self.lobbyHidden.Transparency = if self.player:GetAttribute("IsOnArena") == true then 0 else 1
			self.lobbyHidden.Transparency = 1
		end
	end
end

function Moon:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	self:_restoreLighting()
	self:_clearForce()
	self.effects:Destroy()
	if self.transitionEffects then
		self.transitionEffects:Destroy()
		self.transitionEffects = nil
	end
	if self.finalEffects then
		self.finalEffects:Destroy()
	end
	table.clear(self.planeEmitters)
	for instance, parent in self.retiredEffects do
		if parent:IsDescendantOf(self.arena) then
			instance.Parent = parent
		end
	end
	for sound, volume in self.sceneSounds do
		if sound.Parent then
			sound.Volume = volume
		end
	end
	if self.lobbyHidden and self.lobbyHidden:IsDescendantOf(self.arena) then
		self.lobbyHidden.Transparency = self.lobbyHiddenTransparency
	end
	self.player, self.lobbyHidden = nil, nil
	for _, group in self.groups do
		for _, data in group.active do
			data.pool:Release(data.object, data.lease)
		end
		for _, pool in group.pools or {} do pool:Destroy() end
		group.pools = nil
		-- Restore authored objects when detaching a still-existing arena, so a
		-- subsequent handler can take a fresh snapshot. Destroyed arenas own nothing.
		if group.originalParent and group.originalParent:IsDescendantOf(self.arena) then
			for _, template in group.templates do
				template.Parent = group.originalParent
			end
		end
		table.clear(group.active)
		table.clear(group.templates)
	end
	if self.blackhole and self.blackhole:IsDescendantOf(self.arena) then
		for instance, original in self.blackholeFade or {} do
			if instance.Parent then
				if original.transparency then
					instance.Transparency = original.transparency
				end
				if original.kind == "particle" then
					instance.Rate, instance.Enabled = original.rate, original.enabled
				end
				if original.kind == "light" then
					instance.Brightness = original.brightness
				end
			end
		end
		for part, properties in self.blackholeCollisions or {} do
			if part.Parent then
				part.CanCollide, part.CanTouch, part.CanQuery = properties[1], properties[2], properties[3]
			end
		end
		if self.blackholeOriginalScale then
			self.blackhole:ScaleTo(self.blackholeOriginalScale)
		end
		self.blackhole:PivotTo(self.blackholeStart)
	end
	if not self.blackhole and self.blackholeBackup and self.blackholeOriginalParent:IsDescendantOf(self.arena) then
		-- Preserve reattachment support after destroying this client's active Blackhole.
		self.blackholeBackup.Parent = self.blackholeOriginalParent
		self.blackholeBackup = nil
	end
	if self.objects then
		self.objects:Destroy()
	end
	if self.storage then
		self.storage:Destroy()
	end
	table.clear(self.groups)
	self.arena, self.dynamic, self.blackhole, self.blackholeBackup, self.finalEffects = nil, nil, nil, nil, nil
	self.blackholeFade, self.blackholeCollisions = nil, nil
	table.clear(self.retiredEffects)
	table.clear(self.sceneSounds)
	table.clear(self.effectRoots)
	table.clear(self.spawns)
	table.clear(self.stops)
end

return Moon
