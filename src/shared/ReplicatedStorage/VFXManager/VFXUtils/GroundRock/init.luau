local module = {}

local create = require(script.RockCreate)

module.Circle = function(Preset, RockMultiple, Scale, TimeLength, Ignore, Origin, castdis, Parent)
	if Preset == "Normal" then
		create.Circle(Ignore,Origin,14*RockMultiple,8*Scale,1,Vector3.new(0,1,0),2,TimeLength,360,1.5*Scale,5*Scale,1.8-(Scale/10), castdis, Parent)
		create.Circle(Ignore,Origin,14*RockMultiple,10*Scale,1,Vector3.new(0,0,0),2,TimeLength,360,1.25*Scale,6*Scale,1.1-(Scale/10), castdis, Parent)
	elseif Preset == "Vertical" then
		create.Circle(Ignore,Origin,4*RockMultiple,8*Scale,1,Vector3.new(0,math.random(6,12),0)*(Scale/1.5),1.2,TimeLength,0,1.5*Scale,5*Scale,1.8-(Scale/10), castdis, Parent)
		create.Circle(Ignore,Origin,8*RockMultiple,10*Scale,1,Vector3.new(0,math.random(0,2),0)*(Scale/1.5),1.05,TimeLength,0,1.25*Scale,6*Scale,1.1-(Scale/10), castdis, Parent)
	elseif Preset == "Flat" then
		create.Circle(Ignore,Origin,6*RockMultiple,8*Scale,1,Vector3.new(0,math.random(-2,0),0)*(Scale/1.5),2,TimeLength,35,1.5*Scale,5*Scale,1.8-(Scale/10), castdis, Parent)
		create.Circle(Ignore,Origin,12*RockMultiple,10*Scale,1,Vector3.new(0,math.random(-2,0),0)*(Scale/1.5),1.5,TimeLength,35,1.25*Scale,6*Scale,1.1-(Scale/10), castdis, Parent)
	elseif Preset == "Small" then
		create.Circle(Ignore,Origin,4*RockMultiple,3*Scale,1,Vector3.new(0,0,0)*(Scale/1.5),1.46,TimeLength,360,1.5*Scale,2*Scale,1.65-(Scale/10), castdis, Parent)
		create.Circle(Ignore,Origin,6*RockMultiple,5*Scale,1,Vector3.new(0,math.random(-1,0),0)*(Scale/1.5),1.35,TimeLength,360,1.25*Scale,3*Scale,1.1-(Scale/10), castdis, Parent)
	elseif Preset == "Square" then
		create.Circle(Ignore,Origin,14*RockMultiple,8*Scale,1,Vector3.new(0,1,math.random(-4,-2)),1,TimeLength,360,1.5*Scale,5*Scale,1.8-(Scale/10), castdis, Parent)
		create.Circle(Ignore,Origin,14*RockMultiple,10*Scale,1,Vector3.new(0,0,math.random(-4,-2)),1,TimeLength,360,1.25*Scale,6*Scale,1.1-(Scale/10), castdis, Parent)	
	end
end

-- Fixed parameter order: Ignore comes FIRST to match create.Circle(Ignore, Origin, ...)
module.Line = function(Ignore, Origin, Direction, Length, RockCount, Preset, Scale, TimeLength, CastDis, Parent)
	local stepDistance = (Length or 24) / (RockCount or 6)
	local flatDirection = Vector3.new(Direction.X, 0, Direction.Z).Unit
	local rightVector = flatDirection:Cross(Vector3.yAxis)
	if rightVector.Magnitude > 0.01 then
		rightVector = rightVector.Unit
	else
		rightVector = Vector3.xAxis
	end

	task.spawn(function()
		for i = 1, (RockCount or 6) do
			local currentPos = Origin + (flatDirection * (i * stepDistance))

			-- Fire small ground rock burst on left and right sides along the path
			local leftPos = currentPos + (rightVector * (1.5 * (Scale or 1)))
			local rightPos = currentPos - (rightVector * (1.5 * (Scale or 1)))

			create.Circle(Ignore, leftPos, 2, 4 * (Scale or 1), 1, Vector3.new(0, 1, 0), 1.5, TimeLength or 2, 45, 1.2 * (Scale or 1), 4 * (Scale or 1), 1.5, CastDis or 15, Parent or workspace)
			create.Circle(Ignore, rightPos, 2, 4 * (Scale or 1), 1, Vector3.new(0, 1, 0), 1.5, TimeLength or 2, 45, 1.2 * (Scale or 1), 4 * (Scale or 1), 1.5, CastDis or 15, Parent or workspace)

			task.wait(0.03) -- Step delay for progressive rushing effect
		end
	end)
end

return module
