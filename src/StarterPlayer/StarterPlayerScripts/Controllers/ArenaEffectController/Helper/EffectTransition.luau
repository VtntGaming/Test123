local EffectTransition = {}
EffectTransition.__index = EffectTransition
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local function validate(settings)
	assert(type(settings) == "table", "Arena effect Config must be a table")
	assert(
		type(settings.StartFraction) == "number"
			and type(settings.FullFraction) == "number"
			and settings.StartFraction >= 0
			and settings.StartFraction < settings.FullFraction
			and settings.FullFraction <= 1,
		"Arena effect Config requires 0 <= StartFraction < FullFraction <= 1"
	)
	for _, prefix in { "VFX", "SFX" } do
		local style, direction = settings[prefix .. "EasingStyle"], settings[prefix .. "EasingDirection"]
		assert(
			typeof(style) == "EnumItem" and style.EnumType == Enum.EasingStyle,
			"Arena effect Config." .. prefix .. "EasingStyle must be an Enum.EasingStyle"
		)
		assert(
			typeof(direction) == "EnumItem" and direction.EnumType == Enum.EasingDirection,
			"Arena effect Config." .. prefix .. "EasingDirection must be an Enum.EasingDirection"
		)
	end
end

function EffectTransition.new(settings, player)
	validate(settings)
	return setmetatable({
		settings = table.clone(settings),
		player = player,
		effects = {},
		references = {},
		referencedSounds = {},
		lifetimes = {},
		vfxIntensity = 0,
		sfxIntensity = 0,
		active = false,
	}, EffectTransition)
end

function EffectTransition:_applySound(sound, data, active)
	local changed = data.active ~= active
	data.active = active
	sound.Volume = if active then data.maximum * self.sfxIntensity else 0
	if changed then
		if active then
			sound:Play()
		else
			sound:Stop()
		end
	end
end

function EffectTransition:RefreshPlayer()
	if self.destroyed then
		return
	end
	local active = self.active and self.player:GetAttribute("IsOnArena") == true
	for _, data in self.referencedSounds do
		self:_applySound(data.sound, data, active)
	end
end

function EffectTransition:_applyEffect(effect, data)
	if effect:IsA("Sound") then
		self:_applySound(effect, data, self.active)
		return
	end
	local active = (self.active or data.minimumRate > 0) and not data.suppressed
	local changed = data.active ~= active
	data.active = active
	effect.Rate = data.minimumRate + (math.max(data.maximum, data.minimumRate) - data.minimumRate) * self.vfxIntensity
	if data.minTimeScale ~= nil then
		effect.TimeScale = data.minTimeScale + (1 - data.minTimeScale) * self.vfxIntensity
	end
	if data.speedTransition then
		local speed = data.speedTransition
		local minimum = speed.Minimum.Min + (speed.Minimum.Max - speed.Minimum.Min) * self.vfxIntensity
		local maximum = speed.Maximum.Min + (speed.Maximum.Max - speed.Maximum.Min) * self.vfxIntensity
		effect.Speed = NumberRange.new(minimum, maximum)
	end
	effect.Enabled = active
	if changed and not active then
		effect:Clear()
	end
end

-- Visibility gating keeps transitions current, so restoring a particle emitter
-- immediately reapplies its current rate, speed, and TimeScale.
function EffectTransition:SetParticleEnabled(instance, enabled)
	if self.destroyed or not instance:IsA("ParticleEmitter") then
		return
	end
	local data = self.effects[instance]
	if not data or data.suppressed == not enabled then
		return
	end
	data.suppressed = not enabled
	self:_applyEffect(instance, data)
end

function EffectTransition:_setIntensity(vfx, sfx, active)
	if self.vfxIntensity == vfx and self.sfxIntensity == sfx and self.active == active then
		return
	end
	self.vfxIntensity, self.sfxIntensity, self.active = vfx, sfx, active
	for effect, data in self.effects do
		self:_applyEffect(effect, data)
	end
	self:RefreshPlayer()
end

function EffectTransition:_releaseTarget(object)
	local reference = self.references[object]
	local target = reference and reference.target
	if not target then
		return
	end
	reference.target = nil
	local data = self.referencedSounds[target]
	if not data then
		return
	end
	data.objects[object] = nil
	if next(data.objects) then
		return
	end
	self.referencedSounds[target] = nil
	data.destroying:Disconnect()
	data.sound:Stop()
	data.sound:Destroy()
end

