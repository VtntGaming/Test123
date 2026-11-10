--[[
    Module made by: Maplestorm (@Maplestorm_0) | Discord: maplestorm
    Optimized by: @1Xayd1 | Discord: 1xayd1
]]

local RockModule = {}

local TweenService = game:GetService("TweenService")
local ObjectCache = require(script:WaitForChild("ObjectCache"))

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
local TweenPopupParam = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local Cache = ObjectCache.new(script.RockDebris, 100, workspace.Cache)

local function retractRock(Rock, lifetime, retractTime, position, size, Cache)
	retractTime = retractTime or 1
	local retractTween = TweenService:Create(
		Rock, 
		TweenInfo.new(retractTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), 
		{Position = position - Vector3.new(0, size, 0)}
	)
	retractTween.Completed:Once(function()
		Cache:ReturnPart(Rock)
	end)
	retractTween:Play()
end

local function createRock(result, size, position, material, color, lifetime, retractTime, Cache)
	local Rock = Cache:GetPart()
	Rock.Massless = true
	Rock.Anchored = true
	Rock.AssemblyLinearVelocity = Vector3.zero
	Rock.Position = position
	Rock.Size = Vector3.new(size, size, size)
	Rock.Smoke.Size = NumberSequence.new(size * math.random(3, 6))
	Rock.Parent = workspace.Debris
	Rock.Material = material
	Rock.Color = color
	Rock.Rotation = Vector3.new(math.random(0, 360), math.random(0, 360), math.random(0, 360))

	local Tween = TweenService:Create(
		Rock, 
		TweenPopupParam, 
		{Position = result.Position}
	)
	Tween:Play()

	if math.random() >= 0.75 then
		Rock.Smoke:Emit(1)
	end

	task.delay(
		lifetime, retractRock, Rock,
		lifetime, retractTime,
		position, size, Cache
	)
end

local function spawnRocks(amount, startSize, endSize, startCFrame, dir, distance, startDistance, raycastDirection, raycastParams, popupTime, createRock, lifetime, retractTime, Cache)
	for j = 1, amount do
		local size = startSize + (endSize - startSize) * (j / amount)
		local torigin = startCFrame + dir.LookVector * (1 + (distance - 1) * (j / amount)) + dir.LookVector * startDistance
		local result = workspace:Raycast(torigin.Position + Vector3.new(0, raycastDirection.Y / -2, 0), raycastDirection, raycastParams)

		if result then
			createRock(result, size, result.Position - Vector3.new(0, size / 2, 0), result.Material, result.Instance.Color, lifetime, retractTime, Cache)
		end

		if popupTime ~= 0 then
			task.wait(popupTime / amount)
		end
	end
end

function RockModule.new(
	origin: Vector3,
	direction: Vector3,
	raycastDirection: Vector3,
	angle: number,
	lines: number,
	distance: number,
	startSize: number,
	endSize: number,
	numRocks: number,
	lifetime: number,
	startDistance: number,
	popupTime: number,
	retractTime: number	
): ()

	local result = workspace:Raycast(origin, raycastDirection, raycastParams)

	if not result then return end

	local normal = result.Normal
	local startCFrame = CFrame.new(result.Position, result.Position + direction)
	startCFrame = startCFrame:ToWorldSpace(CFrame.Angles(0, math.rad(-angle / 2), 0))
	local RocksPerLine = numRocks / lines

	for i = 1, lines do
		local dir = lines == 1 and startCFrame or startCFrame:ToWorldSpace(CFrame.Angles(0, math.rad(angle / (lines - 1) * (i - 1)), 0))
		local amount = RocksPerLine + math.round(math.random(RocksPerLine * 3, RocksPerLine * 5) / RocksPerLine)
		
		task.spawn(
			spawnRocks, 
			amount, startSize, endSize, 
			startCFrame, dir, distance, 
			startDistance, raycastDirection, raycastParams, 
			popupTime, createRock, 
			lifetime, retractTime, 
			Cache
		)
	end
end

return RockModule