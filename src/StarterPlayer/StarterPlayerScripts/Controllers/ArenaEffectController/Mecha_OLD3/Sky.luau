-- One rotation timeline drives both the sky and the authored structure formation.
local Sky = {}
local Lighting = game:GetService("Lighting")
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)

local function integrate(previous, elapsed, total, stage, startFraction, endFraction)
	local from = math.max(previous, total * startFraction)
	local finish = math.min(elapsed, total * endFraction)
	if not stage.Enable or finish <= from then
		return Vector3.zero
	end
	local settings = stage.Sky
	local steps = math.clamp(math.ceil((finish - from) / 0.05), 1, 4096)
	local step, angles = (finish - from) / steps, Vector3.zero
	for index = 1, steps do
		local time = from + (index - 0.5) * step
		local progress = MotionMath.Eased(MotionMath.Window(time, total, startFraction, endFraction), settings)
		local ramp = if settings.RampTime > 0
			then math.clamp((time - total * startFraction) / settings.RampTime, 0, 1)
			else 1
		ramp = ramp * ramp * (3 - 2 * ramp)
		angles += settings.StartSpeed:Lerp(settings.EndSpeed, progress) * ramp * step
	end
	return angles
end

function Sky.Advance(self, elapsed, total)
	local previous = self.skyElapsed or 0
	self.skyAngles += integrate(
		previous,
		elapsed,
		total,
		Config.Stage1,
		Config.Stage1.StartFraction,
		Config.Stage1.EndFraction
	)
	self.skyElapsed = elapsed
end

local function rotation(angles)
	-- SkyboxOrientation uses Y-X-Z rotation order, matching CFrame.fromOrientation.
	return CFrame.fromOrientation(math.rad(angles.X % 360), math.rad(angles.Y % 360), math.rad(angles.Z % 360))
end

function Sky.Restore(self)
	if self.sky and self.sky.Parent == Lighting then
		self.sky.SkyboxOrientation = self.skyOriginal
	end
	self.sky, self.skyOriginal = nil, nil
end

function Sky.Update(self, relativeRotation)
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky ~= self.sky then
		Sky.Restore(self)
		self.sky, self.skyOriginal = sky, sky and sky.SkyboxOrientation
	end
	if sky then
		if relativeRotation then
			local x, y, z = (relativeRotation * rotation(self.skyOriginal)):ToOrientation()
			sky.SkyboxOrientation = if relativeRotation == CFrame.identity
				then self.skyOriginal
				else Vector3.new(math.deg(x), math.deg(y), math.deg(z))
			return
		end
		local angles = self.skyOriginal + self.skyAngles
		sky.SkyboxOrientation = Vector3.new(angles.X % 360, angles.Y % 360, angles.Z % 360)
	end
end

function Sky.StructureRotation(self)
	if not self.sky then
		return CFrame.identity
	end
	-- Apply the same world rotation relative to the sky's authored orientation.
	return rotation(self.skyOriginal + self.skyAngles) * rotation(self.skyOriginal):Inverse()
end

function Sky.Reset(self)
	Sky.Restore(self)
	self.skyAngles = Vector3.zero
	self.skyElapsed = nil
end

return Sky
