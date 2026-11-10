return function()
    local Gradient = Instance.new("UIGradient");
    Gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 234, 8)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 234, 8)),
    })
	Gradient.Rotation = 90
    return Gradient;
end