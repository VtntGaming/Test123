return {
	ReturnToNormal = true, -- Smoothly restore authored structure and sky orientations when the match ends.
	ReturnDuration = 2, -- Seconds for the return transition; zero restores immediately.
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	StructuresName = "Structures", -- Authored models stay in place; nothing is cloned or spawned.
	CenterPath = { "Block", "Main", "MainPlatform" }, -- Structure formation rotates around this center.
	ArenaTemplatePath = { "Assets", "Arenas", "Mecha" }, -- Center fallback if the active platform was removed.
	Stage1 = {
		Enable = true, -- False keeps the sky and structures in their authored poses.
		StartFraction = 0.5, -- Nothing moves during the first half of the match.
		EndFraction = 1,
		Sound = {
			FadeInDuration = 2, -- Fade from silence to each Sound's authored Volume at stage start.
			FadeOutDuration = 2, -- Fade to silence when the stage or match ends, then stop.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		OrbitAroundCenter = false, -- False rotates each captured structure model at its authored pivot without orbiting CenterPath.
		Sky = {
			StartSpeed = Vector3.new(15, 2, 1), -- SkyboxOrientation pitch/yaw/roll degrees per second.
			EndSpeed = Vector3.new(60, 10, 5),
			RampTime = 2, -- Seconds to ease into rotation from rest; zero starts immediately.
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		-- The sky drives structure orientation and, when OrbitAroundCenter is enabled, position.
		Transparency = {
			FadeOutDuration = 5, -- Final seconds of this stage; invisible at EndFraction. Zero hides at end.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
	},
}
