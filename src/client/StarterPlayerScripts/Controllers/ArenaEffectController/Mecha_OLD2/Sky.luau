-- Integrates sky motion across both stages and restores the original SkyboxOrientation.
local Sky = {}
local Lighting = game:GetService("Lighting")
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)
local eased, window = MotionMath.Eased, MotionMath.Window

function Sky.Advance(self, elapsed, total)
	local first, second = Config.Stage1, Config.Stage2
	local previous = self.skyElapsed or total * first.StartFraction
	self.skyAngles = self.skyAngles or Vector3.zero
	local function integrate(stage, startTime, endTime, startFraction, endFraction, rampTime)
		local from, finish = math.max(previous, startTime), math.min(elapsed, endTime)
		local delta = finish - from
		if delta <= 0 then
			return
		end
		local steps = math.clamp(math.ceil(delta / 0.1), 1, 2048)
		local step = delta / steps
		for index = 1, steps do
			local time = from + (index - 0.5) * step
			local progress = eased(window(time, total, startFraction, endFraction), stage.Sky)
			local ramp = if rampTime and rampTime > 0 then math.clamp((time - startTime) / rampTime, 0, 1) else 1
			ramp = ramp * ramp * (3 - 2 * ramp)
			self.skyAngles += stage.Sky.StartSpeed:Lerp(stage.Sky.EndSpeed, progress) * ramp * step
		end
	end
	if first.Enable then
		local endFraction = self:_stage1EndFraction()
		integrate(
			first,
			total * first.StartFraction,
			if second.Enable then total * endFraction else math.huge,
			first.StartFraction,
			endFraction,
			nil
		)
	end
	if second.Enable then
		local orbitStart = total * second.StartFraction
			+ (second.StructuresPerSide - 1) * second.SpawnInterval
			+ second.SettleTime
		integrate(second, orbitStart, math.huge, second.StartFraction, 1, second.Orbit.RampTime)
	end
	self.skyElapsed = elapsed
end

function Sky.Restore(self)
	if self.sky and self.sky.Parent == Lighting then
		self.sky.SkyboxOrientation = self.skyOriginal
	end
	self.sky, self.skyOriginal = nil, nil
end

function Sky.Update(self)
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky ~= self.sky then
		self:_restoreSky()
		self.sky = sky
		self.skyOriginal = sky and sky.SkyboxOrientation
	end
	if sky then
		local angles = self.skyOriginal + self.skyAngles
		sky.SkyboxOrientation = Vector3.new(angles.X % 360, angles.Y % 360, angles.Z % 360)
	else
		self:_warn("sky", "No Sky in Lighting; sky rotation is disabled until a Sky is available.")
	end
end

function Sky.Reset(self)
	self.skyAngles, self.skyElapsed = Vector3.zero, nil
	Sky.Restore(self)
end

return Sky
