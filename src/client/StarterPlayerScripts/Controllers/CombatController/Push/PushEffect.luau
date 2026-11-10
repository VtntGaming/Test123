-- PushEffect (CLIENT ModuleScript) -> INSIDE the CombatController, folder "Push", next to PushClient.
-- Runs on EVERY client and instantly on the pusher (PushClient).

local PushEffect = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local RockModule = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("VFXUtils"):WaitForChild("RockModule"))
local ForceFX = require(script.Parent.Parent:WaitForChild("ForceFX"))

local CONFIG = {
	COLOR = Color3.fromRGB(110, 200, 255),
	WHITE = Color3.fromRGB(240, 250, 255),
	SOUND_WINDUP = "WeaponSwing",
	SOUND_RELEASE = "WeaponSwing2",
	SOUND_BOOM = "Push",
	SOUND_HIT = "Rock",

	-- RockModule V-formation parameters matching your screenshot:
	ROCK_ANGLE = 45,        -- Opening angle of the V
	ROCK_LINES = 2,         -- 2 diverging lines of rocks
	ROCK_COUNT = 32,        -- Total rocks distributed across lines
	START_SIZE = 1.4,       -- Rock size starting close to player
	END_SIZE = 4.2,         -- Rock size at max range
	START_DISTANCE = 4,     -- Forward distance from feet where rocks start
	POPUP_TIME = 0.25,      -- Speed at which the rock wave travels forward
	LIFETIME = 1.6,         -- Seconds the rocks stay emerged
	RETRACT_TIME = 0.5,     -- Duration rocks take to sink back underground
}

local active = {} -- [Player] = { startedAt, cancelled, stopGlow }

local function release(character, root, aim, range, angle, isLocal)
	local origin = root.Position
	local feet = origin - Vector3.new(0, 2.5, 0)
	local chest = origin + Vector3.new(0, 0.5, 0) + aim * 2

	-- 1) V-Shaped Rock Ground Fracture
	task.delay(0.25, function()
		RockModule.new(
			feet + Vector3.new(0, 1.5, 0),         -- origin
			aim,                                   -- direction
			Vector3.new(0, -10, 0),                -- raycastDirection (down to find ground)
			CONFIG.ROCK_ANGLE,                     -- angle
			CONFIG.ROCK_LINES,                     -- lines (2 for V shape)
			range or 28,                           -- distance
			CONFIG.START_SIZE,                     -- startSize
			CONFIG.END_SIZE,                       -- endSize
			CONFIG.ROCK_COUNT,                     -- numRocks
			CONFIG.LIFETIME,                       -- lifetime
			CONFIG.START_DISTANCE,                 -- startDistance
			CONFIG.POPUP_TIME,                     -- popupTime
			CONFIG.RETRACT_TIME                    -- retractTime
		)
	end)
	

	-- 2) Ground dust following the blast
	ForceFX.DustCone(origin, aim, range, angle, false, character)

	-- 3) Subtle forward air puff, flash, and sound
	ForceFX.Burst(chest + aim * 1.5, CONFIG.WHITE, 16, 50, Vector2.new(angle, angle), 1.0, aim)
	ForceFX.Flash(chest, CONFIG.COLOR, 4)
	ForceFX.PlaySoundAt(CONFIG.SOUND_RELEASE, origin, 0.75, 1)
	ForceFX.PlaySoundAt(CONFIG.SOUND_BOOM, origin, 0.9, 1)

	if isLocal then
		ForceFX.Shake(5, 0.45)
	else
		ForceFX.ShakeAt(origin, 3, 0.35)
	end
end

function PushEffect.Init() end

-- params = { aim, range, angle, releaseTime, startTime (server time) }
function PushEffect.Cast(player, character, params)
	local existing = active[player]
	if existing and os.clock() - existing.startedAt < 1.5 then return end
	PushEffect.Cancel(player)

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or type(params) ~= "table" or typeof(params.aim) ~= "Vector3" then return end

	local aim = params.aim
	local range, angle = params.range or 28, params.angle or 55
	local releaseTime = params.releaseTime or 0.35
	local isLocal = player == Players.LocalPlayer

	local entry = { startedAt = os.clock(), cancelled = false }
	entry.stopGlow = ForceFX.Glow(character, CONFIG.COLOR, CONFIG.WHITE)
	active[player] = entry

	-- Windup tension
	ForceFX.PlaySoundAt(CONFIG.SOUND_WINDUP, root.Position, 0.7, 0.8)
	if isLocal then ForceFX.Shake(1.2, releaseTime, 18) end

	local now = time()
	local wait = math.clamp((params.startTime or now) + releaseTime - now, 0, releaseTime)
	task.delay(wait, function()
		if entry.cancelled or active[player] ~= entry then return end
		if root.Parent then release(character, root, aim, range, angle, isLocal) end
		entry.stopGlow(0.25)
		task.delay(1.6, function()
			if active[player] == entry then active[player] = nil end
		end)
	end)
end

function PushEffect.Cancel(player)
	local entry = active[player]
	if not entry then return end
	entry.cancelled = true
	entry.stopGlow(0.1)
	active[player] = nil
end

function PushEffect.Impact(player, position)
	if typeof(position) ~= "Vector3" then return end
	ForceFX.Burst(position, CONFIG.WHITE, 14, 45, Vector2.new(180, 180), 0.8)
	ForceFX.Flash(position, CONFIG.COLOR, 2.5)
	ForceFX.PlaySoundAt(CONFIG.SOUND_HIT, position, 1.1, 0.9)
	if player ~= Players.LocalPlayer then ForceFX.ShakeAt(position, 2.0, 0.3) end
end

function PushEffect.PusherHit(count)
	ForceFX.Shake(2 + math.min(count, 4) * 1.1, 0.45)
end

function PushEffect.Victim()
	ForceFX.Shake(5.5, 0.6)
	ForceFX.ScreenFlash(CONFIG.WHITE, 0.5, 0.35)
end

return PushEffect
