return function()
	local Gradient = Instance.new("UIGradient");
	Gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(56, 180, 73)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(101, 214, 102)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(34, 255, 0)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(101, 214, 102)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(56, 180, 73)),

	});
	return Gradient;
end