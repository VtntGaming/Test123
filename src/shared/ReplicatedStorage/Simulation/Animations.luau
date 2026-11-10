--!strict
-- Plays tracked action timelines continuously, aligning live tracks at transitions and rollback corrections.
-- Immutable clip metadata is collected outside simulation; track handles are never retained between steps.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local State = require(script.Parent.State)
local Weapons = require(ReplicatedStorage.SharedModules.WeaponConfig)
local Abilities = require(ReplicatedStorage.SharedModules.AbilityConfig)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local ClientSimulation = SimulationConfig.ClientSimulation
local CharacterAnimations = ReplicatedStorage.Assets.Animations.Character

--// Constants
local FADE_TIME = 0.1
local POSITION_TOLERANCE = 1 / 30
local END_EPSILON = 0.0001

--// Types
type WeaponAnimations = { Idle: Animation, Attack: Animation, JumpAttack: Animation }
type Timeline = { Position: number, Speed: number, Length: number? }
export type Animations = {
	-- Caches available clip lengths outside simulation without retaining live animation tracks.
	Prepare: () -> (),
	-- Updates eligible actors' animation tracks from replayable action state at now in seconds; dt is the step interval.
	Step: (number, number) -> ()
}

--// Properties
local WeaponAnimations: { [string]: WeaponAnimations } = {}
local AbilityAnimations: { [string]: Animation } = {}
local Catalog: { Animation } = { CharacterAnimations.Idle, CharacterAnimations.Running, CharacterAnimations.Jumping }
local AnimationIds: { [Animation]: string } = {}
local ClipLengths: { [string]: number } = {}
for _, animation in Catalog do
	AnimationIds[animation] = animation.AnimationId
end

local function Create(id: string | number): Animation
	local animation = Instance.new("Animation")
	animation.AnimationId = if type(id) == "number" then "rbxassetid://" .. tostring(id) else id
	AnimationIds[animation] = animation.AnimationId
	table.insert(Catalog, animation)
	return animation
end

for name, config in Weapons.BaseWeapons do
	WeaponAnimations[name] = {
		Idle = Create(config.Idle),
		Attack = Create(config.Attack.AnimationId),
		JumpAttack = Create(config.JumpAttack.AnimationId),
	}
end
for name, config in Abilities.Abilities do
	local id = config.Animation or config.M2
	if id then
		AbilityAnimations[name] = Create(id)
	end
end

--// Controller
local Animations: Animations = {} :: Animations

local function Play(
	animator: Animator,
	animation: Animation,
	priority: Enum.AnimationPriority,
	looped: boolean,
	timeline: Timeline?,
	selected: { [string]: boolean }
)
	local id = AnimationIds[animation]
	selected[id] = true
	local track = animator:GetTrackByAnimationId(id)
	if not track then
		track = animator:LoadAnimation(animation)
	end
	track.Priority, track.Looped = priority, looped
	local starting = not track.IsPlaying
	local resuming = not starting and track.WeightTarget == 0
	if starting then
		track:Play(FADE_TIME)
	elseif resuming then
		track:AdjustWeight(1, FADE_TIME)
	end
	local speed = if timeline then timeline.Speed else 1
	if timeline then
		local position = math.max(0, timeline.Position)
		local length = ClipLengths[id] or timeline.Length
		if length and length > 0 then
			if looped then
				position %= length
			else
				local lastPosition = math.max(0, length - END_EPSILON)
				position = math.min(position, lastPosition)
				if position >= lastPosition then
					speed = 0
				end
			end
		end
		local difference = math.abs(track.TimePosition - position)
		if looped and length and length > 0 then
			difference %= length
			difference = math.min(difference, length - difference)
		end
		-- Normal playback supplies the in-between poses. Only discontinuities need a seek.
		if
			starting
			or resuming
			or track.Speed ~= speed
			or RunService:IsResimulating()
			or difference > POSITION_TOLERANCE
		then
			track.TimePosition = position
		end
	end
	if track.Speed ~= speed then
		track:AdjustSpeed(speed)
	end
end

--// APIs
function Animations.Prepare()
	-- Length and Animation.AnimationId have no Simulation Access. Cache only immutable data,
	-- and query the live tracks again in Step because rollback can replace their handles.
	for _, record in State.Records do
		local animator = record.Animator
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				local length = track.Length
				if length > 0 and length < math.huge then
					ClipLengths[track.Animation.AnimationId] = length
				end
			end
		end
	end
end

