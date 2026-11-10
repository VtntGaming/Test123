local TextEffects = require(script.Parent.Parent);

return function(uiInstance: GuiObject, speed: number)
    local mainGradient = TextEffects.Gradient.new(uiInstance, TextEffects.Templates.OG.Color, TextEffects.Templates.OG.Transparency);
    mainGradient:SetOffsetSpeed(speed, 1);
	mainGradient:SetTransparencyOffsetSpeed(speed, 1);
	mainGradient:SetRotation(90, 1)
    return {
        Effects = { mainGradient }
    };
end