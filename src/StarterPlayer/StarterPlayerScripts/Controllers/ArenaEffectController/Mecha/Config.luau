return {
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	StructuresName = "Structures", -- Authored scenery; destroyed locally after fading.
	Portal = {
		Name = "Portal", -- Under DynamicEffectsPath; persists after Structures disappear.
		ReferenceSpeed = 100, -- Studs/second at which each emitter uses its authored Rate.
		MaxRateMultiplier = 3, -- Cap on emission rate.
		ReferenceAngularSpeed = 30, -- Degrees/second adding one authored particle-speed multiplier.
		MaxSpeedMultiplier = 3, -- Cap on the combined travel/turn particle-speed multiplier.
		MinParticleSpeed = 50, -- Absolute particle-speed floor in studs/second; zero permits speeds down to zero.
	},
	CenterPath = { "Block", "Main", "MainPlatform" },
	ArenaTemplatePath = { "Assets", "Arenas", "Mecha" }, -- Center fallback if the platform was removed.
	Stage1 = {
		Enable = true,
		StartFraction = 0.2,
		-- Simulated arena motion. The real arena stays still; scenery moves oppositely.
		-- Axes follow the simulated arena: -Z is forward, +Y is up.
		-- Velocity carries between entries. After the list, coast and keep the last angular velocity.
		Movements = {
			{
				Duration = 10, -- Seconds.
				Acceleration = Vector3.new(0, -20, -5), -- Studs/second squared, arena-local.
				AngularVelocity = Vector3.new(5,1,1), -- Local pitch/yaw/roll, degrees/second.
			},
			{
				Duration = 10,
				Acceleration = Vector3.new(0, 1, 5),
				AngularVelocity = Vector3.new(15, 3, 1),
			},
		},
		StructureFade = {
			StartAfter = 10, -- Seconds after departure begins.
			Duration = 2, -- Destroy after fading; zero destroys immediately.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
	},
}
