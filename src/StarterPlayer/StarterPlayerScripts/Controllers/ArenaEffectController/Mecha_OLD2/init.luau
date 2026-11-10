local Mecha = {}

Mecha.__index = Mecha
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ObjectPool = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("ObjectPool"))
local Config = require(script.Config)
local Stage1 = require(script.Stage1)
local Stage2 = require(script.Stage2)
local Sky = require(script.Sky)
local MotionMath = require(script.MotionMath)
local EffectTransition = require(script.Parent.Helper.EffectTransition)

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function finiteVector(value)
	return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function findPath(root, path)
	for _, name in path do
		root = root and root:FindFirstChild(name)
		if not root then
			return nil
		end
	end
	return root
end

local function easing(settings, prefix)
	prefix = prefix or ""
	local style, direction = settings[prefix .. "EasingStyle"], settings[prefix .. "EasingDirection"]
	assert(typeof(style) == "EnumItem" and style.EnumType == Enum.EasingStyle, "Mecha requires an EasingStyle")
	assert(
		typeof(direction) == "EnumItem" and direction.EnumType == Enum.EasingDirection,
		"Mecha requires an EasingDirection"
	)
end

local function validateRange(value, minimum, name)
	assert(
		typeof(value) == "NumberRange" and finite(value.Min) and finite(value.Max) and value.Min >= minimum,
		"Mecha " .. name .. " has an invalid range"
	)
end

local function validate()
	local first, second = Config.Stage1, Config.Stage2
	assert(
		finite(first.StartFraction)
			and finite(second.StartFraction)
			and first.StartFraction >= 0
			and first.StartFraction < second.StartFraction
			and second.StartFraction < 1,
		"Mecha requires 0 <= Stage1.StartFraction < Stage2.StartFraction < 1"
	)
	for _, stage in { first, second } do
		assert(type(stage.Enable) == "boolean", "Mecha stages require Enable booleans")
		easing(stage.Sky)
		assert(finiteVector(stage.Sky.StartSpeed) and finiteVector(stage.Sky.EndSpeed), "Mecha sky speeds must be finite Vector3")
		easing(stage)
		assert(
			typeof(stage.Scale) == "Vector2"
				and finite(stage.Scale.X)
				and finite(stage.Scale.Y)
				and stage.Scale.X >= 0
				and stage.Scale.Y >= 0,
			"Mecha Scale must be a finite, nonnegative Vector2"
		)
		validateRange(stage.FinalScale, 0.001, "FinalScale")
		assert(stage.OrientationMode == "Random" or stage.OrientationMode == "FaceCenter", "Mecha OrientationMode must be Random or FaceCenter")
		if stage.OrientationMode == "Random" then
			assert(
				type(stage.OrientationY) == "table" and #stage.OrientationY > 0,
				"Mecha OrientationY requires a nonempty list of angles in degrees"
			)
			for index = 1, #stage.OrientationY do
				assert(finite(stage.OrientationY[index]), "Mecha OrientationY angles must be finite numbers")
			end
		end
		if stage == second then
			validateRange(stage.Floating.Amplitude, 0, "Floating.Amplitude")
			validateRange(stage.Floating.Period, 0.001, "Floating.Period")
			easing(stage.Floating)
		end
		validateRange(stage.Aura.RateMultiplier, 0, "Aura.RateMultiplier")
		assert(type(stage.Aura.Enable) == "boolean", "Mecha Aura.Enable must be a boolean")
		easing(stage.Aura)
		local padding = stage.Aura.Padding
		assert(
			finiteVector(padding) and padding.X >= 0 and padding.Y >= 0 and padding.Z >= 0,
			"Mecha Aura.Padding must be nonnegative"
		)
		local transparency = stage.Transparency
		easing(transparency)
	end
	local transparency = first.Transparency
	assert(
		finite(transparency.FadeInEndFraction)
			and finite(transparency.FadeOutStartFraction)
			and transparency.FadeInEndFraction > 0
			and transparency.FadeInEndFraction <= transparency.FadeOutStartFraction
			and transparency.FadeOutStartFraction < 1,
		"Mecha requires 0 < FadeInEndFraction <= FadeOutStartFraction < 1"
	)
	for _, name in { "FadeInDuration", "FadeOutDuration" } do
		local duration = second.Transparency[name]
		assert(finite(duration) and duration >= 0, "Mecha Stage2.Transparency." .. name .. " must be nonnegative")
	end
	assert(finite(first.StructureSpacing) and first.StructureSpacing >= 0, "Mecha StructureSpacing must be nonnegative")
	assert(type(first.ScaleEnable) == "boolean", "Mecha Stage1.ScaleEnable must be a boolean")
	assert(finite(first.FixedScale) and first.FixedScale >= 0.001, "Mecha FixedScale must be at least 0.001")
	validateRange(first.TravelSpeed, 0.001, "TravelSpeed")
	for _, entry in { { first, "MaxActive" }, { first, "MaxSpawnsPerFrame" }, { second, "StructuresPerSide" } } do
		local value = entry[1][entry[2]]
		assert(finite(value) and value >= 1 and value % 1 == 0, "Mecha " .. entry[2] .. " must be a positive integer")
	end
	assert(finite(second.SpawnInterval) and second.SpawnInterval >= 0, "Mecha SpawnInterval must be nonnegative")
	assert(finite(second.SettleTime) and second.SettleTime > 0, "Mecha SettleTime must be positive")
	validateRange(second.StopRange, 0, "StopRange")
	assert(second.StopRange.Max <= 1, "Mecha StopRange must stay within the path")
	validateRange(second.Orbit.Speed, 0, "Orbit.Speed")
	assert(finite(second.Orbit.RampTime) and second.Orbit.RampTime >= 0, "Mecha Orbit.RampTime must be nonnegative")
	easing(second.Orbit)
