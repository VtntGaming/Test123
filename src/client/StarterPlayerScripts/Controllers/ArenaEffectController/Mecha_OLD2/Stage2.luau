-- Final spawn wave, settling schedule and orbit integration.
local Stage2 = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)
local eased, interpolate, window = MotionMath.Eased, MotionMath.Interpolate, MotionMath.Window

function Stage2.Update(self, elapsed, total)
	local settings = Config.Stage2
	local start = total * settings.StartFraction
	local matchId = ReplicatedValues.GetNumber(ReplicatedStorage, "MatchId") or 0
	for side, path in self.paths do
		for slot = 1, settings.StructuresPerSide do
			local born = start + (slot - 1) * settings.SpawnInterval
			if elapsed >= born and not path.slots[slot] then
				local random = Random.new(matchId * 1009 + side * 101 + slot)
				path.slots[slot] = self:_spawn(side, born, settings, slot, random)
			end
		end
	end
end

function Stage2.AdvanceOrbit(self, elapsed, total)
	local stage = Config.Stage2
	if not stage.Enable then
		self.orbitStarted, self.angularElapsed = false, elapsed
		return
	end
	local orbitStart = total * stage.StartFraction
		+ (stage.StructuresPerSide - 1) * stage.SpawnInterval
		+ stage.SettleTime
	self.orbitStarted = elapsed >= orbitStart
	if not self.orbitStarted then
		return
	end
	local previous = self.angularElapsed or orbitStart
	local delta = math.max(elapsed - previous, 0)
	if delta <= 0 then
		return
	end
	-- Integrate a long initial interval only for late attachment; normal frames use one midpoint.
	local steps = math.clamp(math.ceil(delta / 0.1), 1, 2048)
	local step = delta / steps
	for i = 1, steps do
		local time = previous + (i - 0.5) * step
		local progress = window(time, total, stage.StartFraction, 1)
		local ramp = if stage.Orbit.RampTime > 0
			then math.clamp((time - orbitStart) / stage.Orbit.RampTime, 0, 1)
			else 1
		ramp = ramp * ramp * (3 - 2 * ramp)
		self.orbitAngle += math.rad(interpolate(stage.Orbit.Speed, eased(progress, stage.Orbit))) * ramp * step
	end
	self.angularElapsed = elapsed
end

function Stage2.Pose(data, age, elapsed, total)
	local alpha = eased(age / data.duration, data.settings)
	local size = data.startScale + (data.endScale - data.startScale) * alpha
	local settings = data.settings.Transparency
	local fadeIn = if settings.FadeInDuration > 0 then eased(age / settings.FadeInDuration, settings) else 1
	local fadeOut = if settings.FadeOutDuration > 0
		then eased((elapsed - (total - settings.FadeOutDuration)) / settings.FadeOutDuration, settings)
		else (if elapsed >= total then 1 else 0)
	return alpha, size, math.max(1 - fadeIn, fadeOut)
end

function Stage2.IsActive(elapsed, total)
	return Config.Stage2.Enable and elapsed >= total * Config.Stage2.StartFraction
end

function Stage2.Reset(self)
	for _, path in self.paths do
		table.clear(path.slots)
	end
	self.orbitAngle, self.angularElapsed, self.orbitStarted = 0, nil, false
end

return Stage2
