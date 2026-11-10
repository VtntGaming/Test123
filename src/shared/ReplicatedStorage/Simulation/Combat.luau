--!strict
-- Advances replayable input edges and action deadlines; only the server adapter accepts hits.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Types = require(script.Parent.Types)
local Input = require(script.Parent.Input)
local State = require(script.Parent.State)
local Abilities = require(ReplicatedStorage.SharedModules.AbilityConfig)
local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local ClientCombat = SimulationConfig.ClientSimulation.LocalPlayer.Combat

--// Types
export type ActionEvent = {
	-- Actor record that produced this server-side action event.
	Record: Types.ActorRecord,
	-- Action phase: Start, Release, Cancel, Ability, or SmashImpact.
	Kind: string,
	-- Attack or ability sequence identifier used to distinguish action instances.
	Id: number,
	-- Simulation time of the event in seconds.
	At: number,
	-- Weapon attack variant captured for the event, defaulting to Attack.
	AttackType: string,
	-- Equipped ability name captured from the actor root, or an empty string.
	Ability: string,
	-- Sanitized input aim direction sampled when the event was emitted.
	Aim: Vector3,
	-- Seconds since the recorded attack charge start, or 0 when no start exists.
	Held: number,
}
export type Combat = {
	-- Advances attack and ability state at now in seconds and queues server action events; dt is the step interval.
	Step: (number, number) -> (),
	-- Returns the queued server action events and replaces the queue with an empty one.
	Drain: () -> { ActionEvent }
}

--// Properties
local Events: { ActionEvent } = {}

--// Controller
local Combat: Combat = {} :: Combat

local function Emit(record: Types.ActorRecord, kind: string, now: number, sample: Types.ActionSample)
	if not IsServer then
		return
	end
	local humanoid = record.Humanoid :: Humanoid
	table.insert(Events, {
		Record = record,
		Kind = kind,
		Id = if kind == "Ability" or kind == "SmashImpact"
			then (Attributes.Get(humanoid, "SAAbilityId") :: number?) or 0
			else (Attributes.Get(humanoid, "SAAttackId") :: number?) or 0,
		At = now,
		AttackType = (Attributes.Get(humanoid, "SAAttackType") :: string?) or "Attack",
		Ability = (Attributes.Get(record.Root, "SAEquippedAbility") :: string?) or "",
		Aim = sample.Aim,
		Held = now - ((Attributes.Get(humanoid, "SAChargeStarted") :: number?) or now),
	})
end