end

local eased, interpolate, window = MotionMath.Eased, MotionMath.Interpolate, MotionMath.Window

local function sample(random, range)
	return random:NextNumber(range.Min, range.Max)
end

local function preparePart(part)
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
end

local function projectedWidth(path, rotation, size)
	local direction = (path.finish - path.start).Unit
	return math.abs(direction:Dot(rotation.RightVector)) * size.X
		+ math.abs(direction:Dot(rotation.UpVector)) * size.Y
		+ math.abs(direction:Dot(rotation.LookVector)) * size.Z
end

local function facingRotation(position, center, authoredRotation)
	local direction = Vector3.new(center.X - position.X, 0, center.Z - position.Z)
	if direction.Magnitude < 0.001 then return authoredRotation end
	local yaw = math.atan2(-direction.X, -direction.Z)
	local quarterTurn = math.pi / 2
	yaw = math.round(yaw / quarterTurn) * quarterTurn
	local forward = authoredRotation.LookVector
	local authoredYaw = math.atan2(-forward.X, -forward.Z)
	local tilt = CFrame.Angles(0, -authoredYaw, 0) * authoredRotation
	return (CFrame.Angles(0, yaw, 0) * tilt):Orthonormalize()
end

-- local function facingRotation(position: Vector3, center: Vector3, authoredRotation: CFrame)
-- 	return CFrame.new(position, center) * authoredRotation
-- end

function Mecha:_warn(key, message)
	if self.warned[key] then
		return
	end
	self.warned[key] = true
	warn("[Mecha] " .. message)
end