function Animations.Step(dt, now)
	for _, record in State.Records do
		if not record.Ready then
			continue
		end
		if not IsServer then
			if record.Owner == LocalPlayer and not ClientSimulation.LocalPlayer.GameplayAnimations then
				continue
			end
			if
				not ClientSimulation.NPCs.GameplayAnimations
				and record.Actor:GetAttribute("KnockbackActorKind") == "NPC"
			then
				continue
			end
		end
		local humanoid, animator = record.Humanoid, record.Animator
		if not humanoid or not animator or not record.Alive then
			continue
		end
		if not IsServer and RunService:GetPredictionStatus(record.Root) ~= Enum.PredictionStatus.Predicted then
			continue
		end
		if record.Actor:GetAttribute("TimeStopped") == true then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:AdjustSpeed(0)
			end
			continue
		end
		local selected: { [string]: boolean } = {}
		if Attributes.Get(record.Root, "KBActive") ~= true then
			local airborne = humanoid.FloorMaterial == Enum.Material.Air
			local speed = (record.Root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
			local core = if airborne
				then CharacterAnimations.Jumping
				else if speed > 0.5 then CharacterAnimations.Running else CharacterAnimations.Idle
			local jumpAt = Attributes.Get(humanoid, "SALastJump") :: number?
			Play(
				animator,
				core,
				Enum.AnimationPriority.Core,
				not airborne,
				if airborne and jumpAt then { Position = now - jumpAt, Speed = 1 } else nil,
				selected
			)
			local weaponName = (Attributes.Get(humanoid, "SAAttackWeapon") :: string?)
				or (Attributes.Get(record.Root, "SAEquippedWeapon") :: string?)
				or record.Actor:GetAttribute("EquippedBaseWeapon") :: string?
			local weapon = weaponName and Weapons.BaseWeapons[weaponName]
			local animations = weaponName and WeaponAnimations[weaponName]
			local charging = Attributes.Get(humanoid, "SACharging") == true
			local releasedAt = Attributes.Get(humanoid, "SAReleasedAt") :: number?
			local kind = (Attributes.Get(humanoid, "SAAttackType") :: string?) or "Attack"
			if weapon and animations then
				local config = if kind == "JumpAttack" then weapon.JumpAttack else weapon.Attack
				local chargeAt = (Attributes.Get(humanoid, "SAChargeStarted") :: number?) or now
				local hold = math.min(
					math.max(0, (releasedAt or now) - chargeAt),
					config.TrackChargeThreshold * config.TrackLength
				)
				local position = if charging
					then math.clamp(now - chargeAt, 0, config.TrackChargeThreshold * config.TrackLength)
					else if releasedAt then hold + now - releasedAt else math.huge
				if (charging or releasedAt ~= nil) and position < config.TrackLength then
					Play(
						animator,
						if kind == "JumpAttack" then animations.JumpAttack else animations.Attack,
						Enum.AnimationPriority.Action,
						false,
						{
							Position = position,
							Speed = if charging
									and position >= config.TrackChargeThreshold * config.TrackLength
								then 0
								else 1,
							Length = config.TrackLength,
						},
						selected
					)
				else
					local equipped = (Attributes.Get(record.Root, "SAEquippedWeapon") :: string?)
						or record.Actor:GetAttribute("EquippedBaseWeapon") :: string?
					local idle = equipped and WeaponAnimations[equipped]
					if idle and (not record.Owner or Attributes.Get(record.Root, "SACombatAllowed") == true) then
						Play(animator, idle.Idle, Enum.AnimationPriority.Idle, true, nil, selected)
					end
				end
			end
			local ability = Attributes.Get(humanoid, "SAAbilityAnimation") :: string?
			local animation = ability and AbilityAnimations[ability]
			local config = ability and Abilities.Abilities[ability]
			if animation and config then
				local elapsed = now - ((Attributes.Get(humanoid, "SAAbilityStarted") :: number?) or now)
				local duration = if ability == "TimeStop" then config.ReadyTime else (config.Duration or 1)
				local position = elapsed
				local playbackSpeed = 1
				if ability == "Smash" then
					local upTime = (config.ImpactTime - config.DiveAnimTime) / config.RiseSpeed
					position = if elapsed < upTime
						then elapsed * config.RiseSpeed
						else config.ImpactTime - config.DiveAnimTime + (elapsed - upTime) * config.DiveSpeed
					playbackSpeed = if elapsed < upTime then config.RiseSpeed else config.DiveSpeed
					local impactAt = Attributes.Get(humanoid, "SASmashImpactAt") :: number?
					if impactAt then
						position = config.ImpactTime + math.max(0, now - impactAt - config.HitStop)
						playbackSpeed = if now - impactAt < config.HitStop then 0 else 1
					end
					duration = upTime
						+ config.DiveAnimTime / config.DiveSpeed
						+ config.HitStop
						+ (config.M2Length - config.ImpactTime)
				end
				if elapsed >= 0 and elapsed < duration then
					Play(animator, animation, Enum.AnimationPriority.Action2, ability == "Charge", {
						Position = position,
						Speed = playbackSpeed,
					}, selected)
				end
			end
		end
		for _, animation in Catalog do
			local id = AnimationIds[animation]
			if not selected[id] then
				local track = animator:GetTrackByAnimationId(id)
				if track and track.WeightTarget ~= 0 then
					track:Stop(FADE_TIME)
				end
			end
		end
	end
end

return Animations
