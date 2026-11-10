-- PushClient (CLIENT ModuleScript) -> INSIDE the CombatController, folder "Push", next to PushEffect.
-- Drives the LOCAL player through the push:
--   * turns the character towards the camera direction and plays the Push animation (everybody sees it: the Animator replicates)
--   * the force wave is shown at once on his screen at ReleaseTime (the server resolves the same wave for everybody else)
--   * camera: slight zoom-in during the windup, a punch outwards at the release
-- Returns a cleanup function; CombatController calls it when the ability gets cancelled.

local PushClient = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PushEffect = require(script.Parent:WaitForChild("PushEffect"))

local function flatten(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

local function loadTrack(humanoid, animationId)
	if not animationId then return nil end
	local id = tostring(animationId)
	if not string.find(id, "rbxassetid://", 1, true) then id = "rbxassetid://" .. id end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then return nil end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	if not ok or not track then return nil end
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	return track
end

-- ctx = { config, character, root, humanoid, defaultFov, setFov(value, time), alive() -> bool, aim }
function PushClient.Start(ctx)
	local config, root, humanoid = ctx.config, ctx.root, ctx.humanoid
	local localPlayer = Players.LocalPlayer :: Player
	local lookVectorBefore = root.CFrame.LookVector
	ctx.aim = lookVectorBefore	-- The server always take the previous CFrame of the player

	local aim = ctx.aim or flatten(root.CFrame.LookVector) or Vector3.zAxis
	local releaseTime = config.ReleaseTime or 0.35

	local cancelled = false
	local track = loadTrack(humanoid, config.Animation)

	local function cleanup()
		cancelled = true
		if track then track:Stop(0.15) track = nil end
		PushEffect.Cancel(localPlayer)
		ctx.setFov(ctx.defaultFov, 0.25)
	end

	-- face the push direction, play the animation
	root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
	if track then
		local current = track
		current:Play(0.05, 1, config.AnimSpeed or 1)
		current.Stopped:Once(function() current:Destroy() end)
	end
	ctx.setFov(ctx.defaultFov - 5, releaseTime)

	-- the wave on his own screen, without waiting for the server
	PushEffect.Cast(localPlayer, ctx.character, {
		aim = aim, range = config.Range, angle = config.Angle, releaseTime = releaseTime,
		startTime = Workspace:GetServerTimeNow(),
	})

	task.delay(releaseTime, function()
		if cancelled or not ctx.alive() then return end
		ctx.setFov(ctx.defaultFov + 12, 0.06) -- punch outwards
		task.delay(0.08, function()
			if not cancelled then ctx.setFov(ctx.defaultFov, 0.4) end
		end)
	end)

	return cleanup
end

return PushClient