function Mecha:_paths()
	local misc = findPath(self.arena, Config.MiscPath)
	local starts, ends = {}, {}
	if misc then
		for _, item in misc:GetDescendants() do
			if item:IsA("BasePart") then
				if item.Name == Config.SpawnStartName then
					table.insert(starts, item)
				end
				if item.Name == Config.SpawnEndName then
					table.insert(ends, item)
				end
			end
		end
	end
	table.sort(starts, function(a, b)
		if a.Position.X == b.Position.X then
			return a.Position.Z < b.Position.Z
		end
		return a.Position.X < b.Position.X
	end)
	for _, start in starts do
		local nearest, distance = nil, math.huge
		for index, finish in ends do
			local length = (finish.Position - start.Position).Magnitude
			if length < distance then
				nearest, distance = index, length
			end
		end
		if nearest and distance > 0.001 then
			local finish = table.remove(ends, nearest)
			table.insert(self.paths, {
				start = start.Position,
				finish = finish.Position,
				length = distance,
				slots = {},
				movingSlots = {},
				nextSlot = 0,
				firstSlot = 0,
				activeCount = 0,
			})
		end
	end
	if #self.paths == 0 or #self.paths ~= #starts or #ends > 0 then
		self:_warn(
			"paths",
			"Missing or incomplete Misc.ObjectSpawnStart/ObjectSpawnEnd pairs; only complete paths will spawn structures."
		)
	end
end

