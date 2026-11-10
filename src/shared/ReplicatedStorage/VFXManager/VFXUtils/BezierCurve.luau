local module = {}

-- made by yurid cuto

local function lerp(t, a, b)
	return a + (b - a) * t
end

local function Quad(t, p0, p1, p2)
	local l1 = lerp(t, p0, p1)
	local l2 = lerp(t, p1, p2)
	local quad = lerp(t, l1, l2)
	return quad
end

local RunService = game:GetService("RunService")

module.Quadratic = function(obj, p1, p2, p3, o1, o2, o3, timelength)
	if not (p1 and p2 and p3) then return end

	task.spawn(function()
		local start = tick()
		while tick() - start < timelength do
			local t = (tick() - start) / timelength
			if t > 1 then t = 1 end

			local quad = Quad(t, p1, p2, p3)
			local ori = Quad(t, o1, o2, o3)

			obj.CFrame = CFrame.new(quad) * CFrame.Angles(
				math.rad(ori.X),
				math.rad(ori.Y),
				math.rad(ori.Z)
			)

			RunService.Heartbeat:Wait()
		end

		obj:SetAttribute("BezierFinished", true)
	end)
end
return module
