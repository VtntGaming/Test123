-- PullClient (CLIENT ModuleScript) -> INSIDE the CombatController, folder "Pull", next to PullEffect.
-- Drives the LOCAL player through the pull:
--   * turns the character towards the camera direction and plays the Pull animation (everybody sees it: the Animator replicates)
--   * the pull effect is shown at once on his screen at ReleaseTime (the server resolves the same pull for everybody else)
--   * camera: slight zoom-out during the windup, a snap IN at the release (like yanking something towards you)
-- Returns a cleanup function; CombatController calls it when the ability gets cancelled.

local PullClient = {}

local Players = game:GetService("Players")

local PullEffect = require(script.Parent:WaitForChild("PullEffect"))

local function flatten(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

local function loadTrack(humanoid, animationId)
	return nil
end -- Shared simulation owns gameplay tracks.


-- ctx = { config, character, root, humanoid, defaultFov, setFov(value, time), alive() -> bool, aim }
function PullClient.Start(ctx)
	local config, root, humanoid = ctx.config, ctx.root, ctx.humanoid
	local localPlayer = Players.LocalPlayer
	local aim = ctx.aim or flatten(root.CFrame.LookVector) or Vector3.zAxis
	local releaseTime = config.ReleaseTime or 0.35

	local cancelled = false
	local track = loadTrack(humanoid, config.Animation)

	local function cleanup()
		cancelled = true
		if track then track:Stop(0.15) track = nil end
		PullEffect.Cancel(localPlayer)
		ctx.setFov(ctx.defaultFov, 0.25)
	end

	-- face the pull direction, play the animation
	if track then
		local current = track
		current:Play(0.05, 1, config.AnimSpeed or 1)
		current.Stopped:Once(function() current:Destroy() end)
	end
	ctx.setFov(ctx.defaultFov + 5, releaseTime)

	-- the pull on his own screen, without waiting for the server
	PullEffect.Cast(localPlayer, ctx.character, {
		aim = aim, range = config.Range, angle = config.Angle, releaseTime = releaseTime,
		startTime = time(),
	})

	task.delay(releaseTime, function()
		if cancelled or not ctx.alive() then return end
		ctx.setFov(ctx.defaultFov - 9, 0.06) -- snap in
		task.delay(0.08, function()
			if not cancelled then ctx.setFov(ctx.defaultFov, 0.45) end
		end)
	end)

	return cleanup
end

return PullClient