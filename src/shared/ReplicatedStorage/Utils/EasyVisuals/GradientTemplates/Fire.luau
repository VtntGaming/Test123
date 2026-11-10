return function()
	local Gradient = Instance.new("UIGradient");
	Gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 54, 14)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 234, 8)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 72, 0)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 164, 6)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 54, 14)),

	});
	return Gradient;
end