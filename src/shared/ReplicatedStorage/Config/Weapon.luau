--!strict
-- Server WeaponId chooses a base family. Cosmetic variants share that family's tuning.
-- Strength is applied to a fresh per-hit profile; these tables are never mutated.
local profiles = {}
for _, id in {"Slap", "Bat", "Hammer", "Stick", "Chicken"} do
	profiles[id] = table.freeze({
		StunDuration = 0,
		HorizontalSpeed = 40,
		LaunchHeight = 8,
		TimeToApex = 0.35,
		GroundBounceCount = 0,
		GroundBounceHeight = 0,
		GroundSpeedRetention = 0.35,
		WallBounceCount = 0,
		WallSpeedRetention = 0.15,
		SlideEnabled = true, -- False: stop at the final landing and enter Rest immediately.
		SlideDeceleration = 80,
		RestDuration = 0,
		MaxDuration = 8,
		FlyTimeout = 0.8, -- Consecutive Fly seconds before normal character recovery; zero disables.
		FlyTimeoutRequiresJump = true,
		FlyVisualOffset = Vector3.zero,
		RestVisualOffset = Vector3.new(0, 0.575, 0),
	})
end
return table.freeze(profiles)
