local TransitionEffects = {}
TransitionEffects.__index = TransitionEffects
local TweenService = game:GetService("TweenService")
local EffectTransition = require(script.Parent.Parent.Helper.EffectTransition)

local function fadeSequence(sequence, progress)
	local points = {}
	for _, point in sequence.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(
			point.Time, point.Value + (1 - point.Value) * progress, point.Envelope * (1 - progress)
		))
	end
	return NumberSequence.new(points)
end

function TransitionEffects.new(folder, config)
	local settings = table.clone(config)
	settings.StartFraction, settings.FullFraction = 0, 1
	-- Transition audio is heard by all local listeners, including the lobby.
	local listener = { GetAttribute = function(_, name) return name == "IsOnArena" end }
	local self = setmetatable({
		settings = settings, visuals = {}, effects = EffectTransition.new(settings, listener),
	}, TransitionEffects)
	for _, instance in folder:GetDescendants() do
		self.effects:Register(instance)
		if instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail") then
			self.visuals[instance] = { transparency = instance.Transparency }
			instance.Enabled = false
			if instance:IsA("ParticleEmitter") or instance:IsA("Trail") then instance:Clear() end
		elseif instance:IsA("Light") then
			self.visuals[instance] = { brightness = instance.Brightness }
			instance.Enabled = false
		end
	end
	return self
end

function TransitionEffects:Start()
	if self.started or self.destroyed then return end
	self.started = true
	self.effects:Update(1, 1)
	for instance in self.visuals do
		if instance.Parent then instance.Enabled = true end
	end
end

function TransitionEffects:Fade(progress)
	if not self.started or self.stopped or self.destroyed then return end
	progress = math.clamp(progress, 0, 1)
	self.effects:Update(1 - progress, 1)
	local vfx = 1 - math.clamp(TweenService:GetValue(
		1 - progress, self.settings.VFXEasingStyle, self.settings.VFXEasingDirection
	), 0, 1)
	for instance, original in self.visuals do
		if instance.Parent then
			if original.transparency then instance.Transparency = fadeSequence(original.transparency, vfx) end
			if original.brightness then instance.Brightness = original.brightness * (1 - vfx) end
			if progress >= 1 then
				instance.Enabled = false
				if instance:IsA("ParticleEmitter") or instance:IsA("Trail") then instance:Clear() end
			end
		end
	end
	if progress >= 1 then
		self.effects:Reset() -- Stop direct and referenced sounds; clear remaining particles.
		self.stopped = true
	end
end

function TransitionEffects:Destroy()
	if self.destroyed then return end
	self.destroyed = true
	self.effects:Destroy() -- Disconnect references and destroy their client sound copies.
	for instance, original in self.visuals do
		if instance.Parent then
			instance.Enabled = false
			if original.transparency then instance.Transparency = original.transparency end
			if original.brightness then instance.Brightness = original.brightness end
			if instance:IsA("ParticleEmitter") or instance:IsA("Trail") then instance:Clear() end
		end
	end
	table.clear(self.visuals)
end

return TransitionEffects
