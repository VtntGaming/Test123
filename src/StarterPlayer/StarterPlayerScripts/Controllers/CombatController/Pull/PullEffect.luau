-- PullEffect (CLIENT ModuleScript) -> INSIDE the CombatController, folder "Pull", next to PullClient.
-- Runs on EVERY client (the server broadcasts PullStart / PullHook / PullEnd) and instantly on the puller (PullClient).
--   WINDUP   purple body glow, a ring collapses into the hand, suction sound, tension rumble
--   RELEASE  big rings RUSH BACK towards the puller while shrinking, wind streaks and dust race INTO him, burst + flash
--   EVERY HOOKED TARGET  a glowing rope between the puller's hand and the target, sparks at the target,
--                        and a landing puff + ring + shake where the target arrives
--   the puller and the victim get their own camera shake, the victim a screen flash

local PullEffect = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ForceFX = require(script.Parent.Parent:WaitForChild("ForceFX"))

local CONFIG = {
	COLOR = Color3.fromRGB(190, 120, 255),
	WHITE = Color3.fromRGB(250, 240, 255),
	LINES = 20,                       -- wind streaks per pull
	RINGS = 3,                        -- implosion rings per pull
	TETHER_TIME = 0.5,                -- seconds the rope stays
	ARRIVE_TIME = 0.55,               -- seconds until the landing puff (the targets fly for about this long)
	SOUND_WINDUP = "WeaponSwing3",    -- names inside SoundService.SFX or SoundService.Effects ("" = none)
	SOUND_RELEASE = "WeaponSwing",
	SOUND_HOOK = "Rock",
	SOUND_ARRIVE = "Rock",
}

local active = {} -- [Player] = { startedAt, cancelled, stopGlow }

local function release(character, root, aim, range, angle, isLocal)
	local origin = root.Position
	local chest = origin + Vector3.new(0, 0.5, 0) + aim * 2
	local right = aim:Cross(Vector3.yAxis)
	right = if right.Magnitude > 0.01 then right.Unit else Vector3.xAxis
	local coneWidth = math.min(2 * range * math.tan(math.rad(math.min(angle, 80))) * 0.8, range * 1.2)

	-- 1) implosion rings: start far away, wide, and rush back to the puller while shrinking
	for i = 1, CONFIG.RINGS do
		task.delay((i - 1) * 0.08, function()
			ForceFX.Ring(chest + aim * (range * 0.9), aim, if i == 1 then CONFIG.WHITE else CONFIG.COLOR, coneWidth, 1.5, 0.42, -range * 0.85)
		end)
	end

	-- 2) wind streaks rushing INTO the puller
	for _ = 1, CONFIG.LINES do
		local yaw = math.rad((math.random() * 2 - 1) * angle * 0.9)
		local pitch = math.rad((math.random() * 2 - 1) * 10)
		local direction = (CFrame.fromAxisAngle(Vector3.yAxis, yaw) * CFrame.fromAxisAngle(right, pitch)):VectorToWorldSpace(aim)
		local distance = range * (0.55 + math.random() * 0.45)
		local start = chest + direction * distance + right * (math.random() * 2 - 1)
		ForceFX.WindLine(
			start, -direction, distance * 0.95, 0.3 + math.random() * 0.12,
			if math.random() < 0.5 then CONFIG.WHITE else CONFIG.COLOR, 0.3
		)
	end

	-- 3) dust racing towards the puller
	ForceFX.DustCone(origin, aim, range, angle, true, character)

	-- 4) burst at the hands, flash, sound, camera
	ForceFX.Burst(chest, CONFIG.WHITE, 18, 45, Vector2.new(180, 180), 1.1)
	ForceFX.Flash(chest, CONFIG.COLOR, 4)
	ForceFX.PlaySoundAt(CONFIG.SOUND_RELEASE, origin, 1.35, 1)
	if isLocal then
		ForceFX.Shake(3.5, 0.45)
	else
		ForceFX.ShakeAt(origin, 2, 0.3)
	end
end

function PullEffect.Init() end

