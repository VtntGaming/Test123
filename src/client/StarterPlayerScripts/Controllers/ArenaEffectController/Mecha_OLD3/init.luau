-- Animate authored structures in place. No templates, spawning, pooling or scaling.
local Mecha = {}
Mecha.__index = Mecha
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(script.Config)
local Sky = require(script.Sky)
local Stage1 = require(script.Stage1)
local Sounds = require(script.Sounds)

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function findPath(root, path)
	for _, name in path do
		root = root and root:FindFirstChild(name)
	end
	return root
end

local function easing(settings)
	assert(
		typeof(settings.EasingStyle) == "EnumItem" and settings.EasingStyle.EnumType == Enum.EasingStyle,
		"Invalid Mecha EasingStyle"
	)
	assert(
		typeof(settings.EasingDirection) == "EnumItem" and settings.EasingDirection.EnumType == Enum.EasingDirection,
		"Invalid Mecha EasingDirection"
	)
end

local function validate()
	assert(type(Config.ReturnToNormal) == "boolean", "Mecha ReturnToNormal must be a boolean")
	assert(finite(Config.ReturnDuration) and Config.ReturnDuration >= 0, "Invalid Mecha ReturnDuration")
	local stage = Config.Stage1
	assert(
		finite(stage.StartFraction)
			and finite(stage.EndFraction)
			and stage.StartFraction >= 0
			and stage.StartFraction < stage.EndFraction
			and stage.EndFraction <= 1,
		"Invalid Mecha stage fractions"
	)
	assert(type(stage.Enable) == "boolean", "Mecha Stage1 requires an Enable boolean")
	easing(stage.Sound)
	for _, name in { "FadeInDuration", "FadeOutDuration" } do
		assert(finite(stage.Sound[name]) and stage.Sound[name] >= 0, "Invalid Mecha Sound." .. name)
	end
	assert(type(stage.OrbitAroundCenter) == "boolean", "Mecha Stage1 requires an OrbitAroundCenter boolean")
	easing(stage.Sky)
	for _, speed in { stage.Sky.StartSpeed, stage.Sky.EndSpeed } do
		assert(
			typeof(speed) == "Vector3" and finite(speed.X) and finite(speed.Y) and finite(speed.Z),
			"Mecha sky speeds must be finite Vector3 values"
		)
	end
	assert(finite(stage.Sky.RampTime) and stage.Sky.RampTime >= 0, "Invalid Mecha sky RampTime")
	easing(stage.Transparency)
	assert(
		finite(stage.Transparency.FadeOutDuration) and stage.Transparency.FadeOutDuration >= 0,
		"Invalid Mecha FadeOutDuration"
	)
end

local function centerOf(object)
	if not object then
		return nil
	end
	if object:IsA("BasePart") then
		return object.Position
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

local function capture(self, object)
	local data = { object = object, pivot = object:GetPivot(), parts = {}, visuals = {} }
	local descendants = object:GetDescendants()
	table.insert(descendants, 1, object)
	for _, item in descendants do
		if item:IsA("BasePart") then
			table.insert(data.parts, {
				instance = item,
				anchored = item.Anchored,
				collide = item.CanCollide,
				touch = item.CanTouch,
				query = item.CanQuery,
			})
			item.Anchored, item.CanCollide, item.CanTouch, item.CanQuery = true, false, false, false
		end
		if
			item:IsA("BasePart")
			or item:IsA("Decal")
			or item:IsA("Texture")
			or item:IsA("ParticleEmitter")
			or item:IsA("Beam")
			or item:IsA("Trail")
		then
			table.insert(data.visuals, {
				instance = item,
				transparency = item.Transparency,
				enabled = if item:IsA("ParticleEmitter")
						or item:IsA("Beam")
						or item:IsA("Trail")
					then item.Enabled
					else nil,
			})
		elseif item:IsA("Light") then
			table.insert(data.visuals, { instance = item, brightness = item.Brightness, enabled = item.Enabled })
		end
	end
	table.insert(self.structures, data)
end

