local TextEffects = require(script.Parent.Parent)

return function(uiInstance: GuiObject, speed: number, size: number, customColor: ColorSequence?, customTransparency: NumberSequence?, customStrokeColor: Color3?, customRotation: number?, importantStroke: boolean?)
	local color = customColor or ColorSequence.new(Color3.new(1, 1, 1))
	local transparency = customTransparency or NumberSequence.new(0)
	local rotation = customRotation or -90
	local mainGradient = TextEffects.Gradient.new(uiInstance, color, transparency)
	mainGradient:SetRotation(rotation, 1)
	mainGradient:SetOffsetSpeed(speed, 1)

	local mainStroke = TextEffects.Stroke.new(uiInstance, size, customStrokeColor)
	if (importantStroke) then
		
		local white = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255,255,255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255,255,255)),
		})
		local defaultStrokeGradient = TextEffects.Gradient.new(mainStroke.Instance, white, 0);
	end

	return {
		Effects = { mainGradient, mainStroke },
	}
end