-- params = { aim, range, angle, releaseTime, startTime (server time) }
function PullEffect.Cast(player: Player, character: Model, params)
	local existing = active[player]
	if existing and os.clock() - existing.startedAt < 1.5 then return end -- the puller already started it locally
	PullEffect.Cancel(player)

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or type(params) ~= "table" or typeof(params.aim) ~= "Vector3" then return end

	local aim = params.aim
	local range, angle = params.range or 40, params.angle or 25
	local releaseTime = params.releaseTime or 0.35
	local isLocal = player == Players.LocalPlayer :: Player

	local entry = { startedAt = os.clock(), cancelled = false }
	entry.stopGlow = ForceFX.Glow(character, CONFIG.COLOR, CONFIG.WHITE)
	active[player] = entry

	-- windup: a ring collapses into the hand, suction sound, tension
	local hand = ForceFX.HandPosition(character)
	ForceFX.Ring(hand, aim, CONFIG.COLOR, 6, 0.6, releaseTime * 0.9, 0)
	ForceFX.PlaySoundAt(CONFIG.SOUND_WINDUP, root.Position, 1.3, 0.8)
	if isLocal then ForceFX.Shake(1.2, releaseTime, 18) end

	local now = Workspace:GetServerTimeNow()
	local wait = math.clamp((params.startTime or now) + releaseTime - now, 0, releaseTime)
	task.delay(wait, function()
		if entry.cancelled or active[player] ~= entry then return end
		if root.Parent then release(character, root, aim, range, angle, isLocal) end
		entry.stopGlow(0.3)
		task.delay(1.6, function() -- stays registered a little longer: ignores the server's own PullStart for the puller
			if active[player] == entry then active[player] = nil end
		end)
	end)
end

-- the puller got ragdolled / the server cancelled the pull
function PullEffect.Cancel(player)
	local entry = active[player]
	if not entry then return end
	entry.cancelled = true
	entry.stopGlow(0.1)
	active[player] = nil
end

-- a target got hooked: rope from the puller's hand, sparks, and a landing puff where it arrives
function PullEffect.Hook(player, target, stopPoint)
	if typeof(target) ~= "Instance" or not target.Parent then return end
	local toPart = if target:IsA("BasePart") then target else target:FindFirstChild("HumanoidRootPart")
	if not toPart then return end
	local puller = player.Character
	local fromPart = puller and (puller:FindFirstChild("RightHand") or puller:FindFirstChild("Right Arm") or puller:FindFirstChild("HumanoidRootPart"))

	ForceFX.Tether(fromPart, toPart, CONFIG.COLOR, CONFIG.TETHER_TIME)
	ForceFX.Burst(toPart.Position, CONFIG.WHITE, 14, 40, Vector2.new(180, 180), 1.0)
	ForceFX.Burst(toPart.Position, CONFIG.COLOR, 12, 30, Vector2.new(180, 180), 1.3)
	ForceFX.Flash(toPart.Position, CONFIG.COLOR, 3)
	ForceFX.PlaySoundAt(CONFIG.SOUND_HOOK, toPart.Position, 1.25, 0.9)
	if player ~= Players.LocalPlayer :: Player then ForceFX.ShakeAt(toPart.Position, 1.8, 0.3) end -- bystanders

	if typeof(stopPoint) == "Vector3" then
		task.delay(CONFIG.ARRIVE_TIME, function()
			ForceFX.Burst(stopPoint + Vector3.new(0, 0.5, 0), Color3.fromRGB(225, 215, 195), 14, 24, Vector2.new(80, 80), 1.8)
			ForceFX.GroundRing(stopPoint, CONFIG.COLOR, 9, 0.35, 0.2)
			ForceFX.PlaySoundAt(CONFIG.SOUND_ARRIVE, stopPoint, 0.8, 0.9)
			ForceFX.ShakeAt(stopPoint, 2.5, 0.35)
		end)
	end
end

-- local puller: hooked something (count = how many)
function PullEffect.PullerHit(count)
	ForceFX.Shake(2 + math.min(count, 4) * 1.0, 0.45)
end

-- local victim: got pulled
function PullEffect.Victim()
	ForceFX.Shake(5, 0.7)
	ForceFX.ScreenFlash(CONFIG.COLOR, 0.6, 0.45)
end

return PullEffect