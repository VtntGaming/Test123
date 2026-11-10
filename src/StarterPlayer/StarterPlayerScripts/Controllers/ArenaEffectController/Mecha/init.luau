-- Move authored scenery opposite a virtual arena; the gameplay arena stays stationary.
local Mecha = {}
Mecha.__index = Mecha
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Config)
local Sky = require(script.Sky)
local Stage1 = require(script.Stage1)
local Motion = require(script.Motion)
local Portal = require(script.Portal)

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function finiteVector(value)
	return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function findPath(root, path)
	for _, name in path do
		root = root and root:FindFirstChild(name)
	end
	return root
end

local function validate()
	assert(finite(Config.Portal.ReferenceSpeed) and Config.Portal.ReferenceSpeed > 0,
		"Mecha Portal.ReferenceSpeed must be positive")
	assert(finite(Config.Portal.MaxRateMultiplier) and Config.Portal.MaxRateMultiplier >= 0,
		"Invalid Mecha Portal.MaxRateMultiplier")
	assert(finite(Config.Portal.ReferenceAngularSpeed) and Config.Portal.ReferenceAngularSpeed > 0,
		"Mecha Portal.ReferenceAngularSpeed must be positive")
	for _, name in { "MaxSpeedMultiplier", "MinParticleSpeed" } do
		assert(finite(Config.Portal[name]) and Config.Portal[name] >= 0, "Invalid Mecha Portal." .. name)
	end
	local stage = Config.Stage1
	assert(type(stage.Enable) == "boolean", "Mecha Stage1 requires an Enable boolean")
	assert(finite(stage.StartFraction) and stage.StartFraction >= 0 and stage.StartFraction < 1,
		"Mecha StartFraction must satisfy 0 <= value < 1")
	assert(type(stage.Movements) == "table", "Mecha Movements must be a list")
	for _, movement in stage.Movements do
		assert(finite(movement.Duration) and movement.Duration > 0, "Mecha movement Duration must be positive")
		assert(finiteVector(movement.Acceleration), "Mecha Acceleration must be a finite Vector3")
		assert(finiteVector(movement.AngularVelocity), "Mecha AngularVelocity must be a finite Vector3")
	end
	local fade = stage.StructureFade
	assert(finite(fade.StartAfter) and fade.StartAfter >= 0, "Invalid Mecha StructureFade.StartAfter")
	assert(finite(fade.Duration) and fade.Duration >= 0, "Invalid Mecha StructureFade.Duration")
	assert(typeof(fade.EasingStyle) == "EnumItem" and fade.EasingStyle.EnumType == Enum.EasingStyle,
		"Invalid Mecha StructureFade.EasingStyle")
	assert(typeof(fade.EasingDirection) == "EnumItem" and fade.EasingDirection.EnumType == Enum.EasingDirection,
		"Invalid Mecha StructureFade.EasingDirection")
end

local function centerOf(object)
	if not object then
		return nil
	end
	if object:IsA("BasePart") then
		local original = object:GetAttribute("FallingOrigin")
		return if typeof(original) == "CFrame" then original.Position else object.Position
	end
	if object:IsA("Model") then
		local box = object:GetBoundingBox()
		local original = object:GetAttribute("FallingOrigin")
		return if typeof(original) == "CFrame"
			then (original * object:GetPivot():ToObjectSpace(box)).Position
			else box.Position
	end
	return nil
end

local function capture(self, structures)
	local function collect(object)
		if object:IsA("Model") or object:IsA("BasePart") then
			table.insert(self.structures, { object = object, pivot = object:GetPivot() })
		else
			for _, child in object:GetChildren() do
				collect(child)
			end
		end
	end
	collect(structures)
	local descendants = structures:GetDescendants()
	table.insert(descendants, 1, structures)
	for _, item in descendants do
		if item:IsA("Sound") then
			item:Stop()
		end
		if item:IsA("BasePart") then
			table.insert(self.parts, {
				instance = item,
				anchored = item.Anchored,
				collide = item.CanCollide,
				touch = item.CanTouch,
				query = item.CanQuery,
			})
			item.Anchored, item.CanCollide, item.CanTouch, item.CanQuery = true, false, false, false
		end
		if item:IsA("BasePart") or item:IsA("Decal") or item:IsA("Texture")
			or item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail") then
			table.insert(self.visuals, {
				instance = item,
				transparency = item.Transparency,
				enabled = if item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail")
					then item.Enabled else nil,
			})
		elseif item:IsA("Light") then
			table.insert(self.visuals, { instance = item, brightness = item.Brightness, enabled = item.Enabled })
		end
	end
