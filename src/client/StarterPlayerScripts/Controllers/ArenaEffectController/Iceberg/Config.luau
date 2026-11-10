return {
	DynamicEffectsPath = { "Decorations", "dynamic_vfx" },
	StartFraction = 0.2,
	FullFraction = 0.5,
	
	VFXEasingStyle = Enum.EasingStyle.Quad,
	VFXEasingDirection = Enum.EasingDirection.InOut,
	SFXEasingStyle = Enum.EasingStyle.Quad,
	SFXEasingDirection = Enum.EasingDirection.InOut,
	
	TornadoPath = { "Decorations", "dynamic_vfx", "Tornado-01" },
	TornadoOffset = Vector3.xAxis * 350,
	TornadoTravelTime = 20,
	TornadoForce = {
		Enabled = false,
		StartFraction = 0.35, -- Start pulling at 35% of the match.
		FullFraction = 0.9, -- Reach full strength at 90% of the match.
		Value = 50, -- Pull acceleration in studs/second squared, compensated for character mass.
		EasingStyle = Enum.EasingStyle.Quad,
		EasingDirection = Enum.EasingDirection.InOut,
	},
}
