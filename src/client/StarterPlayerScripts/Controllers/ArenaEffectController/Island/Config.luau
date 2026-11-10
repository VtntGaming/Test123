return {
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	StartFraction = 0.15,
	FullFraction = 0.85,
	VFXEasingStyle = Enum.EasingStyle.Quad,
	VFXEasingDirection = Enum.EasingDirection.InOut,
	SFXEasingStyle = Enum.EasingStyle.Quad,
	SFXEasingDirection = Enum.EasingDirection.InOut,
	Earthquake = {
		-- Min at match start, Max at match end; no earthquakes outside Playing.
		Frequency = NumberRange.new(0.05, 0.18), -- Earthquakes/second: about every 25s → 5.6s.
		Duration = NumberRange.new(2, 7), -- Seconds per earthquake.
		Intensity = NumberRange.new(0.85, 2.5),
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.In,
		IntervalRandom = NumberRange.new(0.85, 1.15), -- Multiplies the interval; sampled between quakes.
		Camera = {
			Roughness = 15,
			FadeTime = 0.25, -- Seconds to fade in/out.
			PositionInfluence = Vector3.new(0.25, 0.2, 0.15), -- Studs at intensity 1.
			RotationInfluence = Vector3.new(1.2, 0.8, 1), -- Degrees at intensity 1.
		},
	}, 
	RocksVFX = {
		TemplatePath = { "Assets", "VFX", "Rocks VFX" }, -- Relative to ReplicatedStorage.
		SpawnRate = NumberRange.new(2.5, 5), -- Bursts/second during earthquakes, at match start/end.
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.In,
		PartsPerBurst = 3,
		MaxActive = 24,
		MaxBurstsPerFrame = 1,
		SurfaceGrid = 4, -- Visit different cells of each platform's top surface.
		SurfaceOffset = 3, -- Studs above the surface.
		Lifetime = 7
	},
	Debris = {
		PartsPath = { "Blocks" }, -- Pick visible, collidable parts inside this folder.
		TopSurfaceTolerance = 0.25, -- Studs below highest surviving top surface; applies to debris and RocksVFX.
		BurstInterval = 0.25, -- Seconds between bursts during an earthquake.
		PartsPerBurst = 5, -- Distinct platforms per burst, spread across surviving parts.
		PiecesPerPart = NumberRange.new(3, 6),
		Size = NumberRange.new(0.25, 0.8),
		Lifetime = NumberRange.new(0.6, 1.2),
		FadeTime = 0.3,
		HorizontalSpeed = NumberRange.new(3, 10),
		UpwardSpeed = NumberRange.new(30, 40),
		Gravity = 35,
		MaxActive = 64, -- Bounds the number of local debris pieces.
	},
}
