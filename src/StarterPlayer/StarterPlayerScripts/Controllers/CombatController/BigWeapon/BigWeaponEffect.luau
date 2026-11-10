--!strict
-- Smooths authoritative BigWeapon resizing using an explicit baseline and actual grip dimensions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local AbilityConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("AbilityConfig"))
local heavyswordSwing = SoundService.SFX.heavyswordswing

type Record = {
	weapon: Model,
	baseScale: number,
	baseSize: Vector3,
	baseParts: { [BasePart]: CFrame },
	targetScale: number,
	visualScale: number,
	player: Player,
	character: Model,
	gripHost: BasePart,
	gripOffset: CFrame,
	connection: RBXScriptConnection?,
}
export type BigWeaponEffect = {
	Start: (player: unknown, character: unknown, data: unknown) -> (),
	End: (player: Player) -> (),
	Impact: (player: unknown, center: unknown, radius: unknown) -> (),
	Init: (shakeFn: unknown?) -> (),
}
local BigWeaponEffect = {} :: BigWeaponEffect
local active: { [Player]: Record } = {}
local Initialized = false

local function getCfg()
	return AbilityConfig.Abilities.BigWeapon or {}
end

local function setWeaponScale(record: Record, weapon: Model, scale: number)
	if not weapon or not weapon.Parent then return end
	local main = weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then return end
	if not record.gripHost:IsDescendantOf(record.character) then return end
	-- Derive the grip from the moving hand and the server's unscaled offset.
	-- The observed Main.CFrame may already contain a replicated or locally scaled offset.
	local mainCFrame = record.gripHost.CFrame * record.gripOffset
	-- Scaling/pivoting a weapon with an active grip can move the holder's entire
	-- assembly. Disconnect endpoints as ShrinkScale does, without yielding.
	local joints: { { Joint: WeldConstraint, Part0: BasePart, Part1: BasePart } } = {}
	for _, descendant in weapon:GetDescendants() do
		if descendant:IsA("WeldConstraint") and descendant.Enabled then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 then
				table.insert(joints, { Joint = descendant, Part0 = part0, Part1 = part1 })
				descendant.Enabled = false
				descendant:ResetPropertyToDefault("Part1")
			end
		end
	end
	-- Like ShrinkEffect, reconcile physical dimensions rather than trusting a local
	-- canonical scale that may have received server geometry in either order.
	local targetSize = record.baseSize * (scale / record.baseScale)
	weapon:ScaleTo(weapon:GetScale() * targetSize.X / main.Size.X)
	if (main.Size - targetSize).Magnitude > 0.0001 then
		weapon:ScaleTo(weapon:GetScale() * targetSize.X / main.Size.X)
	end
	weapon:PivotTo((mainCFrame * main.CFrame:Inverse()) * weapon:GetPivot())
	-- ScaleTo's local cache can retain original joint spacing while part sizes
	-- have replicated at a different scale. Restore every part's intended spacing
	-- explicitly before reconnecting joints, using the server's unscaled snapshot.
	local ratio = scale / record.baseScale
	for part, originalFrame in record.baseParts do
		if part ~= main and part:IsDescendantOf(weapon) then
			part.CFrame = mainCFrame * CFrame.new(originalFrame.Position * ratio) * originalFrame.Rotation
		end
	end
	
	for _, saved in joints do
		saved.Joint.Part0 = saved.Part0
		saved.Joint.Part1 = saved.Part1
		saved.Joint.Enabled = true
	end
	
	record.visualScale = scale
end

local function stopRecordTween(record: Record?)
	if record and record.connection then
		record.connection:Disconnect()
		record.connection = nil
	end
end