function Mecha.new(arena, player)
	validate()
	local self = setmetatable({
		arena = arena,
		player = player,
		structures = {},
		sounds = {},
		fade = 0,
		lastRotation = CFrame.identity,
		lastOrbit = Config.Stage1.OrbitAroundCenter,
		skyAngles = Vector3.zero,
	}, Mecha)
	self.center = centerOf(findPath(arena, Config.CenterPath))
		or centerOf(findPath(findPath(ReplicatedStorage, Config.ArenaTemplatePath), Config.CenterPath))
	local dynamic = findPath(arena, Config.DynamicEffectsPath)
	local structures = dynamic and dynamic:FindFirstChild(Config.StructuresName)
	local function collect(container)
		if container:IsA("Model") or container:IsA("BasePart") then
			capture(self, container)
		else
			for _, child in container:GetChildren() do
				collect(child)
			end
		end
	end
	if structures then
		Sounds.Capture(self, structures)
		collect(structures)
	end
	self.center = self.center or centerOf(structures) or arena:GetPivot().Position
	return self
end

function Mecha:_apply(rotation, fade)
	local orbit = Config.Stage1.OrbitAroundCenter
	local move, changeFade = rotation ~= self.lastRotation or orbit ~= self.lastOrbit, fade ~= self.fade
	if not move and not changeFade then
		return
	end
	local transform = CFrame.new(self.center) * rotation * CFrame.new(-self.center)
	for _, data in self.structures do
		if data.object:IsDescendantOf(self.arena) then
			if move then
				local pivot = if orbit
					then transform * data.pivot
					else CFrame.new(data.pivot.Position) * rotation * data.pivot.Rotation
				data.object:PivotTo(pivot)
			end
			if changeFade then
				for _, visual in data.visuals do
					--Stage1.ApplyFade(visual, fade)
				end
			end
		end
	end
	self.lastRotation, self.lastOrbit, self.fade = rotation, orbit, fade
end

function Mecha:Finish()
	if self.destroyed then
		return
	end
	Sounds.Finish(self, self.lastElapsed or 0)
	if self.destroyed or not Config.ReturnToNormal or self.returnStarted ~= nil then
		return
	end
	self.returnStarted = self.lastElapsed or 0
	self.returnRotation = Sky.StructureRotation(self)
end

function Mecha:Update(elapsed, total, _dt)
	if self.destroyed then
		return
	end
	if not finite(elapsed) or not finite(total) or total <= 0 then
		self:Reset()
		return
	end
	elapsed = math.max(elapsed, 0)
	if self.lastElapsed and elapsed < self.lastElapsed then
		self:Reset()
	end
	self.lastElapsed = elapsed
	Sounds.Update(self, elapsed, total)
	if self.returnStarted == nil then
		Sky.Advance(self, elapsed, total)
		Sky.Update(self)
		if elapsed >= total * Config.Stage1.EndFraction then
			self:Finish()
			if self.returnStarted ~= nil then
				self.returnStarted = total * Config.Stage1.EndFraction
			end
		end
	end
	if self.returnStarted ~= nil then
		local progress = if Config.ReturnDuration > 0
			then math.clamp((elapsed - self.returnStarted) / Config.ReturnDuration, 0, 1)
			else 1
		local alpha = progress * progress * (3 - 2 * progress)
		local rotation = self.returnRotation:Lerp(CFrame.identity, alpha)
		Sky.Update(self, rotation)
		self:_apply(rotation, self.fade)
		return
	end
	local rotation = if Stage1.IsActive(elapsed, total) then Sky.StructureRotation(self) else CFrame.identity
	self:_apply(rotation, Stage1.Fade(elapsed, total))
end

function Mecha:Reset()
	if self.destroyed then
		return
	end
	self:_apply(CFrame.identity, 0)
	Sky.Reset(self)
	Sounds.Reset(self)
	self.lastElapsed = nil
	self.returnStarted, self.returnRotation = nil, nil
end

function Mecha:RefreshPlayer() end

function Mecha:Destroy()
	if self.destroyed then
		return
	end
	self:Reset()
	self.destroyed = true
	for _, data in self.structures do
		for _, part in data.parts do
			if part.instance:IsDescendantOf(self.arena) then
				part.instance.Anchored, part.instance.CanCollide, part.instance.CanTouch, part.instance.CanQuery =
					part.anchored, part.collide, part.touch, part.query
			end
		end
	end
	table.clear(self.structures)
	table.clear(self.sounds)
	self.arena, self.player = nil, nil
end

return Mecha
