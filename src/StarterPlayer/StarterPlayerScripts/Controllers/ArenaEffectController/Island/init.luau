local Island = {}
Island.__index = Island
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ObjectPool = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("ObjectPool"))
local Config = require(script.Config)
local CameraShake = require(script.Parent.Helper.CameraShake)
local EffectTransition = require(script.Parent.Helper.EffectTransition)

local function findPath(root, path)
	for _, name in path do
		root = root:FindFirstChild(name)
		if not root then return nil end
	end
	return root
end

local function range(value, minimum, name)
	assert(typeof(value) == "NumberRange" and value.Min >= minimum and value.Max < math.huge, "Island " .. name .. " has an invalid range")
end

local function validate()
	local quake, debris = Config.Earthquake, Config.Debris
	for _, key in { "Frequency", "Duration", "Intensity", "IntervalRandom" } do range(quake[key], 0.000001, key) end
	assert(typeof(quake.EasingStyle) == "EnumItem" and quake.EasingStyle.EnumType == Enum.EasingStyle, "Island earthquake easing style is invalid")
	assert(typeof(quake.EasingDirection) == "EnumItem" and quake.EasingDirection.EnumType == Enum.EasingDirection, "Island earthquake easing direction is invalid")
	for _, key in { "Size", "Lifetime" } do range(debris[key], 0.000001, key) end
	for _, key in { "PiecesPerPart", "HorizontalSpeed", "UpwardSpeed" } do range(debris[key], 0, key) end
	for _, key in { "PartsPerBurst", "MaxActive" } do
		assert(type(debris[key]) == "number" and debris[key] >= 0 and debris[key] < math.huge and debris[key] % 1 == 0, "Island " .. key .. " must be a nonnegative integer")
	end
	assert(debris.PiecesPerPart.Min % 1 == 0 and debris.PiecesPerPart.Max % 1 == 0, "Island debris piece counts must be integers")
	for _, pair in { { debris, "BurstInterval", true }, { debris, "TopSurfaceTolerance", false }, { debris, "FadeTime", false }, { debris, "Gravity", false }, { quake.Camera, "Roughness", false }, { quake.Camera, "FadeTime", false } } do
		local value = pair[1][pair[2]]
		assert(type(value) == "number" and value == value and value < math.huge and (if pair[3] then value > 0 else value >= 0), "Island " .. pair[2] .. " is invalid")
	end
	assert(typeof(quake.Camera.PositionInfluence) == "Vector3" and typeof(quake.Camera.RotationInfluence) == "Vector3", "Island camera influences must be Vector3")
	local rocks = Config.RocksVFX
	range(rocks.SpawnRate, 0, "RocksVFX.SpawnRate")
	assert(typeof(rocks.EasingStyle) == "EnumItem" and rocks.EasingStyle.EnumType == Enum.EasingStyle, "Island RocksVFX easing style is invalid")
	assert(typeof(rocks.EasingDirection) == "EnumItem" and rocks.EasingDirection.EnumType == Enum.EasingDirection, "Island RocksVFX easing direction is invalid")
	for _, key in { "PartsPerBurst", "MaxActive", "MaxBurstsPerFrame", "SurfaceGrid" } do
		assert(type(rocks[key]) == "number" and rocks[key] >= 1 and rocks[key] < math.huge and rocks[key] % 1 == 0, "Island RocksVFX." .. key .. " must be a positive integer")
	end
	assert(type(rocks.SurfaceOffset) == "number" and rocks.SurfaceOffset == rocks.SurfaceOffset and math.abs(rocks.SurfaceOffset) < math.huge, "Island RocksVFX.SurfaceOffset must be finite")
end

function Island.new(arena, player)
	validate()
	local self = setmetatable({ arena = arena, player = player, random = Random.new(), parts = {}, debris = {}, rocks = {}, rocksUses = {}, rocksClock = 0, clock = 0, playing = false }, Island)
	self.effects = EffectTransition.new(Config, player)
	local dynamic = findPath(arena, Config.DynamicEffectsPath)
	if dynamic then for _, instance in dynamic:GetDescendants() do self.effects:Register(instance) end end
	local blocks = findPath(arena, Config.Debris.PartsPath)
	if blocks then
		for _, instance in blocks:GetDescendants() do
			if instance:IsA("BasePart") then table.insert(self.parts, instance) end
		end
	end
	self.objects = Instance.new("Folder")
	self.objects.Name = "IslandEarthquakeDebris"
	self.objects.Parent = arena
	self.shake = CameraShake.new(function()
		return not self.destroyed and self.playing and self.player:GetAttribute("IsOnArena") == true
	end)
	return self
