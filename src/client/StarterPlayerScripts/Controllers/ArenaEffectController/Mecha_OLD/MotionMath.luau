local MotionMath = {}
local TweenService = game:GetService("TweenService")

local function eased(progress, settings, prefix)
	prefix = prefix or ""
	return math.clamp(
		TweenService:GetValue(
			math.clamp(progress, 0, 1),
			settings[prefix .. "EasingStyle"],
			settings[prefix .. "EasingDirection"]
		),
		0,
		1
	)
end

local function interpolate(range, alpha)
	return range.Min + (range.Max - range.Min) * alpha
end

local function window(elapsed, total, startFraction, endFraction)
	return math.clamp((elapsed / total - startFraction) / (endFraction - startFraction), 0, 1)
end

MotionMath.Eased = eased
MotionMath.Interpolate = interpolate
MotionMath.Window = window
return MotionMath
