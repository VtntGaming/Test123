return {
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	MiscPath = { "Misc" },
	LobbyHiddenPath = { "Decorations", "static", "LobbyHidden" },
	FinalLightingPath = { "Decorations", "final" },
	FinalTransitionPath = { "Decorations", "final_transition" },
	DefaultLightingPath = { "Assets", "Arenas", "Moon" }, -- Relative to ReplicatedStorage.
	StartFraction = 0,
	FullFraction = 0.6,
	VFXEasingStyle = Enum.EasingStyle.Quad,
	VFXEasingDirection = Enum.EasingDirection.InOut,
	SFXEasingStyle = Enum.EasingStyle.Quad,
	SFXEasingDirection = Enum.EasingDirection.InOut,
	Blackhole = {
		Name = "Blackhole",
		StopName = "BlackholeStop",
		EasingStyle = Enum.EasingStyle.Linear,
		EasingDirection = Enum.EasingDirection.InOut,
		Scale = NumberRange.new(0.1, 12),

		Transition = {
			Delay = 0,
			Time = 2,
			SkyboxChangeFraction = 0.35, -- Switch to Final lighting at 50% of Time, after Delay.
			ScaleFinal = 200,
			EasingStyle = Enum.EasingStyle.Exponential,
			EasingDirection = Enum.EasingDirection.InOut,
			FadeTime = 0.5, -- Fade particles and geometry, then destroy the Blackhole.
			EffectsFadeTime = 1.5, -- Fade final_transition VFX/audio after expansion completes.
		},

		Force = {
			StartFraction = 0.35,
			FullFraction = 0.9,
			Value = 150, -- Pull acceleration in studs/second squared; compensated for assembly mass.
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.InOut,
		},
	},
	VFXs = {
		Name = "VFXs",
		-- Each range is one endpoint's speed at zero/full VFX intensity.
		-- Initially Speed = [50, 150]; at full intensity Speed = [150, 450].
		ParticleSpeed = { Minimum = NumberRange.new(50, 70), Maximum = NumberRange.new(250, 300) },
	},
	Portal = {
		Name = "Portal",
		MinTimeScale = 1, -- Fades to 1 using the VFX easing settings.
		MinimumEmitRate = 35, -- Particles per second before the fade starts.
	},
	Objects = {
		SpawnName = "ObjectSpawn", -- Collects both parts with this name.
		DestroyName = "ObjectSpawnDestroy",
		MaxSpawnsPerFrame = 2, -- Per group; prevents a burst after a long frame.
		-- Templates move to this handler's folder in ReplicatedStorage.Runtime.
		-- Clones travel in world Z only, then return to bounded template pools.
		-- TravelSpeed ranges are studs/second at zero/full arena progression.
		-- SpawnRate ranges are spawns/second at match start/end, with separate easing.
		-- SpawnRateRandom multiplies that rate; sampled once per spawn interval.
		Groups = {
			{
				Name = "Galaxies",
				SpawnRate = NumberRange.new(0.25, 0.75),
				SpawnRateEasingStyle = Enum.EasingStyle.Quad,
				SpawnRateEasingDirection = Enum.EasingDirection.InOut,
				SpawnRateRandom = NumberRange.new(0.8, 1.2),
				TravelSpeed = NumberRange.new(30, 250),
				MaxActive = 6,
				EasingStyle = Enum.EasingStyle.Quad,
				EasingDirection = Enum.EasingDirection.InOut,
			},
			{
				Name = "Meteors",
				FadeOut = {
					StartFraction = 0.85, -- Start fading at 85% of the trip to ObjectSpawnDestroy; invisible at the endpoint.
					EasingStyle = Enum.EasingStyle.Quad,
					EasingDirection = Enum.EasingDirection.InOut,
				},
				Scale = NumberRange.new(0, 2), -- Start/fallback end multiplier; zero uses 0.001.
				FinalScale = NumberRange.new(0.5, 3), -- Random end multiplier, sampled once per meteor.
				SpawnRate = NumberRange.new(0.55, 2.5),
				SpawnRateEasingStyle = Enum.EasingStyle.Quad,
				SpawnRateEasingDirection = Enum.EasingDirection.In,
				SpawnRateRandom = NumberRange.new(0.8, 1.2),
				TravelSpeed = NumberRange.new(200, 1000),
				MaxActive = 25,
				EasingStyle = Enum.EasingStyle.Quad,
				EasingDirection = Enum.EasingDirection.In,
			},
			{
				Name = "Sparkles",
				SpawnRate = NumberRange.new(0.5, 3),
				SpawnRateEasingStyle = Enum.EasingStyle.Quad,
				SpawnRateEasingDirection = Enum.EasingDirection.InOut,
				SpawnRateRandom = NumberRange.new(0.8, 1.2),
				TravelSpeed = NumberRange.new(200, 400),
				MaxActive = 12,
				EasingStyle = Enum.EasingStyle.Quad,
				EasingDirection = Enum.EasingDirection.InOut,
			},
		},
	},
}
