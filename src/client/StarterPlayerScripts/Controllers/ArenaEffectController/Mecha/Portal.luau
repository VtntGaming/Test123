-- Only emitter properties change; Portal parts and attachments keep their authored transforms.
local Portal = {}
Portal.__index = Portal

local function closestFace(direction)
	local x, y, z = math.abs(direction.X), math.abs(direction.Y), math.abs(direction.Z)
	if x >= y and x >= z then
		return if direction.X >= 0 then Enum.NormalId.Right else Enum.NormalId.Left
	elseif y >= z then
		return if direction.Y >= 0 then Enum.NormalId.Top else Enum.NormalId.Bottom
	end
	return if direction.Z >= 0 then Enum.NormalId.Back else Enum.NormalId.Front
end

local function planeNormal(size)
	if size.X <= size.Y and size.X <= size.Z then
		return Vector3.xAxis
	elseif size.Y <= size.Z then
		return Vector3.yAxis
	end
	return Vector3.zAxis
end

function Portal.new(model, settings)
	local self = setmetatable({ model = model, settings = settings, emitters = {} }, Portal)
	if not model then
		return self
	end
	for _, item in model:GetDescendants() do
		if not item:IsA("ParticleEmitter") then
			continue
		end
		local source = item.Parent
		if not source or not (source:IsA("BasePart") or source:IsA("Attachment")) then
			continue
		end
		table.insert(self.emitters, {
			instance = item,
			rate = item.Rate,
			speed = item.Speed,
			enabled = item.Enabled,
			direction = item.EmissionDirection,
			source = source,
			part = if source:IsA("BasePart") then source else source:FindFirstAncestorWhichIsA("BasePart"),
		})
		item.Enabled, item.Rate = false, 0
		item:Clear()
	end
	return self
end

function Portal:Update(velocity, angularVelocity)
	local speed = velocity.Magnitude
	local moving = speed > 0.001
	local multiplier = math.min(speed / self.settings.ReferenceSpeed, self.settings.MaxRateMultiplier)
	local turnSpeed = if angularVelocity then angularVelocity.Magnitude else 0
	local speedMultiplier = math.min(speed / self.settings.ReferenceSpeed
		+ turnSpeed / self.settings.ReferenceAngularSpeed, self.settings.MaxSpeedMultiplier)
	for _, data in self.emitters do
		local emitter, source = data.instance, data.source
		if emitter:IsDescendantOf(self.model) and source:IsDescendantOf(self.model) then
			local parallel = false
			if moving then
				local frame = if source:IsA("Attachment") then source.WorldCFrame else source.CFrame
				emitter.EmissionDirection = closestFace(frame:VectorToObjectSpace(velocity))
				if data.part and data.part:IsDescendantOf(self.model) then
					-- Use the selected emission face, including attachment rotation, in the portal plane's axes.
					local direction = data.part.CFrame:VectorToObjectSpace(
						frame:VectorToWorldSpace(Vector3.FromNormalId(emitter.EmissionDirection))
					)
					parallel = math.abs(direction:Dot(planeNormal(data.part.Size))) < 0.0001
				end
			end
			emitter.Rate = data.rate * multiplier
			local minimum = math.max(self.settings.MinParticleSpeed, data.speed.Min * speedMultiplier)
			emitter.Speed = NumberRange.new(minimum, math.max(minimum, data.speed.Max * speedMultiplier))
			emitter.Enabled = data.enabled and moving and multiplier > 0 and parallel
		end
	end
end

function Portal:Reset()
	for _, data in self.emitters do
		if data.instance.Parent then
			data.instance.Enabled, data.instance.Rate = false, 0
			data.instance.EmissionDirection = data.direction
			data.instance.Speed = data.speed
			data.instance:Clear()
		end
	end
end

function Portal:Destroy()
	self:Reset()
	for _, data in self.emitters do
		if data.instance.Parent then
			data.instance.Rate, data.instance.Enabled = data.rate, data.enabled
		end
	end
	table.clear(self.emitters)
	self.model = nil
end

return Portal
