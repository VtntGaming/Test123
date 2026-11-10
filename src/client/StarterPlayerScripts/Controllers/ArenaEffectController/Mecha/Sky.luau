local Sky = {}
local Lighting = game:GetService("Lighting")

function Sky.Restore(self)
	if self.sky and self.sky.Parent == Lighting then
		self.sky.SkyboxOrientation = self.skyOriginal
	end
	self.sky, self.skyOriginal = nil, nil
end

function Sky.Update(self, relativeRotation)
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky ~= self.sky then
		Sky.Restore(self)
		self.sky, self.skyOriginal = sky, sky and sky.SkyboxOrientation
	end
	if sky then
		local original = self.skyOriginal
		-- SkyboxOrientation applies extrinsic Y-X-Z rotations, matching CFrame's Z-X-Y order.
		local authored = CFrame.fromEulerAngles(
			math.rad(original.X), math.rad(original.Y), math.rad(original.Z), Enum.RotationOrder.ZXY
		)
		local x, y, z = (relativeRotation * authored):ToEulerAngles(Enum.RotationOrder.ZXY)
		sky.SkyboxOrientation = if relativeRotation == CFrame.identity
			then original
			else Vector3.new(math.deg(x), math.deg(y), math.deg(z))
	end
end

return Sky
