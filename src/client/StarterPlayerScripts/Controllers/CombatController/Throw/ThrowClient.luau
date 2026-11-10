-- ThrowClient (CLIENT ModuleScript) -> inside the CombatController ModuleScript, folder "Throw", next to ThrowEffect.
-- Drives the LOCAL player through the throw:
--   * turns the character towards the camera direction, plays the Throw animation (everybody sees it: the Animator replicates)
--   * after Config.ReleaseTime (= the release frame of the animation) the weapon leaves the hand:
--     the flight is started LOCALLY at once (the server starts the same flight for everybody else and does the hits)
-- Returns a cleanup function; CombatController calls it when the ability gets cancelled.

local ThrowClient = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local ThrowEffect = require(script.Parent:WaitForChild("ThrowEffect"))
local PlayerData = require(ReplicatedStorage.PlayerData)

local function flatten(vector)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.01 then flat.Unit else nil
end

local function loadTrack(humanoid, animationId)
	return nil
end -- Shared simulation owns gameplay tracks.


-- the direction (flat) the weapon will be thrown: where the camera looks. CombatController sends it with the Request.
function ThrowClient.GetAim()
	local camera = Workspace.CurrentCamera
	return camera and flatten(camera.CFrame.LookVector) or nil
end

-- everything a thrown weapon must not fly through (walls), but players / NPCs are ignored
local function obstructionParams(character)
	local ignore = { character, Workspace:FindFirstChild("CombatLocalEffects"), Workspace:FindFirstChild("KnockbackRuntime") }
	for _, player in Players:GetPlayers() do
		if player.Character then table.insert(ignore, player.Character) end
	end
	for _, actor in CollectionService:GetTagged("CombatActor") do
		table.insert(ignore, actor)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	return params
end

-- ctx = { config, character, root, humanoid, defaultFov, setFov(value, time), alive() -> bool, aim }
function ThrowClient.Start(ctx)
	local config, character, root, humanoid = ctx.config, ctx.character, ctx.root, ctx.humanoid
	local localPlayer = Players.LocalPlayer
	local forward = ctx.aim or flatten(root.CFrame.LookVector) or Vector3.zAxis

	local cancelled = false
	local track = nil

	local function cleanup()
		cancelled = true
		if track then track:Stop(0.15) track = nil end
		ThrowEffect.Cancel(localPlayer) -- gives the weapon back to the hand immediately
		ctx.setFov(ctx.defaultFov, 0.25)
	end

	-- face the throw direction, then play the animation
	track = loadTrack(humanoid, config.Animation)
	if track then track:Play(0.05, 1, config.AnimSpeed or 1) end
	ctx.setFov(ctx.defaultFov + 6, 0.2)

	task.delay(config.ReleaseTime or 0.3, function()
		if cancelled or not ctx.alive() then return end
		local weapon = character:FindFirstChild("EquippedWeapon")
		if not weapon then return end

		local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
		local origin = if hand and hand:IsA("BasePart") then hand.Position else root.Position + Vector3.new(0, 1, 0)

		-- stops at walls (same rule as the server): range is shortened to the wall
		local range = config.Range or 55
		local hit = Workspace:Raycast(origin, forward * range, obstructionParams(character))
		if hit then range = math.max(6, hit.Distance - 2) end

		ThrowEffect.Launch(localPlayer, character, {
			scope = if PlayerData.Get(localPlayer, "IsOnArena") then "Arena" else "Training",
			origin = origin, forward = forward, range = range,
			curve = math.min(config.Curve or 12, range * 0.3),
			outTime = config.OutTime or 0.55, hoverTime = config.HoverTime or 0.3, returnTime = config.ReturnTime or 0.7,
			startTime = time(),
			weaponName = weapon:GetAttribute("WeaponName") or weapon:GetAttribute("WeaponId"),
		})
		ctx.setFov(ctx.defaultFov, 0.4)
	end)

	return cleanup
end

return ThrowClient