local function tweenScale(record: Record, weapon: Model, fromScale: number, toScale: number, duration: number,
	easingDirection: Enum.EasingDirection, onComplete: (() -> ())?)
	stopRecordTween(record)
	local startTime = os.clock()
	duration = math.max(duration or 0.3, 0.05)

	record.connection = RunService.PreSimulation:Connect(function()
		if not weapon or not weapon.Parent or active[record.player] ~= record
			or record.player.Character ~= record.character
			or weapon.Parent ~= record.character then
			stopRecordTween(record)
			if active[record.player] == record then active[record.player] = nil end
			return
		end
		local elapsed = os.clock() - startTime
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local eased = TweenService:GetValue(
			alpha,
			Enum.EasingStyle.Quad,
			easingDirection or Enum.EasingDirection.Out
		)
		local current = fromScale + (toScale - fromScale) * eased
		setWeaponScale(record, weapon, current)

		if alpha >= 1 then
			stopRecordTween(record)
			setWeaponScale(record, weapon, toScale)
			if onComplete then onComplete() end
		end
	end)
end

function BigWeaponEffect.Start(player, character, data)
	if typeof(player) ~= "Instance" or not player:IsA("Player")
		or typeof(character) ~= "Instance" or not character:IsA("Model") or player.Character ~= character then return end
	if type(data) ~= "table" then return end
	local payload = data :: { [string]: unknown }
	local weapon = payload.weapon
	if typeof(weapon) ~= "Instance" or not weapon:IsA("Model") or weapon.Parent ~= character then return end
	local main = weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then return end
	local gripHost, gripOffset = payload.gripHost, payload.gripOffset
	if typeof(gripHost) ~= "Instance" or not gripHost:IsA("BasePart")
		or not gripHost:IsDescendantOf(character) or typeof(gripOffset) ~= "CFrame" then return end
	local baseScale, baseSize, targetScale = payload.baseScale, payload.baseSize, payload.targetScale
	if type(baseScale) ~= "number" or baseScale <= 0 or baseScale >= math.huge or baseScale ~= baseScale
		or typeof(baseSize) ~= "Vector3" or baseSize.X <= 0
		or type(targetScale) ~= "number" or targetScale <= 0 or targetScale >= math.huge or targetScale ~= targetScale then return end
	local rawParts = payload.baseParts
	if type(rawParts) ~= "table" then return end
	local baseParts: { [BasePart]: CFrame } = {}
	for _, entry in rawParts :: { unknown } do
		if type(entry) ~= "table" then return end
		local fields = entry :: { [string]: unknown }
		local part, frame = fields.part, fields.frame
		if typeof(part) ~= "Instance" or not part:IsA("BasePart") or not part:IsDescendantOf(weapon)
			or typeof(frame) ~= "CFrame" then return end
		baseParts[part] = frame
	end
	if not baseParts[main] then return end
	local previous = active[player]
	local fromScale = if previous and previous.weapon == weapon then previous.visualScale else baseScale
	stopRecordTween(previous)

	local cfg = getCfg()
	local growTime = cfg.GrowTime or 0.3
	
	local record: Record = {
		weapon = weapon,
		baseScale = baseScale,
		baseSize = baseSize,
		baseParts = baseParts,
		targetScale = targetScale,
		visualScale = fromScale,
		player = player,
		character = character,
		gripHost = gripHost,
		gripOffset = gripOffset,
		connection = nil,
	}
	active[player] = record

	setWeaponScale(record, weapon, fromScale)
	tweenScale(record, weapon, fromScale, targetScale, growTime, Enum.EasingDirection.Out)
	heavyswordSwing:Play()
end

function BigWeaponEffect.Impact(player, center, radius)
	-- All ground shockwaves, neon domes, bursts, and screen shakes removed.
end

function BigWeaponEffect.End(player)
	local record = active[player]
	if not record then return end

	local weapon = record.weapon
	local cfg = getCfg()
	local shrinkTime = cfg.ShrinkTime or 0.25

	if weapon and weapon.Parent and record.baseScale then
		local currentScale = record.visualScale
		tweenScale(record, weapon, currentScale, record.baseScale, shrinkTime, Enum.EasingDirection.InOut, function()
			if active[player] == record then active[player] = nil end
		end)
	else
		stopRecordTween(record)
		active[player] = nil
	end
end

function BigWeaponEffect.Init(shakeFn)
	if Initialized then return end
	Initialized = true
	Players.PlayerRemoving:Connect(function(player: Player)
		stopRecordTween(active[player])
		active[player] = nil
	end)
end

return BigWeaponEffect
