-- ChargeClient (CLIENT ModuleScript) V2 -> inside the CombatController, folder "Charge", next to ChargeEffect.
-- Drives the LOCAL player through the charge:
--   * starts the charge VFX INSTANTLY on the charger (the server also broadcasts it to the others)
--   * plays the run animation, WalkSpeed = RunSpeed, humanoid pushed forward every frame
--   * slow steering towards the camera (Config.TurnRate): skilled players can still dodge him
--   * the last Config.SlowDown seconds he brakes (skid)
--   * camera FOV widens while he runs
-- Returns a cleanup function; CombatController calls it when the ability gets cancelled.

local ChargeClient = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ChargeEffect = require(script.Parent:WaitForChild("ChargeEffect"))

local counter = 0

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
	track.Looped = true
	return track
end

local function flatten(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

-- ctx = { config, character, root, humanoid, defaultFov, setFov(value, time), alive() -> bool }
function ChargeClient.Start(ctx)
	local config, root, humanoid, character = ctx.config, ctx.root, ctx.humanoid, ctx.character
	local localPlayer = Players.LocalPlayer :: Player
	counter += 1
	local bindName = "ChargeMove" .. counter

	local runSpeed = config.RunSpeed or 100
	local duration = config.Duration or 1
	local slowDown = math.min(config.SlowDown or 0.3, duration * 0.5)
	local turnRate = math.rad(config.TurnRate or 140)
	local normalSpeed = humanoid.WalkSpeed -- what we return to

	local finished = false
	local track = nil

	local function finish()
		if finished then return end
		finished = true
		RunService:UnbindFromRenderStep(bindName)
		if humanoid.Parent then humanoid.WalkSpeed = normalSpeed end
		ChargeEffect.Stop(localPlayer)
		if track then
			track:Stop(0.2)
			local old = track
			task.delay(0.3, function() old:Destroy() end)
			track = nil
		end
		ctx.setFov(ctx.defaultFov, 0.3)
	end

	-- instant feedback: red highlight, ribbon, dust, rumble (the server's ChargeStart is ignored for 1.5 s)
	ChargeEffect.Start(localPlayer, character, duration)

	track = loadTrack(humanoid, config.Animation)
	if track then track:Play(0.1) end

	humanoid.WalkSpeed = runSpeed
	ctx.setFov(ctx.defaultFov + 14, 0.2)

	local camera = Workspace.CurrentCamera
	local direction = (camera and flatten(camera.CFrame.LookVector)) or flatten(root.CFrame.LookVector) or Vector3.zAxis
	local startedAt = os.clock()

	-- Runs AFTER the default control script, so our Move() call wins over the player's input.
	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Character.Value, function(dt)
		if finished then return end

		local elapsed = os.clock() - startedAt
		if elapsed >= duration then finish() return end
		if not ctx.alive() then return end -- cancelled: CombatController runs cleanup()

		local current = Workspace.CurrentCamera
		local wanted = current and flatten(current.CFrame.LookVector)
		if wanted then
			local angle = math.atan2(direction:Cross(wanted).Y, direction:Dot(wanted))
			local turn = math.clamp(angle, -turnRate * dt, turnRate * dt)
			direction = CFrame.fromAxisAngle(Vector3.yAxis, turn):VectorToWorldSpace(direction)
		end

		local speed = runSpeed
		local remaining = duration - elapsed
		if remaining < slowDown then
			local a = remaining / slowDown -- 1 -> 0
			speed = normalSpeed + (runSpeed - normalSpeed) * a * a
		end

		humanoid.WalkSpeed = speed -- asserted every frame, in case another script touches it
		humanoid:Move(direction, false)
	end)

	return finish
end

return ChargeClient