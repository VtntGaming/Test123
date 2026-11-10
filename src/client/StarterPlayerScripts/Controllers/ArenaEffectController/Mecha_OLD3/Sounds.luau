local Sounds = {}
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)

function Sounds.Capture(self, structures)
	self.sounds = {}
	for _, instance in structures:GetDescendants() do
		if instance:IsA("Sound") then
			table.insert(self.sounds, { instance = instance, volume = instance.Volume })
			instance:Stop()
			instance.Volume = 0
		end
	end
end

function Sounds.Finish(self, elapsed)
	if self.soundFinishedAt ~= nil then
		return
	end
	self.soundFinishedAt = elapsed
	for _, data in self.sounds do
		data.fadeVolume = data.instance.Volume
	end
end

function Sounds.Update(self, elapsed, total)
	local stage, settings = Config.Stage1, Config.Stage1.Sound
	local start, finish = total * stage.StartFraction, total * stage.EndFraction
	if elapsed >= finish then
		Sounds.Finish(self, finish)
	end
	for _, data in self.sounds do
		local sound = data.instance
		if not sound:IsDescendantOf(self.arena) then
			continue
		end
		if not stage.Enable or elapsed < start then
			sound:Stop()
			sound.Volume = 0
		elseif self.soundFinishedAt ~= nil then
			local progress = if settings.FadeOutDuration > 0
				then math.clamp((elapsed - self.soundFinishedAt) / settings.FadeOutDuration, 0, 1)
				else 1
			sound.Volume = data.fadeVolume * (1 - MotionMath.Eased(progress, settings))
			if progress >= 1 then
				sound:Stop()
			end
		else
			if not data.started then
				sound.Volume = 0
				sound:Play()
				data.started = true
			end
			local progress = if settings.FadeInDuration > 0 then (elapsed - start) / settings.FadeInDuration else 1
			sound.Volume = data.volume * MotionMath.Eased(progress, settings)
		end
	end
end

function Sounds.Reset(self)
	self.soundFinishedAt = nil
	for _, data in self.sounds do
		if data.instance.Parent then
			data.instance:Stop()
			data.instance.Volume = data.volume
		end
		data.started, data.fadeVolume = nil, nil
	end
end

return Sounds
