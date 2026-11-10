--!strict
-- Cartoon presentation only. Physics profiles in Config.Weapon are still required.
local config = {
    CorrectionStartDistance = 0.5,
    CorrectionStopDistance = 0.02,
    CorrectionSmoothTime = 0.07,
    CorrectionSnapDistance = 12,
	-- Animation transition durations in seconds. Read before starting a session.
	NormalToFlyFadeTime = 0.2,
	FlyFadeTime = 0,
	RestFadeTime = 0,
	RestToNormalFadeTime = 0.15,
	BounceFadeTime = 0.05,
	BounceToFlyFadeTime = 0.05,

	-- Opt-in Cartoon cosmetics: each client keeps its own per-impact reaction.
	-- Change before starting a new session; false uses the tracked physical contact category.
	LocalReactionPrediction = true,
	-- Cartoon Bounce rotation: false = lock the body horizontal, turning on world Y only;
	-- true = follow velocity on all axes, like Fly. Change before starting a session.
	BounceFollowVelocity = false,
	-- true = play Bounce once and hold its last frame until another reaction replaces it;
	-- false = play Bounce once, then return to Fly while airborne.
	FreezeBounceAtLastFrame = true,
	UseGlobalAnimations = true,
	GlobalSet = "Global",
	WeaponSets = table.freeze({ Bat = "Bat" }),
}

for _, name in
	{
		"NormalToFlyFadeTime",
		"FlyFadeTime",
		"RestFadeTime",
		"RestToNormalFadeTime",
		"BounceFadeTime",
		"BounceToFlyFadeTime",
	}
do
	local value = config[name]
	assert(
		type(value) == "number" and value == value and value >= 0 and value < math.huge,
		"Config.Animation." .. name .. " must be finite and nonnegative"
	)
end

return table.freeze(config)
