-- Authored formation follows the sky's relative rotation and fades out at stage end.
local Stage1 = {}
local Config = require(script.Parent.Config)
local MotionMath = require(script.Parent.MotionMath)

function Stage1.IsActive(elapsed, total)
	return Config.Stage1.Enable and elapsed >= total * Config.Stage1.StartFraction
end

function Stage1.Fade(elapsed, total)
	if not Stage1.IsActive(elapsed, total) then
		return 0
	end
	local settings = Config.Stage1.Transparency
	local finish = total * Config.Stage1.EndFraction
	local duration =
		math.min(settings.FadeOutDuration, total * (Config.Stage1.EndFraction - Config.Stage1.StartFraction))
	return if duration > 0
		then MotionMath.Eased((elapsed - finish + duration) / duration, settings)
		else (if elapsed >= finish then 1 else 0)
end

local function fadeSequence(original, alpha)
	local points = {}
	for _, point in original.Keypoints do
		table.insert(
			points,
			NumberSequenceKeypoint.new(
				point.Time,
				point.Value + (1 - point.Value) * alpha,
				point.Envelope * (1 - alpha)
			)
		)
	end
	return NumberSequence.new(points)
end

function Stage1.ApplyFade(visual, alpha)
	local object = visual.instance
	if object.Parent == nil then
		return
	end
	if visual.transparency ~= nil then
		local original = visual.transparency
		object.Transparency = if typeof(original) == "NumberSequence"
			then fadeSequence(original, alpha)
			else original + (1 - original) * alpha
	elseif visual.brightness ~= nil then
		object.Brightness = visual.brightness * (1 - alpha)
	end
	if visual.enabled ~= nil then
		object.Enabled = visual.enabled and alpha < 1
	end
	if alpha == 1 and (object:IsA("ParticleEmitter") or object:IsA("Trail")) then
		object:Clear()
	end
end

return Stage1
