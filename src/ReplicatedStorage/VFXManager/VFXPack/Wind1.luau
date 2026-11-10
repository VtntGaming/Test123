local VFXM = require(script.Parent.Parent.VFXUtils)

-- config = {Pos, Scale1, Scale2, Speed}
local module = function(config)
	local wind = script.Wind:Clone()
	wind.Parent = workspace.visual
	wind.Position = config.Pos
	wind.Orientation = Vector3.new(0, math.random(-360,360), 90)
	wind.Mesh.Scale = config.Scale1

	local twp1 = {
		{ins = wind.Mesh, twinfo = TweenInfo.new(.15/config.Speed, Enum.EasingStyle.Quad), 
			prop = {Scale = config.Scale2}, times = 0},
		{ins = wind.Decal, twinfo = TweenInfo.new(.15/config.Speed, Enum.EasingStyle.Quad), 
			prop = {Transparency = 1}, times = 0},
	}

	local pp = VFXM.TweenM.new(twp1)
	pp:Play(true)

	VFXM.Misc.Debris(wind, 1/config.Speed)
end

return module