function Mecha.new(arena, player)
	validate()
	local self = setmetatable({
		arena = arena,
		player = player,
		random = Random.new(),
		templates = {},
		originals = {},
		paths = {},
		structures = {},
		sideAuras = {},
		warned = {},
		moveParts = {},
		moveFrames = {},
		movesDirty = true,
		orbitAngle = 0,
		skyAngles = Vector3.zero,
	}, Mecha)
	self.objects = Instance.new("Folder")
	self.objects.Name, self.objects.Parent = "MechaEffects", arena
	local runtime = ReplicatedStorage:FindFirstChild("Runtime")
	if not runtime then
		runtime = Instance.new("Folder")
		runtime.Name, runtime.Parent = "Runtime", ReplicatedStorage
	end
	self.storage = Instance.new("Folder")
	self.storage.Name, self.storage.Parent = "MechaTemplates", runtime
	self:_paths()
	assert(not Config.Stage1.Enable or #self.paths <= Config.Stage1.MaxActive, "Mecha Stage1.MaxActive must allow at least one structure per path")
	local center = findPath(arena, Config.CenterPath)
	if not center then
		local original = findPath(ReplicatedStorage, Config.ArenaTemplatePath)
		center = original and findPath(original, Config.CenterPath)
	end
	if center and center:IsA("Model") then
		local box = center:GetBoundingBox()
		local origin = center:GetAttribute("FallingOrigin")
		self.center = if typeof(origin) == "CFrame"
			then (origin * center:GetPivot():ToObjectSpace(box)).Position
			else box.Position
	elseif center and center:IsA("BasePart") then
		self.center = center.Position
	else
		self:_warn("center", "Missing Block.Main.MainPlatform; final structures will settle without orbiting.")
	end
	local dynamic = findPath(arena, Config.DynamicEffectsPath)
	local structures = dynamic and dynamic:FindFirstChild(Config.StructuresName)
	if structures then
		for _, template in structures:GetChildren() do
			if template:IsA("Model") and template.Archivable and template:FindFirstChildWhichIsA("BasePart", true) then
				table.insert(self.templates, template)
				table.insert(self.originals, { instance = template, parent = structures })
				template.Parent = self.storage
			end
		end
	end
	if #self.templates == 0 then
		self:_warn(
			"templates",
			"Missing clonable Models in Decorations.dynamic_vfx.Structures; structure spawning is disabled."
		)
	end
	local aura = dynamic and dynamic:FindFirstChild(Config.AuraName)
	if aura and aura:IsA("BasePart") and aura.Archivable then
		self.auraTemplate = aura
		table.insert(self.originals, { instance = aura, parent = dynamic })
		aura.Parent = self.storage
	elseif (Config.Stage1.Enable and Config.Stage1.Aura.Enable) or (Config.Stage2.Enable and Config.Stage2.Aura.Enable) then
		self:_warn("aura", "Missing clonable Aura Part in Decorations.dynamic_vfx; structures will run without Aura.")
	end
	return self
end

function Mecha:_createAura(settings)
	if not settings.Enable or not self.auraTemplate then
		return nil
	end
	self.auraPool = self.auraPool or ObjectPool.fromTemplate(self.auraTemplate, { Name = "MechaAura", MaxIdle = Config.Stage1.MaxActive })
	local carrier, _, lease = self.auraPool:Acquire()
	if not carrier then
		self:_warn("auraClone", "Aura could not be cloned.")
		return nil
	end
	preparePart(carrier)
	carrier.Transparency = 1
	-- carrier.Color = BrickColor.Red().Color
	local transition = EffectTransition.new({
		StartFraction = 0,
		FullFraction = 1,
		VFXEasingStyle = settings.EasingStyle,
		VFXEasingDirection = settings.EasingDirection,
		SFXEasingStyle = settings.EasingStyle,
		SFXEasingDirection = settings.EasingDirection,
	}, self.player)
	for _, item in carrier:GetDescendants() do
		if item:IsA("ParticleEmitter") then
			item.Enabled = false
			item:Clear()
			item.Shape, item.ShapeStyle = Enum.ParticleEmitterShape.Box, Enum.ParticleEmitterShapeStyle.Volume
			item.LockedToPart = true
			local originalRate = item.Rate
			item.Rate = originalRate * settings.RateMultiplier.Max
			transition:Register(item, nil, originalRate * settings.RateMultiplier.Min)
		elseif item:IsA("BasePart") then
			preparePart(item)
		end
	end
	carrier.Parent = self.objects
	self.movesDirty = true
	return { carrier = carrier, effects = transition, settings = settings, pool = self.auraPool, lease = lease }
end

local function destroyAura(aura)
	if not aura then
		return
	end
	aura.effects:Destroy()
	aura.pool:Release(aura.carrier, aura.lease)
end

function Mecha:_cacheStructure(data)
	-- Derive geometry from the immutable spawn pose, never from last frame's moved/scaled transforms.
	local multiplier = data.scale / data.baseScale
	local offset = data.originalPivotToBox
	data.pivotToBox = offset + offset.Position * (multiplier - 1)
	data.boxSize = data.originalBoxSize * multiplier
	for _, item in data.parts do
		local original = item.originalOffset
		item.offset = original + original.Position * (multiplier - 1)
	end
end

function Mecha:_prepareStructure(side, settings, random, final)
	if #self.templates == 0 then
		return nil
	end
	random = random or self.random
	local template = self.templates[random:NextInteger(1, #self.templates)]
	local animatedScale = final or settings.ScaleEnable
	local data = {
		template = template,
		side = side,
		settings = settings,
		baseScale = template:GetScale(),
		startScale = if animatedScale then math.max(settings.Scale.X, 0.001) else settings.FixedScale,
		finishScale = if animatedScale then math.max(settings.Scale.Y, 0.001) else settings.FixedScale,
		endScale = if animatedScale then sample(random, settings.FinalScale) else settings.FixedScale,
		floatAmplitude = if final then sample(random, settings.Floating.Amplitude) else 0,
		floatPeriod = if final then sample(random, settings.Floating.Period) else 1,
		floatPhase = if final then random:NextNumber() else 0,
	}
	local box, size = template:GetBoundingBox()
	local pivot = template:GetPivot():Orthonormalize()
	local pivotToBox = pivot:ToObjectSpace(box:Orthonormalize())
	local angle = if settings.OrientationMode == "Random" then settings.OrientationY[random:NextInteger(1, #settings.OrientationY)] else 0
	data.authoredRotation = pivot.Rotation
	data.rotation = (CFrame.Angles(0, math.rad(angle), 0) * pivot.Rotation):Orthonormalize()
	local path = self.paths[side]
	if settings.OrientationMode == "FaceCenter" then
		if self.center then
			local lane = path.finish - path.start
			local t = math.clamp((self.center - path.start):Dot(lane) / lane:Dot(lane), 0, 1)
			local closest = path.start + lane * t
			data.rotation = facingRotation(closest, self.center, data.authoredRotation)
		else
			self:_warn("orientationCenter", "Missing main area center; FaceCenter structures retain their authored rotation.")
		end
	end
	local boxRotation = data.rotation * pivotToBox.Rotation
	local halfWidth = projectedWidth(path, boxRotation, size) / 2
	local centerOffset = (path.finish - path.start).Unit:Dot(data.rotation:VectorToWorldSpace(pivotToBox.Position))
	local minimum, maximum = centerOffset - halfWidth, centerOffset + halfWidth
	-- Reserve this model's full scale envelope so growing models cannot clip later on the path.
	local lowScale = math.min(data.startScale, data.finishScale, data.endScale)
	local highScale = math.max(data.startScale, data.finishScale, data.endScale)
	data.rearOffset = math.min(minimum * lowScale, minimum * highScale)
	data.frontOffset = math.max(maximum * lowScale, maximum * highScale)
	return data
end

local function createStructure(template)
	local model = template:Clone()
	if not model then return nil end
	local pivot = model:GetPivot():Orthonormalize()
	local box, size = model:GetBoundingBox()
	local descendants = model:GetDescendants()
	local geometry = { pivotToBox = pivot:ToObjectSpace(box:Orthonormalize()):Orthonormalize(), size = size, parts = {}, effects = {}, count = #descendants }
	for _, item in descendants do
		if item:IsA("BasePart") then
			preparePart(item)
			table.insert(geometry.parts, { part = item, transparency = item.Transparency,
				originalOffset = pivot:ToObjectSpace(item.CFrame:Orthonormalize()):Orthonormalize() })
		elseif item:IsA("ParticleEmitter") or item:IsA("Trail") or item:IsA("Sound") then
			table.insert(geometry.effects, item)
		end
	end
	return model, geometry
end

local function resetStructure(model, geometry)
	if #model:GetDescendants() ~= geometry.count then return false end
	for _, item in geometry.parts do if not item.part:IsDescendantOf(model) then return false end end
	for _, effect in geometry.effects do
		if not effect:IsDescendantOf(model) then return false end
		if effect:IsA("Sound") then effect.PlayOnRemove = false; effect:Stop() else effect:Clear() end
	end
	-- The next pose derives geometry from these immutable offsets, so native pivot/scale reset is unnecessary.
	return true
end

function Mecha:_spawn(side, born, settings, finalSlot, random, prepared)
	prepared = prepared or self:_prepareStructure(side, settings, random, finalSlot ~= nil)
	if not prepared then
		return nil
	end
	self.structurePools = self.structurePools or {}
	local pool = self.structurePools[prepared.template]
	if not pool then
		local template = prepared.template
		pool = ObjectPool.new({ Name = "MechaStructure", MaxIdle = math.max(1, math.ceil(Config.Stage1.MaxActive / math.max(1, #self.templates))),
			Create = function() return createStructure(template) end, Reset = resetStructure })
		self.structurePools[prepared.template] = pool
	end
	local model, geometry, lease = pool:Acquire()
	if not model then
		self:_warn("structureClone", "A structure template could not be cloned.")
		return nil
	end
	local data = table.clone(prepared)
	data.model, data.parts, data.born = model, {}, born
	data.pool, data.lease = pool, lease
	data.final, data.finalSlot = finalSlot ~= nil, finalSlot
	data.originalPivotToBox, data.originalBoxSize = geometry.pivotToBox, geometry.size
	data.pivotToBox, data.boxSize, data.scale = geometry.pivotToBox, geometry.size, model:GetScale()
	for _, original in geometry.parts do
		local part, originalOffset = original.part, original.originalOffset
		table.insert(data.parts, {
			part = part,
			transparency = original.transparency,
			originalOffset = originalOffset,
			offset = originalOffset,
			currentTransparency = 1,
		})
		part.Transparency = 1
	end
	if data.scale ~= data.baseScale then self:_cacheStructure(data) end
	if finalSlot then
		local count, stops = Config.Stage2.StructuresPerSide, Config.Stage2.StopRange
		data.stopFraction = if count == 1
			then (stops.Min + stops.Max) / 2
			else interpolate(stops, (finalSlot - 1) / (count - 1))
		data.duration = Config.Stage2.SettleTime
	else
		data.stopFraction = 1
		data.pathFraction = 0
		data.aura = self:_createAura(settings.Aura)
	end
	model.Parent = self.objects
	data.removalConnection = model.DescendantRemoving:Connect(function(item)
		if item:IsA("BasePart") then
			data.partsDirty, self.movesDirty = true, true
		end
	end)
	self.movesDirty = true
	table.insert(self.structures, data)
	return data
end

function Mecha:_removeStructure(index)
	local data = table.remove(self.structures, index)
	local path = self.paths[data.side]
	if data.finalSlot then
		path.slots[data.finalSlot] = nil
	elseif data.movingSlot then
		path.movingSlots[data.movingSlot] = nil
		path.activeCount = math.max(0, (path.activeCount or 0) - 1)
	end
	if data.removalConnection then data.removalConnection:Disconnect() end
	self.movesDirty = true
	destroyAura(data.aura)
	data.pool:Release(data.model, data.lease)
end

Mecha._stage1EndFraction = Stage1.EndFraction
Mecha._stage1Capacity = Stage1.Capacity
Mecha._stage1Spawns = Stage1.Update
Mecha._finalWave = Stage2.Update
Mecha._advanceAngles = Stage2.AdvanceOrbit
Mecha._advanceSky = Sky.Advance
Mecha._restoreSky = Sky.Restore
Mecha._updateSky = Sky.Update

function Mecha:_syncMoveParts(inSecond)
	local finalSides = {}
	for _, data in self.structures do
		if data.partsDirty then
			local kept = 0
			for _, item in data.parts do
				if item.part:IsDescendantOf(data.model) then
					kept += 1
					data.parts[kept] = item
				end
			end
			for index = #data.parts, kept + 1, -1 do data.parts[index] = nil end
			data.partsDirty = false
		end
		if data.final then finalSides[data.side] = true end
		if data.aura and data.aura.carrier.Parent ~= self.objects then
			destroyAura(data.aura)
			data.aura, self.movesDirty = nil, true
		end
		if not data.final and data.settings.Aura.Enable then
			data.aura = data.aura or self:_createAura(data.settings.Aura)
		elseif data.aura then
			destroyAura(data.aura)
			data.aura, self.movesDirty = nil, true
		end
	end
	for side in self.paths do
		local aura = self.sideAuras[side]
		if aura and aura.carrier.Parent ~= self.objects then
			destroyAura(aura)
			self.sideAuras[side], self.movesDirty = nil, true
		end
		if inSecond and Config.Stage2.Aura.Enable and finalSides[side] then
			self.sideAuras[side] = self.sideAuras[side] or self:_createAura(Config.Stage2.Aura)
		elseif self.sideAuras[side] then
			destroyAura(self.sideAuras[side])
			self.sideAuras[side], self.movesDirty = nil, true
		end
	end
	if not self.movesDirty then return end
	-- Membership changes only on spawn/removal/aura toggles, not every frame.
	table.clear(self.moveParts)
	table.clear(self.moveFrames)
	local function add(part)
		local index = #self.moveParts + 1
		self.moveParts[index], self.moveFrames[index] = part, part.CFrame
		return index
	end
	for _, data in self.structures do
		for _, item in data.parts or {} do item.moveIndex = add(item.part) end
		if data.aura then data.aura.moveIndex = add(data.aura.carrier) end
	end
	for _, aura in self.sideAuras do aura.moveIndex = add(aura.carrier) end
	self.movesDirty = false
end

function Mecha:_pose(data, elapsed, orbitTransform, total)
	local age = math.max(elapsed - data.born, 0)
	local alpha, sizeMultiplier, fade
	if data.final then
		alpha, sizeMultiplier, fade = Stage2.Pose(data, age, elapsed, total)
	else
		alpha, sizeMultiplier, fade = Stage1.Pose(data)
	end
	local scale = data.baseScale * math.max(sizeMultiplier, 0.001)
	if data.scale ~= scale then
		data.model:ScaleTo(scale)
		data.scale = scale
		self:_cacheStructure(data)
	end
	local path = self.paths[data.side]
	local pathFraction = alpha * data.stopFraction
	local position = path.start:Lerp(path.finish, pathFraction)
	local height = 0
	if data.final and data.floatAmplitude > 0 then
		local cycle = (age / data.floatPeriod + data.floatPhase) % 1
		local triangle = if cycle < 0.5 then cycle * 2 else (1 - cycle) * 2
		height = data.floatAmplitude * (2 * eased(triangle, data.settings.Floating) - 1)
	end
	local pivotFrame = CFrame.new(position + Vector3.yAxis * height) * data.rotation
	if data.final then
		pivotFrame = orbitTransform * pivotFrame
	end
	if data.settings.OrientationMode == "FaceCenter" and self.center then
		pivotFrame = CFrame.new(pivotFrame.Position) * if data.rotation then data.rotation else pivotFrame.Rotation --* facingRotation(...)
	end
	-- Place the authored bottom pivot on the path; bounds and aura follow the geometry above it.
	data.pendingPivot = pivotFrame:Orthonormalize()
	data.boxFrame = (data.pendingPivot * data.pivotToBox):Orthonormalize()
	local changed = data.fade ~= fade
	local frames, pivot = self.moveFrames, data.pendingPivot
	for _, item in data.parts do
		if changed then
			local transparency = item.transparency + (1 - item.transparency) * fade
			if item.currentTransparency ~= transparency then
				item.part.Transparency = transparency
				item.currentTransparency = transparency
			end
		end
		-- Both inputs come from immutable/normalized transforms; no accumulated per-part drift.
		frames[item.moveIndex] = pivot * item.offset
	end
	data.fade = fade
end

function Mecha:_poseAura(aura, boxFrame, size, progress)
	if not aura or aura.carrier.Parent ~= self.objects then
		return
	end
	if not finiteVector(size) or not finiteVector(boxFrame.Position) then
		self:_warn("auraBounds", "Invalid structure bounds; skipped aura update.")
		return
	end
	local padded = size + aura.settings.Padding
	if aura.carrier.Size ~= padded then
		aura.carrier.Size = padded
	end
	aura.effects:Update(progress, 1)
	self.moveFrames[aura.moveIndex] = boxFrame
end

function Mecha:_sideBounds(side, formationFrame)
	local minimum, maximum =
		Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local found = false
	local inverse = formationFrame:Inverse()
	for _, data in self.structures do
		if not data.final or data.side ~= side then
			continue
		end
		found = true
		local frame, half = inverse * data.boxFrame, data.boxSize / 2
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				for _, z in { -1, 1 } do
					local point = frame:PointToWorldSpace(half * Vector3.new(x, y, z))
					minimum = Vector3.new(
						math.min(minimum.X, point.X),
						math.min(minimum.Y, point.Y),
						math.min(minimum.Z, point.Z)
					)
					maximum = Vector3.new(
						math.max(maximum.X, point.X),
						math.max(maximum.Y, point.Y),
						math.max(maximum.Z, point.Z)
					)
				end
			end
		end
	end
	if not found then
		return nil
	end
	return formationFrame * CFrame.new((minimum + maximum) / 2), maximum - minimum
end

function Mecha:Update(elapsed, total, _dt)
	if self.destroyed then
		return
	end
	if not finite(elapsed) or not finite(total) or total <= 0 then
		self:Reset()
		return
	end
	-- Movement/floating continues after the match timer ends; property progression clamps in window().
	elapsed = math.max(elapsed, 0)
	if self.lastElapsed and elapsed < self.lastElapsed then
		self:Reset()
	end
	self.lastElapsed = elapsed
	local inFirst = Stage1.IsActive(elapsed, total)
	local inSecond = Stage2.IsActive(elapsed, total)
	if not inFirst and not inSecond then
		self:Reset()
		self.lastElapsed = elapsed
		return
	end
	for i = #self.structures, 1, -1 do
		local data = self.structures[i]
		if data.model.Parent ~= self.objects then
			self:_removeStructure(i)
		end
	end
	for index = #self.structures, 1, -1 do
		if self.structures[index].final ~= inSecond then self:_removeStructure(index) end
	end
	if inFirst then
		self:_stage1Spawns(elapsed, total)
	else
		self:_finalWave(elapsed, total)
	end
	self:_advanceAngles(elapsed, total)
	self:_advanceSky(elapsed, total)
	local formationFrame = if self.center
		then CFrame.new(self.center) * CFrame.Angles(0, self.orbitAngle % (math.pi * 2), 0)
		else CFrame.new()
	local orbitTransform = if self.center then formationFrame * CFrame.new(-self.center) else CFrame.new()
	local firstProgress = window(elapsed, total, Config.Stage1.StartFraction, self:_stage1EndFraction())
	local secondProgress = window(elapsed, total, Config.Stage2.StartFraction, 1)
	self:_syncMoveParts(inSecond)
	for _, data in self.structures do
		self:_pose(data, elapsed, orbitTransform, total)
		if data.aura then
			self:_poseAura(data.aura, data.boxFrame, data.boxSize, firstProgress)
		end
	end
	for side, aura in self.sideAuras do
		local box, size = self:_sideBounds(side, formationFrame)
		if box then
			self:_poseAura(aura, box, size, secondProgress)
		end
	end
	if #self.moveParts > 0 then
		workspace:BulkMoveTo(self.moveParts, self.moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	-- BulkMoveTo moves geometry, not a Model's WorldPivot. Keep native scaling centered on the logical pose.
	for _, data in self.structures do
		if not data.model.PrimaryPart then
			data.model.WorldPivot = data.pendingPivot
		end
	end
	self:_updateSky()
end

function Mecha:RefreshPlayer()
	if self.destroyed then
		return
	end
	for _, data in self.structures do
		if data.aura then
			data.aura.effects:RefreshPlayer()
		end
	end
	for _, aura in self.sideAuras do
		aura.effects:RefreshPlayer()
	end
end

function Mecha:Reset()
	if self.destroyed then
		return
	end
	for i = #self.structures, 1, -1 do
		self:_removeStructure(i)
	end
	for _, aura in self.sideAuras do
		destroyAura(aura)
	end
	table.clear(self.sideAuras)
	Stage1.Reset(self)
	Stage2.Reset(self)
	table.clear(self.moveParts)
	table.clear(self.moveFrames)
	self.movesDirty = true
	self.lastElapsed = nil
	Sky.Reset(self)
end

function Mecha:Destroy()
	if self.destroyed then
		return
	end
	self:Reset()
	self.destroyed = true
	for _, pool in self.structurePools or {} do pool:Destroy() end
	if self.auraPool then self.auraPool:Destroy() end
	for _, original in self.originals do
		if original.instance.Parent == self.storage and original.parent:IsDescendantOf(self.arena) then
			original.instance.Parent = original.parent
		end
	end
	self.objects:Destroy()
	self.storage:Destroy()
	table.clear(self.templates)
	table.clear(self.originals)
	table.clear(self.paths)
	self.arena, self.player, self.auraTemplate = nil, nil, nil
end

return Mecha
