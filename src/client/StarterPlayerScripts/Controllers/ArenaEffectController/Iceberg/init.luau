-- Presents iceberg behavior using logical Player data access.
local Iceberg = {}
Iceberg.__index = Iceberg
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)
local Config = require(script.Config)
local Helper = script.Parent.Helper
local EffectTransition = require(Helper.EffectTransition)

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

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

function Iceberg.new(arena, player)
	assert(
		type(Config.TornadoTravelTime) == "number"
			and Config.TornadoTravelTime > 0
			and Config.TornadoTravelTime < math.huge,
		"Iceberg.Config.TornadoTravelTime must be finite and positive"
	)
	assert(typeof(Config.TornadoOffset) == "Vector3", "Iceberg.Config.TornadoOffset must be a Vector3")
	local force = Config.TornadoForce
	assert(type(force) == "table" and type(force.Enabled) == "boolean", "Iceberg TornadoForce.Enabled must be a boolean")
	assert(finite(force.StartFraction) and finite(force.FullFraction) and force.StartFraction >= 0
		and force.StartFraction < force.FullFraction and force.FullFraction <= 1, "Iceberg TornadoForce requires 0 <= StartFraction < FullFraction <= 1")
	assert(finite(force.Value) and force.Value >= 0, "Iceberg TornadoForce.Value must be finite and nonnegative")
	assert(typeof(force.EasingStyle) == "EnumItem" and force.EasingStyle.EnumType == Enum.EasingStyle, "Iceberg TornadoForce easing style is invalid")
	assert(typeof(force.EasingDirection) == "EnumItem" and force.EasingDirection.EnumType == Enum.EasingDirection, "Iceberg TornadoForce easing direction is invalid")
	local self = setmetatable({ arena = arena, player = player }, Iceberg)
	self.effects = EffectTransition.new(Config, player)
	local folder = findPath(arena, Config.DynamicEffectsPath)
	if folder then
		for _, instance in folder:GetDescendants() do
			self.effects:Register(instance)
		end
	end
	local tornado = findPath(arena, Config.TornadoPath)
	if tornado and tornado:IsA("BasePart") then
		self.tornado = tornado
		self.motion = { start = tornado.Position, counter = 0, sign = 1 }
	end
	return self
end

function Iceberg:_clearForce()
	if self.pullForce then self.pullForce:Destroy() end
	if self.pullAttachment then self.pullAttachment:Destroy() end
	self.pullForce, self.pullAttachment, self.pullRoot = nil, nil, nil
end

function Iceberg:_updateForce(elapsed, total)
	local settings = Config.TornadoForce
	if self.destroyed or not settings.Enabled or self.player ~= Players.LocalPlayer
		or PlayerData.Get(self.player, "IsOnArena") ~= true or not finite(elapsed)
		or not finite(total) or total <= 0 or not self.tornado
		or not self.tornado:IsDescendantOf(self.arena) then
		self:_clearForce()
		return
	end
	local fraction = math.clamp(elapsed / total, 0, 1)
	local alpha = math.clamp((fraction - settings.StartFraction) / (settings.FullFraction - settings.StartFraction), 0, 1)
	local acceleration = settings.Value * math.clamp(TweenService:GetValue(alpha, settings.EasingStyle, settings.EasingDirection), 0, 1)
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if acceleration <= 0 or not root or not root:IsA("BasePart") or not humanoid
		or humanoid.Health <= 0 or not finite(root.AssemblyMass) or root.AssemblyMass <= 0 then
		self:_clearForce()
		return
	end
	if self.pullRoot ~= root or not self.pullForce or self.pullForce.Parent ~= root
		or not self.pullAttachment or self.pullAttachment.Parent ~= root then
		self:_clearForce()
		self.pullRoot = root
		self.pullAttachment = Instance.new("Attachment")
		self.pullAttachment.Name = "IcebergTornadoPullAttachment"
		self.pullAttachment.Parent = root
		self.pullForce = Instance.new("VectorForce")
		self.pullForce.Name = "IcebergTornadoPull"
		self.pullForce.Attachment0 = self.pullAttachment
		self.pullForce.RelativeTo = Enum.ActuatorRelativeTo.World
		self.pullForce.ApplyAtCenterOfMass = true
		self.pullForce.Parent = root
	end
	local offset = self.tornado.Position - root.Position
	self.pullForce.Force = if offset.Magnitude > 0.0001 then offset.Unit * acceleration * root.AssemblyMass else Vector3.zero
end

function Iceberg:Update(elapsed, total, dt)
	if self.destroyed then
		return
	end
	self.effects:Update(elapsed, total)
	self.forceElapsed, self.forceTotal = elapsed, total
	local part, data = self.tornado, self.motion
	if part and not part:IsDescendantOf(self.arena) then
		self.tornado, self.motion = nil, nil
		self:_clearForce()
		return
	end
	if part then
		-- Match the old loop's clamped endpoints and direction reversal.
		data.counter += dt * data.sign
		if data.counter > Config.TornadoTravelTime then
			data.counter, data.sign = Config.TornadoTravelTime, -1
		elseif data.counter < 0 then
			data.counter, data.sign = 0, 1
		end
		part.Position = data.start:Lerp(data.start + Config.TornadoOffset, data.counter / Config.TornadoTravelTime)
	end
	self:_updateForce(elapsed, total)
end

function Iceberg:Reset()
	if not self.destroyed then
		self.effects:Reset()
		self.forceElapsed, self.forceTotal = nil, nil
		self:_clearForce()
	end
end

function Iceberg:RefreshPlayer()
	if not self.destroyed then
		self.effects:RefreshPlayer()
		self:_updateForce(self.forceElapsed, self.forceTotal)
	end
end

function Iceberg:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	self.effects:Destroy()
	self:_clearForce()
	self.player, self.forceElapsed, self.forceTotal = nil, nil, nil
	self.tornado, self.motion, self.arena = nil, nil, nil
end

return Iceberg