end

function Mecha.new(arena, player)
	validate()
	local self = setmetatable({
		arena = arena,
		player = player,
		structures = {},
		parts = {},
		visuals = {},
		fade = 0,
		lastTransform = CFrame.identity,
		motion = Motion.new(Config.Stage1.Movements),
	}, Mecha)
	local dynamic = findPath(arena, Config.DynamicEffectsPath)
	local structures = dynamic and dynamic:FindFirstChild(Config.StructuresName)
	local center = centerOf(findPath(arena, Config.CenterPath))
		or centerOf(findPath(findPath(ReplicatedStorage, Config.ArenaTemplatePath), Config.CenterPath))
		or centerOf(structures) or arena:GetPivot().Position
	self.origin = CFrame.new(center) * arena:GetPivot().Rotation
	if structures then
		capture(self, structures)
	end
	self.portal = Portal.new(dynamic and dynamic:FindFirstChild(Config.Portal.Name), Config.Portal)
	return self
end

function Mecha:_apply(transform, fade)
	local move, changeFade = transform ~= self.lastTransform, fade ~= self.fade
	if move then
		for _, data in self.structures do
			if data.object:IsDescendantOf(self.arena) then
				data.object:PivotTo(transform * data.pivot)
			end
		end
	end
	if changeFade then
		for _, visual in self.visuals do
			Stage1.ApplyFade(visual, fade)
		end
	end
	self.lastTransform, self.fade = transform, fade
end

function Mecha:_destroyStructures()
	for _, data in self.structures do
		if data.object:IsDescendantOf(self.arena) then
			data.object:Destroy()
		end
	end
	table.clear(self.structures)
	table.clear(self.parts)
	table.clear(self.visuals)
	self.structuresDestroyed = true
end

-- A match ending does not interrupt departure or start a recovery transition.
function Mecha:Finish() end

function Mecha:Update(elapsed, total, dt)
	if self.destroyed or not finite(elapsed) or not finite(total) or total <= 0 then
		return
	end
	if self.timelineElapsed == nil then
		-- Seed once for late attachment; subsequent server reports cannot advance or rewind the effect.
		self.timelineElapsed = math.max(elapsed, 0)
	elseif finite(dt) and dt > 0 then
		self.timelineElapsed += dt
	end
	if not Stage1.IsActive(self.timelineElapsed, total) then
		return
	end
	local age = math.max(self.timelineElapsed - total * Config.Stage1.StartFraction, 0)
	local virtualPose, velocity, angularVelocity = Motion.Evaluate(self.motion, age)
	local transform = self.origin * virtualPose:Inverse() * self.origin:Inverse()
	-- Express virtual velocity in the current arena's axes, then in the stationary arena's world frame.
	self.portal:Update(self.origin:VectorToWorldSpace(virtualPose:VectorToObjectSpace(velocity)), angularVelocity)
	Sky.Update(self, transform.Rotation)
	if not self.structuresDestroyed then
		local fade = Stage1.Fade(age)
		self:_apply(transform, fade)
		if age >= Config.Stage1.StructureFade.StartAfter + Config.Stage1.StructureFade.Duration then
			self:_destroyStructures()
		end
	end
end

function Mecha:Reset()
	if self.destroyed then
		return
	end
	self:_apply(CFrame.identity, 0)
	Sky.Restore(self)
	self.portal:Reset()
	self.timelineElapsed = nil
	self.motion = Motion.new(Config.Stage1.Movements)
	-- Destroyed scenery is never recreated; the next arena supplies fresh instances.
end

function Mecha:RefreshPlayer() end

function Mecha:Destroy()
	if self.destroyed then
		return
	end
	self:Reset()
	self.portal:Destroy()
	self.destroyed = true
	for _, part in self.parts do
		if part.instance:IsDescendantOf(self.arena) then
			part.instance.Anchored, part.instance.CanCollide, part.instance.CanTouch, part.instance.CanQuery =
				part.anchored, part.collide, part.touch, part.query
		end
	end
	table.clear(self.structures)
	table.clear(self.parts)
	table.clear(self.visuals)
	self.motion, self.arena, self.player = nil, nil, nil
end

return Mecha
