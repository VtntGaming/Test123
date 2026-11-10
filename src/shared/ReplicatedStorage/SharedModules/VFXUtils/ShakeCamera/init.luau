local CameraShaker = require(game.ReplicatedStorage.Module.Utils.ShakeCamera.CameraShaker)
local module = function(Pos, SV, ShakeDistance, Preset)
	local plrshaked = {}

	task.spawn(function()
		for _, plr in pairs(game.Players:GetPlayers()) do
			local nearchar = plr.Character
			if nearchar and nearchar:FindFirstChild("Humanoid") and nearchar:FindFirstChild("HumanoidRootPart") then
				if (nearchar.HumanoidRootPart.Position - Pos).Magnitude <= ShakeDistance then

					if not plrshaked[plr.Name] then
						plrshaked[plr.Name] = true

						if SV then
							--game.ReplicatedStorage.Event.Client:FireClient(plr, "ShakeCamera", Preset)
						else
							local camera = game.Workspace.CurrentCamera
							local camshake = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCFrame)
								camera.CFrame = camera.CFrame * shakeCFrame
							end)
							camshake:Start()
							camshake:Shake(CameraShaker.Presets[Preset])
						end
					end
				end
			end
		end
	end)
end

return module
