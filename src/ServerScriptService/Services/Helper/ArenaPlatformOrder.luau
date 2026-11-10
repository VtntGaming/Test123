local ArenaPlatformOrder = {}

-- Resolve the supporting platform before warning animations or drops move it.
function ArenaPlatformOrder.SpawnLast(arena: Model, platforms: { Model }): ({ Model }, Model?)
	local spawn = arena:FindFirstChild("Spawn")
	if not spawn or not spawn:IsA("BasePart") or #platforms == 0 then
		return platforms, nil
	end

	local candidates: { [Instance]: boolean } = {}
	local lowestY = spawn.Position.Y
	for _, platform in platforms do
		candidates[platform] = true
		local pivot, size = platform:GetBoundingBox()
		-- The bounding sphere also covers rotated platform geometry.
		lowestY = math.min(lowestY, pivot.Position.Y - size.Magnitude * 0.5)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = platforms
	params.RespectCanCollide = true
	local origin = spawn.Position + Vector3.yAxis * (spawn.Size.Magnitude * 0.5 + 1)
	local hit = workspace:Raycast(origin, -Vector3.yAxis * (origin.Y - lowestY + 1), params)
	if not hit then
		return platforms, nil
	end

	local supporting: Instance? = hit.Instance
	while supporting and not candidates[supporting] do
		supporting = supporting.Parent
	end
	if not supporting then
		return platforms, nil
	end

	local spawnPlatform = supporting :: Model
	local ordered = {}
	for _, platform in platforms do
		if platform ~= spawnPlatform then
			table.insert(ordered, platform)
		end
	end
	table.insert(ordered, spawnPlatform)
	return ordered, spawnPlatform
end

return ArenaPlatformOrder
