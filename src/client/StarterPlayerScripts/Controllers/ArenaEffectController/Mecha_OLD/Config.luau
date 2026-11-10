return {
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	StructuresName = "Structures",
	AuraName = "Aura",
	MiscPath = { "Misc" },
	SpawnStartName = "ObjectSpawnStart",
	SpawnEndName = "ObjectSpawnEnd",
	-- Paths place each structure's authored pivot at the markers' centers; use bottom pivots for aligned bases.
	CenterPath = { "Block", "Main", "MainPlatform" },
	ArenaTemplatePath = { "Assets", "Arenas", "Mecha" }, -- Original center fallback for late attachment.
	Stage1 = {
		Enable = true, -- False skips stage 1, including its structures, aura and sky rotation.
		StartFraction = 0,
		-- Progress ends at Stage2.StartFraction when stage 2 is enabled; otherwise it ends with the match.
		StructureCount = Vector2.new(25, 30), -- Target structures per side at stage start/end; spacing = path length / interpolated count.
		FitToStructureCount = false, -- Fit each model independently; false preserves sizes and uses wider gaps only for larger neighbors.
		SpacingPadding = 3, -- Minimum edge gap; each neighboring pair uses its own selected rotations and sampled peak sizes.
		MaxActive = 20, -- Total budget divided across sides; spacing widens if needed to respect it.
		MaxSpawnsPerFrame = 5, -- Catch-up budget; delayed spawns use their correct spaced positions.
		TravelSpeed = NumberRange.new(15, 40), -- Shared conveyor studs/second, progressing with the stage timer.
		-- Easing below controls stage 1 speed and spacing progression; structures never overtake.
		EasingStyle = Enum.EasingStyle.Linear,
		EasingDirection = Enum.EasingDirection.InOut,
		Scale = Vector2.new(0.95, 0.95), -- X: spawn size, Y: end size; template multipliers before fitting to count, zero uses 0.001.
		FinalScale = NumberRange.new(1, 1), -- Random midpoint size before fitting to count; sampled once, keep Scale.X/Y below Min.
		OrientationY = { 0 }, -- Random Y rotation in degrees, relative to the template; picked once per structure.
		OrientationMode = "FaceCenter", -- "Random": use OrientationY; "FaceCenter": face CenterPath, snapped to world Y turns of 90 degrees.
		Transparency = {
			-- Fractions of each structure's path from ObjectSpawnStart to ObjectSpawnEnd.
			FadeInEndFraction = 0.15, -- Invisible at spawn; authored transparency by 15% of the path.
			FadeOutStartFraction = 0.8, -- Begin fading out at 80%; invisible at the end.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		Floating = {
			Amplitude = NumberRange.new(0,0),--(2, 5), -- Studs above/below the path, sampled once.
			Period = NumberRange.new(3, 6), -- Seconds per full cycle, sampled once.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		Aura = {
			Enable = false, -- Per-structure aura VFX for stage 1.
			RateMultiplier = NumberRange.new(0, 1), -- Multiplies each authored emitter rate.
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
			Padding = Vector3.new(2, 2, 2), -- Added to bounding-box size in studs.
		},
		Sky = {
			StartSpeed = Vector3.new(0, 0, 0), -- SkyboxOrientation pitch/yaw/roll speed in degrees per second.
			EndSpeed = Vector3.new(15, 2, 1), -- Progresses over stage 1; rotation carries into stage 2 without resetting.
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
		},
	},
	Stage2 = {
		Enable = false, -- False keeps stage 1 running until match end; skips final structures, orbit and stage 2 sky.
		StartFraction = 0.5,
		-- Progress below is normalized from StartFraction to match end.
		StructuresPerSide = 5, -- Exactly this many final structures per valid path after the spawn wave; stage 1 is cleared.
		SpawnInterval = 0.15, -- Seconds between final structures on each side.
		SettleTime = 4, -- Seconds from start marker to assigned stopping position.
		StopRange = NumberRange.new(0.2, 0.8), -- Fractions along each path; evenly spaced.
		EasingStyle = Enum.EasingStyle.Cubic,
		EasingDirection = Enum.EasingDirection.Out,
		Scale = Vector2.new(0, 1), -- X: spawn size multiplier (zero uses 0.001); Y is unused in Stage2.
		FinalScale = NumberRange.new(0.75, 1.25), -- Random settled size, sampled once; retained while orbiting.
		OrientationY = { 0, 90, 180, 270 }, -- Independent of Stage1; degrees relative to the template.
		OrientationMode = "FaceCenter", -- "Random" or "FaceCenter"; facing updates while moving and orbiting.
		Transparency = {
			FadeInDuration = 1, -- Seconds after each structure spawns; zero makes it immediately visible.
			FadeOutDuration = 1, -- Final seconds before match/stage 2 end; zero hides instantly at end.
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		Floating = { -- Independent of Stage1, with matching defaults.
			Amplitude = NumberRange.new(0,0),--(10, 15),
			Period = NumberRange.new(3, 6),
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.InOut,
		},
		Aura = { -- One combined carrier per side, not one per structure.
			Enable = false, -- Combined side aura VFX for stage 2.
			RateMultiplier = NumberRange.new(0, 1),
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
			Padding = Vector3.new(2, 2, 2),
		},
		Orbit = {
			Speed = NumberRange.new(5, 35), -- Degrees/second around world Y.
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.In,
			RampTime = 2, -- Seconds to smoothly introduce orbit and sky rotation.
		},
		Sky = {
			StartSpeed = Vector3.new(15, 2, 1), -- Pitch/yaw/roll degrees per second.
			EndSpeed = Vector3.new(60, 10, 5),
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
		},
	},
}
