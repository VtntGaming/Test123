--!strict
-- Server-only shape queries for active actors; no Workspace proxy instances.
local Query = {}

local function extent(axis: Vector3, frame: CFrame, half: Vector3): number
	return math.abs(axis:Dot(frame.RightVector)) * half.X
		+ math.abs(axis:Dot(frame.UpVector)) * half.Y
		+ math.abs(axis:Dot(frame.LookVector)) * half.Z
end

function Query.BoxesOverlap(a: CFrame, aSize: Vector3, b: CFrame, bSize: Vector3): boolean
	local aHalf, bHalf = aSize * 0.5, bSize * 0.5
	local delta = b.Position - a.Position
	-- Cheap circumscribed-sphere rejection before the 15 separating axes.
	if delta.Magnitude > aHalf.Magnitude + bHalf.Magnitude then
		return false
	end
	local aAxes = { a.RightVector, a.UpVector, a.LookVector }
	local bAxes = { b.RightVector, b.UpVector, b.LookVector }
	local function separated(axis: Vector3): boolean
		-- Cross products need not be normalized; skip nearly parallel axes.
		if axis:Dot(axis) < 1e-12 then
			return false
		end
		return math.abs(delta:Dot(axis)) > extent(axis, a, aHalf) + extent(axis, b, bHalf) + 1e-6
	end
	for _, axis in aAxes do
		if separated(axis) then
			return false
		end
	end
	for _, axis in bAxes do
		if separated(axis) then
			return false
		end
	end
	for _, aAxis in aAxes do
		for _, bAxis in bAxes do
			if separated(aAxis:Cross(bAxis)) then
				return false
			end
		end
	end
	return true
end

function Query.ClosestBoxPoint(frame: CFrame, size: Vector3, from: Vector3): Vector3
	local point, half = frame:PointToObjectSpace(from), size * 0.5
	return frame:PointToWorldSpace(Vector3.new(
		math.clamp(point.X, -half.X, half.X),
		math.clamp(point.Y, -half.Y, half.Y),
		math.clamp(point.Z, -half.Z, half.Z)
	))
end

function Query.ClosestSpherePoint(center: Vector3, radius: number, from: Vector3): Vector3
	local delta = from - center
	if delta.Magnitude <= radius then
		return from
	end
	return center + delta.Unit * radius
end

return Query