end

function Island:_parameters(elapsed, total)
	local settings = Config.Earthquake
	local progress = math.clamp(elapsed / total, 0, 1)
	local alpha = math.clamp(TweenService:GetValue(progress, settings.EasingStyle, settings.EasingDirection), 0, 1)
	local function interpolate(value) return value.Min + (value.Max - value.Min) * alpha end
	return interpolate(settings.Frequency), interpolate(settings.Duration), interpolate(settings.Intensity)
end

function Island:_burstParts(limit, usesByPart, anchoredOnly)
	local eligible, selected, chosen = {}, {}, {}
	self.partUses = self.partUses or {}
	usesByPart = usesByPart or self.partUses
	local highestTop = -math.huge
	for _, part in self.parts do
		if part:IsDescendantOf(self.arena) and part.Transparency < 1 and part.CanCollide and (not anchoredOnly or part.Anchored) then
			table.insert(eligible, part)
			highestTop = math.max(highestTop, part.Position.Y + part.Size.Y / 2)
		end
	end
	-- Island is flat: compare top-surface Y, including thickness, to skip internal parts.
	for i = #eligible, 1, -1 do
		local part = eligible[i]
		if highestTop - (part.Position.Y + part.Size.Y / 2) > Config.Debris.TopSurfaceTolerance then
			table.remove(eligible, i)
		end
	end
	for _ = 1, math.min(limit, #eligible) do
		local best, bestUses, bestDistance = nil, math.huge, -1
		for _, part in eligible do
			if chosen[part] then continue end
			local uses = usesByPart[part] or 0
			local distance = if #selected == 0 then self.random:NextNumber() else math.huge
			for _, other in selected do
				local offset = part.Position - other.Position
				distance = math.min(distance, offset.X ^ 2 + offset.Z ^ 2)
			end
			-- Visit every surviving platform fairly; within a burst favor distant parts.
			if uses < bestUses or (uses == bestUses and distance > bestDistance) then
				best, bestUses, bestDistance = part, uses, distance
			end
		end
		chosen[best] = true
		table.insert(selected, best)
	end
	return selected
end

function Island:_rocksRate(elapsed, total)
	local settings = Config.RocksVFX
	local alpha = math.clamp(TweenService:GetValue(math.clamp(elapsed / total, 0, 1), settings.EasingStyle, settings.EasingDirection), 0, 1)
	return settings.SpawnRate.Min + (settings.SpawnRate.Max - settings.SpawnRate.Min) * alpha
end

function Island:_rocksBurst()
	local settings = Config.RocksVFX
	local template = self.rocksTemplate or findPath(ReplicatedStorage, settings.TemplatePath)
	if not template or not template:IsA("BasePart") then return end
	local available = settings.MaxActive - #self.rocks
	if available <= 0 then return end
	local sources = self:_burstParts(math.min(settings.PartsPerBurst, available), self.rocksUses, true)
	for _, source in sources do
		self.rockPools = self.rockPools or {}
		local pool = self.rockPools[template]
		if not pool then
			pool = ObjectPool.fromTemplate(template, { Name = "IslandRocks", MaxIdle = settings.MaxActive })
			self.rockPools[template] = pool
		end
		local clone, _, lease = pool:Acquire()
		if not clone then continue end
		local uses = self.rocksUses[source] or 0
		local grid = settings.SurfaceGrid
		local cell = (uses * (grid + 1)) % (grid * grid)
		local x = ((cell % grid + self.random:NextNumber(0.1, 0.9)) / grid - 0.5) * source.Size.X
		local z = ((math.floor(cell / grid) + self.random:NextNumber(0.1, 0.9)) / grid - 0.5) * source.Size.Z
		clone.CFrame = source.CFrame * CFrame.new(x, source.Size.Y / 2 + settings.SurfaceOffset, z) * template.CFrame.Rotation
		clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery = true, false, false, false
		local emitters, lifetime = {}, settings.Lifetime
		for _, instance in clone:GetDescendants() do
			if instance:IsA("BasePart") then
				instance.Anchored, instance.CanCollide, instance.CanTouch, instance.CanQuery = true, false, false, false
			elseif instance:IsA("ParticleEmitter") then
				instance.Enabled = false -- Never continuously emit from the cloned template.
				local count = instance:GetAttribute("EmitCount")
				if type(count) == "number" and count == count and count > 0 and count < math.huge then
					if instance.TimeScale <= 0 then instance.TimeScale = 1 end
					--lifetime = math.max(lifetime, instance.Lifetime.Max / instance.TimeScale)
					table.insert(emitters, { instance = instance, count = math.floor(count) })
				end
			end
		end
		if #emitters == 0 then pool:Release(clone, lease) continue end
		clone.Parent = self.objects
		for _, emitter in emitters do emitter.instance:Emit(emitter.count) end
		self.rocksUses[source] = uses + 1
		table.insert(self.rocks, { part = clone, pool = pool, lease = lease, age = 0, lifetime = lifetime })
		pool:ReleaseAfter(clone, lease, lifetime) -- Safety expiry uses this checkout only, never a subsequent reuse.
	end
end

function Island:_updateRocks(dt)
	for i = #self.rocks, 1, -1 do
		local data = self.rocks[i]
		data.age += dt
		if data.age >= data.lifetime or data.part.Parent ~= self.objects then
			data.pool:Release(data.part, data.lease)
			table.remove(self.rocks, i)
		end
	end
	for part in self.rocksUses do
		if not part:IsDescendantOf(self.arena) then self.rocksUses[part] = nil end
	end
end

function Island:_spawnRocks(elapsed, total, dt)
	local settings = Config.RocksVFX
	self.rocksClock = math.min(self.rocksClock + dt * self:_rocksRate(elapsed, total), settings.MaxBurstsPerFrame)
	local bursts = math.floor(self.rocksClock)
	for _ = 1, bursts do
		self.rocksClock -= 1
		self:_rocksBurst()
	end
	--warn(`rock burst {bursts}`)
end

function Island:_burst()
	local settings = Config.Debris
	-- Platforms may already have been removed by DestructionController.
	for i = #self.parts, 1, -1 do
		if not self.parts[i]:IsDescendantOf(self.arena) then
			if self.partUses then self.partUses[self.parts[i]] = nil end
			table.remove(self.parts, i)
		end
	end
	if #self.parts == 0 then return end
	local available = settings.MaxActive - #self.debris
	if available <= 0 then return end
	local sources = self:_burstParts(math.min(settings.PartsPerBurst, available))
	local plans = {}
	for _, source in sources do
		local count = self.random:NextInteger(settings.PiecesPerPart.Min, settings.PiecesPerPart.Max)
		table.insert(plans, { source = source, count = count, positions = {} })
	end
	-- Share remaining capacity across platforms instead of filling it on the first.
	local remaining = available
	while remaining > 0 do
		local added = false
		for _, plan in plans do
			if #plan.positions >= plan.count or remaining <= 0 then continue end
			table.insert(plan.positions, 0)
			remaining -= 1
			added = true
		end
		if not added then break end
	end
	for _, plan in plans do
		local source, count = plan.source, #plan.positions
		if count == 0 then continue end
		self.partUses[source] = (self.partUses[source] or 0) + 1
		-- One point per X/Z strip, with shuffled Z strips to avoid a diagonal pattern.
		for i = 1, count do plan.positions[i] = i end
		for i = count, 2, -1 do
			local j = self.random:NextInteger(1, i)
			plan.positions[i], plan.positions[j] = plan.positions[j], plan.positions[i]
		end
		for i = 1, count do
			local size = self.random:NextNumber(settings.Size.Min, settings.Size.Max)
			local position = source.CFrame:PointToWorldSpace(Vector3.new(
				((i - 1 + self.random:NextNumber()) / count - 0.5) * source.Size.X, source.Size.Y / 2,
				((plan.positions[i] - 1 + self.random:NextNumber()) / count - 0.5) * source.Size.Z
			))
			local angle = self.random:NextNumber(0, math.pi * 2)
			local speed = self.random:NextNumber(settings.HorizontalSpeed.Min, settings.HorizontalSpeed.Max)
			local velocity = Vector3.new(math.cos(angle) * speed, self.random:NextNumber(settings.UpwardSpeed.Min, settings.UpwardSpeed.Max), math.sin(angle) * speed)
			self.debrisPool = self.debrisPool or ObjectPool.new({ Name = "IslandDebris", MaxIdle = settings.MaxActive,
				Create = function() return Instance.new("Part") end })
			local part, _, lease = self.debrisPool:Acquire()
			part.Transparency = 0
			part.Size, part.Color, part.Material = Vector3.one * size, source.Color, source.Material
			part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery, part.CastShadow = true, false, false, false, false
			part.CFrame = CFrame.new(position)
			part.Parent = self.objects
			table.insert(self.debris, { part = part, lease = lease, start = position, velocity = velocity, size = size, age = 0,
				lifetime = self.random:NextNumber(settings.Lifetime.Min, settings.Lifetime.Max) })
		end
	end
end

function Island:_updateDebris(dt)
	self.moveParts = self.moveParts or {}
	self.moveFrames = self.moveFrames or {}
	table.clear(self.moveParts)
	table.clear(self.moveFrames)
	for i = #self.debris, 1, -1 do
		local data = self.debris[i]
		data.age += dt
		if data.age >= data.lifetime or data.part.Parent ~= self.objects then
			self.debrisPool:Release(data.part, data.lease)
			table.remove(self.debris, i)
		else
			local fadeTime = math.min(Config.Debris.FadeTime, data.lifetime)
			local fade = if fadeTime > 0 then math.clamp((data.age - data.lifetime + fadeTime) / fadeTime, 0, 1) else 0
			data.part.Transparency = fade
			data.part.Size = Vector3.one * math.max(data.size * (1 - fade), 0.001)
			table.insert(self.moveParts, data.part)
			table.insert(self.moveFrames, CFrame.new(data.start + data.velocity * data.age - Vector3.yAxis * (Config.Debris.Gravity * data.age ^ 2 / 2))
				* CFrame.Angles(data.age * 3, data.age * 2, 0)
			)
		end
	end
	if #self.moveParts > 0 then workspace:BulkMoveTo(self.moveParts, self.moveFrames, Enum.BulkMoveMode.FireCFrameChanged) end
end

function Island:Update(elapsed, total, dt)
	if self.destroyed then return end
	self.effects:Update(elapsed, total)
	if elapsed == nil then self:Reset() return end
	self.playing = true
	self:_updateDebris(dt)
	self:_updateRocks(dt) -- Let one-shot particles finish after the earthquake ends.
	local frequency, duration, intensity = self:_parameters(elapsed, total)
	if self.quakeRemaining then
		self.quakeRemaining -= dt
		if self.quakeRemaining <= 0 then self.quakeRemaining = nil self.rocksClock = 0 self.shake:Stop() return end
		self:_spawnRocks(elapsed, total, dt)
		self.burstClock += dt
		if self.burstClock >= Config.Debris.BurstInterval then
			self.burstClock %= Config.Debris.BurstInterval
			self:_burst() -- At most one burst per update, including after a long frame.
		end
		return
	end
	if not self.intervalFactor then
		local random = Config.Earthquake.IntervalRandom
		self.intervalFactor = self.random:NextNumber(random.Min, random.Max)
	end
	self.clock += dt * frequency / self.intervalFactor
	if self.clock >= 1 then
		self.clock, self.intervalFactor = 0, nil
		self.quakeRemaining, self.quakeDuration, self.quakeIntensity, self.burstClock = duration, duration, intensity, 0
		self.shake:Start(duration, intensity, Config.Earthquake.Camera)
		self:_burst()
		self.rocksClock = 0
		self:_rocksBurst()
	end
end

function Island:RefreshPlayer()
	if self.destroyed then return end
	self.effects:RefreshPlayer()
	if self.player:GetAttribute("IsOnArena") ~= true then
		self.shake:Stop()
	elseif self.playing and self.quakeRemaining then
		self.shake:Start(self.quakeRemaining, self.quakeIntensity, Config.Earthquake.Camera)
	end
end

function Island:Reset()
	if self.destroyed then return end
	self.playing, self.quakeRemaining, self.intervalFactor, self.clock, self.burstClock = false, nil, nil, 0, 0
	self.effects:Reset()
	self.shake:Stop()
	for _, data in self.debris do self.debrisPool:Release(data.part, data.lease) end
	table.clear(self.debris)
	for _, data in self.rocks do data.pool:Release(data.part, data.lease) end
	table.clear(self.rocks)
	table.clear(self.rocksUses)
	self.rocksClock = 0
	if self.partUses then table.clear(self.partUses) end
	if self.moveParts then table.clear(self.moveParts) table.clear(self.moveFrames) end
end

function Island:Destroy()
	if self.destroyed then return end
	self:Reset()
	self.destroyed = true
	if self.debrisPool then self.debrisPool:Destroy() end
	for _, pool in self.rockPools or {} do pool:Destroy() end
	self.effects:Destroy()
	self.shake:Destroy()
	self.objects:Destroy()
	table.clear(self.parts)
	self.arena, self.player = nil, nil
end

return Island
