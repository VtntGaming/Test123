-- SmashClient (CLIENT ModuleScript) -> put it INSIDE the CombatController ModuleScript, next to SmashEffect.
-- Drives the LOCAL player through the smash. The M2 animation is the clock:
--   1. CLIMB   slow, high jump (animation plays at RiseSpeed, e.g. 0.75x), tornado forms under the feet
--   2. HANG    floaty pause at the top, camera widens and rumbles (anticipation)
--   3. DIVE    animation back to normal speed, the fall is timed so the character lands EXACTLY on the
--              slam frame of the animation (Config.ImpactTime), steerable with WASD
--   4. IMPACT  tells the server (it does the hits) + instant local effects + a short hit-stop on the slam frame
-- Returns a cleanup function; CombatController calls it when the ability gets cancelled.

local SmashClient = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SmashEffect = require(script.Parent:WaitForChild("SmashEffect"))

local function loadTrack(humanoid, animationId)
	if type(animationId) ~= "string" or animationId == "" then return nil end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then return nil end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	if not ok or not track then return nil end
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	return track
end

-- ctx = { config, character, root, humanoid, defaultFov, setFov(value, time), alive() -> bool,
--         onImpact(position), onFinish() }
function SmashClient.Start(ctx)
	local config, character, root, humanoid = ctx.config, ctx.character, ctx.root, ctx.humanoid
	local localPlayer = Players.LocalPlayer :: Player

	-- timing (everything comes from AbilityConfig.Smash)
	local impactAnimTime = config.ImpactTime or 1.97      -- animation time of the slam frame
	local m2Length = config.M2Length or 2.5
	local diveAnimTime = config.DiveAnimTime or 0.3
	local riseSpeed = config.RiseSpeed or 0.75
	local diveSpeed = config.DiveSpeed or 1
	local jumpHeight = config.JumpHeight or 26
	local hitStop = config.HitStop or 0.07
	local upTime = math.max(0.4, (impactAnimTime - diveAnimTime) / riseSpeed) -- real seconds spent going up + hanging
	local riseTime = upTime * (config.RiseFraction or 0.5)                    -- real seconds spent climbing
	local maxDiveSpeed = config.SlamSpeed or 160
	local hangSteer = config.HangSteer or 14
	local diveSteer = config.SteerSpeed or 20
	local timeout = (config.Duration or (upTime + 1.5)) + 0.8

	local cancelled, impacted = false, false
	local attachment, velocity, connection = nil, nil, nil
	local tracks = {}
	local m2Track = nil

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character, Workspace:FindFirstChild("CombatLocalEffects") }

	local stand = humanoid.HipHeight + root.Size.Y / 2
	if humanoid.RigType == Enum.HumanoidRigType.R6 then stand += 2 end

	local function destroyForces()
		if connection then connection:Disconnect() connection = nil end
		if velocity then velocity:Destroy() velocity = nil end
		if attachment then attachment:Destroy() attachment = nil end
	end

	-- called by CombatController when the ability is cancelled (ragdolled, server rejected, ...)
	local function cleanup()
		cancelled = true
		destroyForces()
		for _, track in tracks do track:Stop(0.1) end
		table.clear(tracks)
		SmashEffect.StopTelegraph(localPlayer)
		ctx.setFov(ctx.defaultFov, 0.25)
	end

	local function play(track, speed)
		if track then
			table.insert(tracks, track)
			track:Play(0.05, 1, speed or 1)
		end
		return track
	end

	-- height above the take-off point at t seconds: fast start, floaty near the top, then a gentle hang
	local function heightAt(t)
		if t <= 0 then return 0 end
		if t < riseTime then
			local a = t / riseTime
			return jumpHeight * (1 - (1 - a) ^ 2.2)
		end
		local hang = t - riseTime
		return jumpHeight + math.sin(hang * 3) * 0.35 * math.min(hang, 1)
	end

	task.spawn(function()
		if cancelled or not ctx.alive() then return end
		local startY = root.Position.Y
		local feet = root.Position - Vector3.new(0, stand, 0)

		-- 1) TAKE-OFF -------------------------------------------------------------
		m2Track = play(loadTrack(humanoid, config.M2), riseSpeed) -- slower animation = floatier jump
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		SmashEffect.Takeoff(feet)
		SmashEffect.StartTelegraph(localPlayer, character, config.HitRadius) -- tornado + glow, instant for the smasher
		ctx.setFov(ctx.defaultFov + 10, riseTime)

		attachment = Instance.new("Attachment")
		attachment.Name = "SmashAttachment"
		attachment.Parent = root
		velocity = Instance.new("LinearVelocity")
		velocity.Name = "SmashVelocity"
		velocity.Attachment0 = attachment
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.MaxForce = 9999999
		velocity.VectorVelocity = Vector3.new(0, 40, 0)
		velocity.Parent = root

		local startedAt = os.clock()
		local hung, diving = false, false

		connection = RunService.Heartbeat:Connect(function()
			if cancelled or impacted then return end
			if not ctx.alive() then return end -- CombatController runs cleanup()

			local t = os.clock() - startedAt
			if t > timeout then
				-- never landed (fell into the void, got stuck ...): give up cleanly
				cleanup()
				ctx.onFinish()
				return
			end

			local move = humanoid.MoveDirection

			if t < upTime then
				-- 2) CLIMB, then HANG ---------------------------------------------
				if not hung and t >= riseTime then
					hung = true
					local hangTime = math.max(0.2, upTime - riseTime)
					ctx.setFov(ctx.defaultFov + 18, hangTime)
					SmashEffect.Rumble(1.4, hangTime) -- tension builds at the top
				end
				local ahead = 0.04
				local feedForward = (heightAt(t + ahead) - heightAt(t)) / ahead
				local delta = (startY + heightAt(t)) - root.Position.Y
				local vy = math.clamp(feedForward + delta * 10, -120, 120)
				velocity.VectorVelocity = Vector3.new(move.X * hangSteer, vy, move.Z * hangSteer)
				return
			end

			-- 3) DIVE ---------------------------------------------------------------
			if not diving then
				diving = true
				if m2Track then m2Track:AdjustSpeed(diveSpeed) end -- the animation returns to normal speed
				if config.UseDownSlam then play(loadTrack(humanoid, config.DownSlam), 1) end
				ctx.setFov(ctx.defaultFov + 28, 0.12)
				SmashEffect.Dive(root.Position)
			end

			local hit = Workspace:Raycast(root.Position, Vector3.new(0, -(stand + 2.6), 0), rayParams)
			if hit or humanoid.FloorMaterial ~= Enum.Material.Air then
				-- 4) IMPACT ---------------------------------------------------------
				impacted = true
				local groundPosition = hit and hit.Position or (root.Position - Vector3.new(0, stand, 0))
				if hit then
					local lift = stand - (root.Position.Y - hit.Position.Y)
					if lift > 0 then root.CFrame += Vector3.new(0, lift, 0) end
				end
				destroyForces()
				root.AssemblyLinearVelocity = Vector3.zero

				ctx.onImpact(root.Position)                                         -- server does the hits
				SmashEffect.StopTelegraph(localPlayer)
				SmashEffect.Impact(groundPosition, config.HitRadius, character, true) -- instant local feedback

				-- land exactly on the slam frame, freeze it for a beat (hit-stop), then play the recovery
				if m2Track then
					m2Track.TimePosition = math.min(impactAnimTime, math.max(0, m2Track.Length - 0.02))
					m2Track:AdjustSpeed(0)
					task.delay(hitStop, function()
						if m2Track and m2Track.IsPlaying then m2Track:AdjustSpeed(1) end
					end)
				end

				-- FOV "punch": snap in, spring back
				ctx.setFov(ctx.defaultFov - 10, 0.06)
				task.delay(0.08, function() ctx.setFov(ctx.defaultFov, 0.45) end)

				task.delay(math.max(0.3, m2Length - impactAnimTime) + hitStop, function()
					for _, track in tracks do track:Stop(0.25) end
					table.clear(tracks)
					ctx.onFinish()
				end)
				return
			end

			-- fall speed: reach the ground exactly when the animation reaches its slam frame
			local floorHit = Workspace:Raycast(root.Position, Vector3.new(0, -400, 0), rayParams)
			local distance = floorHit and math.max(0, root.Position.Y - floorHit.Position.Y - stand) or 60
			local remaining
			if m2Track and m2Track.Length > 0 then
				remaining = (impactAnimTime - m2Track.TimePosition) / math.max(diveSpeed, 0.1)
			else
				remaining = diveAnimTime / math.max(diveSpeed, 0.1) - (t - upTime)
			end
			local speed = if remaining > 0.03 then distance / remaining else maxDiveSpeed
			speed = math.clamp(speed, 40, maxDiveSpeed * 1.4)
			velocity.VectorVelocity = Vector3.new(move.X * diveSteer, -speed, move.Z * diveSteer)
		end)
	end)

	return cleanup
end

return SmashClient