--// APIs
function Combat.Step(dt, now)
	for _, record in State.Records do
		if not record.Ready then
			continue
		end
		local humanoid = record.Humanoid
		if not record.Owner or not humanoid then continue end
		local root, actor = record.Root, record.Actor
		if
			not IsServer
			and (record.Owner ~= LocalPlayer or RunService:GetPredictionStatus(root) ~= Enum.PredictionStatus.Predicted)
		then
			continue
		end
		local simulateAttacks = IsServer or ClientCombat.AttackChargeAndRelease
		local simulateAttackCooldowns = IsServer or ClientCombat.AttackCooldowns
		local simulateAbilities = IsServer or ClientCombat.AbilityActivationAndCooldowns
		local sample = Input.Read(record.Owner)
		local blocked = Attributes.Get(root, "KBActive") == true or Attributes.Get(root, "SADropAt") ~= nil or actor:GetAttribute("IsFrozen") == true
			or actor:GetAttribute("TimeStopped") == true or actor:GetAttribute("MovementLocked") == true
			or Attributes.Get(root, "SACombatAllowed") ~= true or not record.Alive
		local wasAttack = Attributes.Get(humanoid, "SAWasAttack") == true
		if
			simulateAttacks and Attributes.Get(humanoid, "SACharging") == true
			and Attributes.Get(humanoid, "SAAttackEquipment") ~= actor:GetAttribute("WeaponRevision")
		then
			Emit(record, "Cancel", now, sample)
			Attributes.Set(humanoid, "SACharging", false)
			Attributes.Set(humanoid, "SAReleasedAt", nil)
		end
		local wasAbility = Attributes.Get(humanoid, "SAWasAbility") == true
		local equippedAbility = (Attributes.Get(root, "SAEquippedAbility") :: string?) or ""
		if simulateAbilities then
			Attributes.Set(
				humanoid,
				"SAAbilityReadyAt",
				if equippedAbility ~= ""
					then (Attributes.Get(humanoid, "SACD" .. equippedAbility) :: number?) or 0
					else 0
			)
		end
		if simulateAttacks then
			Attributes.Set(humanoid, "SAWasAttack", sample.Attack)
		end
		if simulateAbilities then
			Attributes.Set(humanoid, "SAWasAbility", sample.Ability)
		end
		if blocked then
			if simulateAttacks then
				if Attributes.Get(humanoid, "SACharging") == true then
					Emit(record, "Cancel", now, sample)
				end
				Attributes.Set(humanoid, "SACharging", false)
			end
			if simulateAbilities then
				Attributes.Set(humanoid, "SAActiveAbility", "")
				Attributes.Set(humanoid, "SAAbilityAnimation", "")
			end
			if simulateAttacks then
				Attributes.Set(humanoid, "SAReleasedAt", nil)
			end
			continue
		end
		local active = Attributes.Get(humanoid, "SAActiveAbility") :: string?
		if
			simulateAbilities and active ~= nil and active ~= ""
			and now >= ((Attributes.Get(humanoid, "SAAbilityEndsAt") :: number?) or 0)
		then
			Attributes.Set(humanoid, "SAActiveAbility", "")
		end
		if
			simulateAttacks and sample.Attack and not wasAttack and Attributes.Get(humanoid, "SACharging") ~= true
			and now >= ((Attributes.Get(humanoid, "SAAttackReadyAt") :: number?) or 0)
			and (Attributes.Get(humanoid, "SAActiveAbility") :: string?) ~= "Charge"
		then
			Attributes.Set(humanoid, "SAAttackId", ((Attributes.Get(humanoid, "SAAttackId") :: number?) or 0) + 1)
			Attributes.Set(humanoid, "SAChargeStarted", now)
			Attributes.Set(humanoid, "SAReleasedAt", nil)
			Attributes.Set(humanoid, "SAAttackWeapon", Attributes.Get(root, "SAEquippedWeapon"))
			Attributes.Set(humanoid, "SAAttackEquipment", actor:GetAttribute("WeaponRevision"))
			Attributes.Set(
				humanoid,
				"SAAttackType",
				if humanoid.FloorMaterial == Enum.Material.Air then "JumpAttack" else "Attack"
			)
			Attributes.Set(humanoid, "SACharging", true)
			Emit(record, "Start", now, sample)
		end
		local autoRelease = not WeaponConfig.ChargedJumpAttack.Enable
			and Attributes.Get(humanoid, "SAAttackType") == "JumpAttack"
		if
			simulateAttacks and Attributes.Get(humanoid, "SACharging") == true
			and ((not sample.Attack and wasAttack) or autoRelease)
		then
			Attributes.Set(humanoid, "SACharging", false)
			Attributes.Set(humanoid, "SAAttackReleased", Attributes.Get(humanoid, "SAAttackId") :: number?)
			Attributes.Set(humanoid, "SAReleasedAt", now)
			local weapon = Attributes.Get(root, "SAEquippedWeapon") :: string
			local config = WeaponConfig.BaseWeapons[weapon]
			if simulateAttackCooldowns and config then
				local scale = if actor:GetAttribute("TimeStopActive") == true
					then Abilities.Abilities.TimeStop.AttackCooldownScale
					else 1
				Attributes.Set(humanoid, "SAAttackReadyAt", now + config.Cooldown * scale)
			end
			Emit(record, "Release", now, sample)
		end
		local flatAim = Vector3.new(sample.Aim.X, 0, sample.Aim.Z)
		local needsFlatAim = equippedAbility == "Charge"
			or equippedAbility == "Throw"
			or equippedAbility == "Push"
			or equippedAbility == "Pull"
		local eligible = (not needsFlatAim or flatAim.Magnitude > 0.001)
			and (equippedAbility ~= "Smash" or humanoid.FloorMaterial ~= Enum.Material.Air)
		if
			simulateAbilities and eligible and sample.Ability and not wasAbility
			and Attributes.Get(humanoid, "SACharging") ~= true
			and now >= ((Attributes.Get(humanoid, "SAAbilityReadyAt") :: number?) or 0)
			and Attributes.Get(root, "SAAbilityAllowed") == true and sample.Aim.Magnitude > 0
		then
			local name = Attributes.Get(root, "SAEquippedAbility") :: string
			local config = Abilities.Abilities[name]
			if config then
				Attributes.Set(humanoid, "SAAbilityId", ((Attributes.Get(humanoid, "SAAbilityId") :: number?) or 0) + 1)
				Attributes.Set(humanoid, "SAActiveAbility", name)
				Attributes.Set(humanoid, "SAAbilityAnimation", name)
				Attributes.Set(humanoid, "SAAbilityStarted", now)
				local aim = if name == "Dash" and sample.Steer.Magnitude > 0.001 then sample.Steer.Unit else sample.Aim
				if name == "Dash" and Vector3.new(aim.X, 0, aim.Z).Magnitude <= 0.001 then
					aim = root.CFrame.LookVector
				end
				Attributes.Set(humanoid, "SAAbilityAim", aim)
				Attributes.Set(humanoid, "SAChargeDirection", nil)
				Attributes.Set(humanoid, "SAAbilityStartY", root.Position.Y)
				local duration = config.Duration or 0.2
				Attributes.Set(humanoid, "SAAbilityEndsAt", now + duration)
				Attributes.Set(humanoid, "SAAbilityReadyAt", now + (config.Cooldown or 0))
				Attributes.Set(humanoid, "SACD" .. name, now + (config.Cooldown or 0))
				Attributes.Set(humanoid, "SASmashImpact", false)
				Attributes.Set(humanoid, "SASmashImpactAt", nil)
				Emit(record, "Ability", now, sample)
			end
		end
		if simulateAttacks and Attributes.Get(humanoid, "SACharging") == true then
			local held = now - ((Attributes.Get(humanoid, "SAChargeStarted") :: number?) or now)
			Attributes.Set(humanoid, "SAChargeStrength", math.clamp(held / GameConfig.Combat.MaxChargeTime, 0, 1))
		end
		if
			simulateAbilities and Attributes.Get(humanoid, "SASmashImpact") == true
			and (Attributes.Get(humanoid, "SASmashCommittedId") :: number?) ~= (Attributes.Get(humanoid, "SAAbilityId") :: number?)
		then
			Attributes.Set(humanoid, "SASmashCommittedId", Attributes.Get(humanoid, "SAAbilityId") :: number?)
			Emit(record, "SmashImpact", now, sample)
		end
	end
end

function Combat.Drain()
	local events = Events
	Events = {}
	return events
end

return Combat
