-- GroundRock Circle
-- by YuriD😼💗

local module = {}
local TweenM = require(script.Parent.Parent.TweenM)

local function RaycastDown(origin, castdis, ignoreList)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = ignoreList
	params.FilterType = Enum.RaycastFilterType.Blacklist

	local ray = workspace:Raycast(origin, Vector3.new(0, -castdis, 0), params)
	if ray then
		return ray.Instance, ray.Position
	end
	return nil, nil
end

local function SpawnRock(cframe, lean, sizeData, distanceData, params)
	local Part = Instance.new("Part")
	Part.Anchored = true
	Part.CanCollide = false
	Part.CFrame = cframe * CFrame.Angles(0, 0, math.rad(lean))
	Part.Size = Vector3.zero
	Part.Parent = params.Parent

	local ignoreList = {params.Parent, params.Ignore}
	local castdis = params.castdis or 12

	local hitPart, pos = RaycastDown(Part.Position + Vector3.new(0,2.5,0), castdis, ignoreList)
	if hitPart then
		Part.Position = pos
		Part.Color = hitPart.Color
		Part.Material = hitPart.Material

		task.spawn(function()
			local scaleVec = Vector3.new(params.SizeRock, params.SizeRock, params.SizeRock) + params.VTRockSize +
				Vector3.new(0, 0, params.SideSizeRock + params.SizeRock + math.random(0, params.SideSizeRock))
			local tweenPack = TweenM.new({
				{ins = Part, twinfo = TweenInfo.new(0.1), prop = {Size = scaleVec}}
			})
			tweenPack:Play(true)

			task.delay(params.TimeRemove, function()
				local tweenOut = TweenM.new({
					{ins = Part, twinfo = TweenInfo.new(1), prop = {Position = Part.Position - Vector3.new(0, params.SizeRock,0), Transparency = 1, Size = Vector3.zero}}
				})
				tweenOut:Play(true)
				task.wait(1)
				Part:Destroy()
			end)
		end)
	else
		game.Debris:AddItem(Part, 0)
	end
end

local function CalculateRockParams(sizeData, distanceData, randomSize, randomDist, bigWhenFar)
	local SizeRock = sizeData + math.random(-randomSize, randomSize)
	local Distance = distanceData + math.random(-randomDist, randomDist)

	if Distance <= SizeRock then
		Distance += SizeRock * 2
	end
	if Distance / 10 >= 1 then
		if bigWhenFar <= 0.25 then bigWhenFar = 0.25 end
		SizeRock = SizeRock + (Distance / 10 * bigWhenFar)
	end

	return SizeRock, Distance
end

module.Circle = function(Ignore, Origin, NumRock, Distance, SizeRock, VTRockSize, SideSizeRock, TimeRemove, Lean, RandomSize, RandomDistance, BigWhenFar, castdis, Parent)
	local sizeData = SizeRock
	local distanceData = Distance

	for i = 1, NumRock do
		local lean = math.random(-Lean, Lean)
		local angle = math.rad(math.random(0, 360))
		local offset = CFrame.new(-Distance,0,0)
		local originCFrame: CFrame
		
		if typeof(Origin) == "Instance" and Origin:IsA("BasePart") then
			originCFrame = Origin.CFrame
		elseif typeof(Origin) == "Vector3" then
			originCFrame = CFrame.new(Origin)
		elseif typeof(Origin) == "CFrame" then
			originCFrame = Origin
		end
		
		SpawnRock(originCFrame * CFrame.Angles(0, angle, 0) * offset, lean, sizeData, distanceData, {
			Ignore = Ignore,
			Parent = Parent,
			SizeRock = SizeRock,
			VTRockSize = VTRockSize,
			SideSizeRock = SideSizeRock,
			TimeRemove = TimeRemove,
			castdis = castdis
		})

		SizeRock, Distance = CalculateRockParams(sizeData, distanceData, RandomSize, RandomDistance, BigWhenFar)
	end
end

return module
