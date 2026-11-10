local DestructionEffect = {}

local TweenService = game:GetService("TweenService")

function DestructionEffect.Play(cframe, size, color, material)
	local volume = size.X * size.Y * size.Z
	local count = math.clamp(math.round(volume / 10), 3, 12)
	local halfSize = size / 2

	for i = 1, count do
		local debris = Instance.new("Part")
		debris.Size = Vector3.new(1, 1, 1) * (math.random(5, 15) / 10)
		debris.Color = color
		debris.Material = material
		debris.Anchored = false
		debris.CanCollide = false 
		
		local offsetX = (math.random() * size.X) - halfSize.X
		local offsetY = (math.random() * size.Y) - halfSize.Y
		local offsetZ = (math.random() * size.Z) - halfSize.Z
		debris.CFrame = cframe * CFrame.new(offsetX, offsetY, offsetZ)

		debris.Parent = workspace.Terrain

		debris.AssemblyLinearVelocity = Vector3.new(
			math.random(-25, 25),
			math.random(20, 40),
			math.random(-25, 25)
		)
		debris.AssemblyAngularVelocity = Vector3.new(
			math.random(-15, 15),
			math.random(-15, 15),
			math.random(-15, 15)
		)

		task.delay(math.random(5, 15) / 10, function()
			local tween = TweenService:Create(
				debris, 
				TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), 
				{Transparency = 1, Size = Vector3.zero}
			)
			tween:Play()
			tween.Completed:Connect(function()
				debris:Destroy()
			end)
		end)
	end
end

return DestructionEffect