function EffectTransition:_refreshReference(object)
	if self.destroyed then
		return
	end
	local reference = self.references[object]
	if not reference then
		return
	end
	local target = object.Value
	if target == reference.target then
		return
	end
	self:_releaseTarget(object)
	if not target or not target:IsA("Sound") then
		return
	end
	local data = self.referencedSounds[target]
	if not data then
		-- One non-positional client copy per source, shared by all references.
		local sound = target:Clone()
		if not sound then
			return
		end
		sound.PlayOnRemove = false
		sound:Stop()
		sound.Volume = 0
		sound.Parent = SoundService
		data = { sound = sound, maximum = target.Volume, active = nil, objects = {} }
		self.referencedSounds[target] = data
		data.destroying = target.Destroying:Connect(function()
			self.referencedSounds[target] = nil
			for linkedObject in data.objects do
				local linkedReference = self.references[linkedObject]
				if linkedReference then
					linkedReference.target = nil
				end
			end
			data.destroying:Disconnect()
			sound:Stop()
			sound:Destroy()
		end)
	end
	reference.target = target
	data.objects[object] = true
	self:_applySound(data.sound, data, self.active and self.player:GetAttribute("IsOnArena") == true)
end

-- Optional speed ranges animate the lower and upper Speed endpoints independently.
-- Each NumberRange stores that endpoint's value at zero and full VFX intensity.
function EffectTransition:Register(instance, speedTransition, minimumRate, minTimeScale)
	if self.destroyed or self.effects[instance] or self.references[instance] then
		return
	end
	if instance:IsA("ObjectValue") then
		self.references[instance] = {
			connection = instance:GetPropertyChangedSignal("Value"):Connect(function()
				self:_refreshReference(instance)
			end),
		}
		self:_refreshReference(instance)
	elseif instance:IsA("ParticleEmitter") or instance:IsA("Sound") then
		local data = { maximum = if instance:IsA("ParticleEmitter") then instance.Rate else instance.Volume }
		if instance:IsA("ParticleEmitter") then
			data.minimumRate = minimumRate or 0
			assert(
				type(data.minimumRate) == "number" and data.minimumRate >= 0 and data.minimumRate < math.huge,
				"Particle minimum emit rate must be finite and nonnegative"
			)
			if minTimeScale ~= nil then
				assert(
					type(minTimeScale) == "number" and minTimeScale >= 0 and minTimeScale <= 1,
					"Particle MinTimeScale must be between 0 and 1"
				)
				data.minTimeScale = minTimeScale
				data.originalTimeScale = instance.TimeScale
			end
		end
		if instance:IsA("ParticleEmitter") and speedTransition then
			assert(
				typeof(speedTransition.Minimum) == "NumberRange" and typeof(speedTransition.Maximum) == "NumberRange",
				"Particle speed transition requires Minimum and Maximum NumberRanges"
			)
			assert(
				speedTransition.Minimum.Min >= 0
					and speedTransition.Minimum.Min <= speedTransition.Maximum.Min
					and speedTransition.Minimum.Max <= speedTransition.Maximum.Max,
				"Particle speed minimum must stay below maximum and be nonnegative"
			)
			data.originalSpeed = instance.Speed
			data.speedTransition = table.clone(speedTransition)
		end
		self.effects[instance] = data
		self:_applyEffect(instance, data)
	end
	if self.effects[instance] or self.references[instance] then
		self.lifetimes[instance] = instance.Destroying:Connect(function()
			self:Unregister(instance)
		end)
	end
end

function EffectTransition:Unregister(instance)
	local lifetime = self.lifetimes[instance]
	if lifetime then
		lifetime:Disconnect()
		self.lifetimes[instance] = nil
	end
	local reference = self.references[instance]
	if reference then
		self:_releaseTarget(instance)
		reference.connection:Disconnect()
		self.references[instance] = nil
	end
	local data = self.effects[instance]
	if not data then
		return
	end
	self.effects[instance] = nil
	if instance:IsA("ParticleEmitter") then
		instance.Enabled = false
		instance:Clear()
		instance.Rate = data.maximum
		if data.originalTimeScale ~= nil then
			instance.TimeScale = data.originalTimeScale
		end
		if data.originalSpeed then
			instance.Speed = data.originalSpeed
		end
	else
		instance:Stop()
		instance.Volume = data.maximum
	end
end

function EffectTransition:Update(elapsed, total)
	if self.destroyed then
		return
	end
	if elapsed == nil then
		self:Reset()
		return
	end
	local config = self.settings
	local fraction = math.clamp(elapsed / total, 0, 1)
	if fraction < config.StartFraction then
		self:_setIntensity(0, 0, false)
	elseif fraction >= config.FullFraction then
		self:_setIntensity(1, 1, true)
	else
		local alpha = (fraction - config.StartFraction) / (config.FullFraction - config.StartFraction)
		local vfx = math.clamp(TweenService:GetValue(alpha, config.VFXEasingStyle, config.VFXEasingDirection), 0, 1)
		local sfx = math.clamp(TweenService:GetValue(alpha, config.SFXEasingStyle, config.SFXEasingDirection), 0, 1)
		self:_setIntensity(vfx, sfx, true)
	end
end

function EffectTransition:Reset()
	if not self.destroyed then
		self:_setIntensity(0, 0, false)
	end
end

function EffectTransition:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for object in self.references do
		self:Unregister(object)
	end
	for effect in self.effects do
		self:Unregister(effect)
	end
	self.player = nil
end

return EffectTransition
