--!strict
-- Applies custom movement from replayable input and tracked actor state on both peers.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local State = require(script.Parent.State)
local Input = require(script.Parent.Input)
local Abilities = require(ReplicatedStorage.SharedModules.AbilityConfig)
local Config = require(ReplicatedStorage.SharedModules.GameConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local KnockbackState = require(ReplicatedStorage.Knockback.State)
local Motion = require(ReplicatedStorage.Knockback.CartoonMotion)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local ClientSimulation = SimulationConfig.ClientSimulation

--// Types
export type Movement = {
	-- Applies input-driven movement and ability motion; active drop paths belong to ActorTimelines.
	Step: (number, number) -> (),
}

--// Properties
-- TweenService is sampled once outside simulation; replay only interpolates immutable values.
local EasingSamples: { number } = {}
for index = 0, 128 do
	EasingSamples[index + 1] = TweenService:GetValue(
		index / 128,
		WeaponConfig.ChargedJumpAttack.EasingStyle,
		WeaponConfig.ChargedJumpAttack.EasingDirection
	)
end

--// Controller
local Movement: Movement = {} :: Movement

--// APIs
function Movement.Step(dt, now)
	for _, record in State.Records do
		if not record.Ready then
			continue
		end
		local humanoid = record.Humanoid
		if not humanoid or not record.Alive then
			continue
		end
		local root, actor = record.Root, record.Actor
		local simulateLocalPlayer = not IsServer and record.Owner == LocalPlayer
		local movement = ClientSimulation.LocalPlayer.Movement
		local abilityMovement = ClientSimulation.LocalPlayer.AbilityMovement
		if
			not IsServer
			and (
				(record.Owner ~= nil and record.Owner ~= LocalPlayer)
				or RunService:GetPredictionStatus(root) ~= Enum.PredictionStatus.Predicted
			)
		then
			continue
		end
		local sample = if record.Owner then Input.Read(record.Owner) else nil
		local jumping = sample ~= nil and sample.Jump
		local jumpEdge = jumping and Attributes.Get(humanoid, "SAWasJump") ~= true
		Attributes.Set(humanoid, "SAWasJump", jumping)
		-- The independent actor timeline callback owns the anchored drop path and completion.
		if Attributes.Get(root, "SADropAt") ~= nil then
			continue
		end
		local frozen = actor:GetAttribute("IsFrozen") == true or actor:GetAttribute("TimeStopped") == true
		local locked = frozen
			or actor:GetAttribute("MovementLocked") == true
			or Attributes.Get(root, "KBActive") == true
		if locked then
			humanoid.WalkSpeed, humanoid.JumpHeight = 0, 0
			humanoid.Jump = false
			if frozen then root.AssemblyLinearVelocity = Vector3.zero end
			if
				jumpEdge and record.Owner and not frozen and actor:GetAttribute("MovementLocked") ~= true
				and (not simulateLocalPlayer or movement.KnockbackRecoveryJump)
			then
				local motion = KnockbackState.Read(root)
				if
					motion
					and motion.profile.FlyTimeoutRequiresJump
					and motion.profile.FlyTimeout > 0
					and motion.flyTime >= motion.profile.FlyTimeout
					and Motion.IsAirborne(motion)
					and motion.position.Y >= Config.VoidHeight
				then
					Attributes.Set(root, "KBRecoveryRequested", true)
					Attributes.Set(root, "KBActive", false)
					root.Anchored = Attributes.Get(root, "KBBeforeAnchored") == true
					root.AssemblyLinearVelocity = Vector3.new(
						motion.velocity.X,
						math.sqrt(2 * Workspace.Gravity * Config.Movement.JumpHeight),
						motion.velocity.Z
					)
					humanoid.WalkSpeed, humanoid.JumpHeight = Config.Movement.WalkSpeed, Config.Movement.JumpHeight
					Attributes.Set(humanoid, "SAAirJumpUsed", false)
					Attributes.Set(humanoid, "SAJumpKind", "Recovery")
					Attributes.Set(humanoid, "SALastJump", now)
				end
			end
			continue
		end
		humanoid.WalkSpeed, humanoid.JumpHeight = Config.Movement.WalkSpeed, Config.Movement.JumpHeight
		local airborne = humanoid.FloorMaterial == Enum.Material.Air
		if not airborne then
			Attributes.Set(humanoid, "SAAirJumpUsed", false)
			Attributes.Set(humanoid, "SAWallJumps", 0)
		end
		local params = RaycastParams.new()
		params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, { actor }
		params.RespectCanCollide = true
		local wall = if airborne and (not simulateLocalPlayer or movement.WallJumpAndSlide)
			then Workspace:Raycast(root.Position, root.CFrame.LookVector * 2.2, params)
			else nil
		local wallSlide = (not simulateLocalPlayer or movement.WallJumpAndSlide) and wall ~= nil
			and wall.Instance:GetAttribute("SAWallJumpAllowed") ~= false
			and ((Attributes.Get(humanoid, "SAWallJumps") :: number?) or 0) < Config.Movement.MaxWallJumps
			and Attributes.Get(root, "SACombatAllowed") == true
		if wallSlide and root.AssemblyLinearVelocity.Y < -5 then
			local velocity = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(velocity.X, -5, velocity.Z)
		end
		if jumpEdge and now - ((Attributes.Get(humanoid, "SALastJump") :: number?) or -1) >= 0.2 then
			local kind: string? = nil
			local velocity = root.AssemblyLinearVelocity
			local speed = math.sqrt(2 * Workspace.Gravity * Config.Movement.JumpHeight)
			if wallSlide and wall then
				local normal = Vector3.new(wall.Normal.X, 0, wall.Normal.Z)
				if normal.Magnitude > 0.001 then
					kind = "Wall"
					root.AssemblyLinearVelocity = normal.Unit * Config.Movement.WalkSpeed * 0.75 + Vector3.yAxis * speed * 1.15
					Attributes.Set(
						humanoid,
						"SAWallJumps",
						((Attributes.Get(humanoid, "SAWallJumps") :: number?) or 0) + 1
					)
					Attributes.Set(humanoid, "SAAirJumpUsed", false)
				end
			elseif not airborne and (not simulateLocalPlayer or movement.GroundJump) then
				kind = "Ground"
				humanoid.Jump = true
			elseif
				airborne and (not simulateLocalPlayer or movement.AirJump)
				and Attributes.Get(humanoid, "SAAirJumpUsed") ~= true
			then
				kind = "Air"
				root.AssemblyLinearVelocity = Vector3.new(velocity.X, speed, velocity.Z)
				Attributes.Set(humanoid, "SAAirJumpUsed", true)
			end
			if kind then
				Attributes.Set(humanoid, "SALastJump", now)
				Attributes.Set(humanoid, "SAJumpKind", kind)
			end
		end
		local simulateFacing = if simulateLocalPlayer
			then movement.FacingRotation
			else IsServer or ClientSimulation.NPCs.FacingFromServerIntent or actor:GetAttribute(
				"KnockbackActorKind"
			) ~= "NPC"
		if simulateFacing then
			if sample and sample.Facing.Magnitude > 0.001 then
				local direction = Vector3.new(sample.Facing.X, 0, sample.Facing.Z)
				if direction.Magnitude > 0.001 then
					humanoid.AutoRotate = false
					root.CFrame = root.CFrame:Lerp(
						CFrame.lookAt(root.Position, root.Position + direction.Unit),
						1 - math.exp(-SimulationConfig.FacingResponsiveness * dt)
					)
				end
			else
				humanoid.AutoRotate = true
			end
		end
		local charge = WeaponConfig.ChargedJumpAttack
		if
			charge.Enable
			and (not simulateLocalPlayer or ClientSimulation.LocalPlayer.Combat.AttackChargeAndRelease)
			and Attributes.Get(humanoid, "SACharging") == true
			and Attributes.Get(humanoid, "SAAttackType") == "JumpAttack"
		then
			local held = now - ((Attributes.Get(humanoid, "SAChargeStarted") :: number?) or now)
			if held >= charge.MinHoldTime then
				local progress = if charge.StopTime > 0
					then math.clamp((held - charge.MinHoldTime) / charge.StopTime, 0, 1)
					else 1
				local index = math.min(127, math.floor(progress * 128))
				local fraction = progress * 128 - index
				local eased = math.clamp(
					EasingSamples[index + 1] + (EasingSamples[index + 2] - EasingSamples[index + 1]) * fraction,
					0,
					1
				)
				humanoid.WalkSpeed = Config.Movement.WalkSpeed * (1 - eased)
			end
		end
		if not sample then
			local direction = Attributes.Get(root, "SANpcDirection") :: Vector3?
			if
				direction
				and (
					IsServer
					or ClientSimulation.NPCs.WalkingFromServerIntent
					or actor:GetAttribute("KnockbackActorKind") ~= "NPC"
				)
			then
				humanoid:Move(direction, false)
			end
			continue
		end
		local ability = Attributes.Get(humanoid, "SAActiveAbility") :: string?
		local elapsed = now - ((Attributes.Get(humanoid, "SAAbilityStarted") :: number?) or now)
		local aim = Attributes.Get(humanoid, "SAAbilityAim") :: Vector3?
		if
			(not simulateLocalPlayer or movement.FacingRotation) and aim
			and (ability == "Throw" or ability == "Push" or ability == "Pull" or ability == "Charge")
		then
			local direction = Vector3.new(aim.X, 0, aim.Z)
			if
				direction.Magnitude > 0.001
				and Attributes.Get(humanoid, "SAAbilityFacedId") ~= Attributes.Get(humanoid, "SAAbilityId")
			then
				root.CFrame = CFrame.lookAt(root.Position, root.Position + direction.Unit)
				Attributes.Set(humanoid, "SAAbilityFacedId", Attributes.Get(humanoid, "SAAbilityId"))
			end
		end
		local velocity = root.AssemblyLinearVelocity
		if ability == "Dash" and aim and (not simulateLocalPlayer or abilityMovement.Dash) then
			local config = Abilities.Abilities.Dash
			local direction = Vector3.new(aim.X, 0, aim.Z)
			if direction.Magnitude > 0.001 then root.AssemblyLinearVelocity = direction.Unit * config.Velocity end
		elseif
			ability == "MegaJump" and (not simulateLocalPlayer or abilityMovement.MegaJump)
			and Attributes.Get(humanoid, "SAMegaJumpId") ~= Attributes.Get(humanoid, "SAAbilityId")
		then
			Attributes.Set(humanoid, "SAMegaJumpId", Attributes.Get(humanoid, "SAAbilityId"))
			root.AssemblyLinearVelocity = Vector3.new(velocity.X, Abilities.Abilities.MegaJump.Force, velocity.Z)
		elseif ability == "Charge" and aim and (not simulateLocalPlayer or abilityMovement.ChargeSteering) then
			local config = Abilities.Abilities.Charge
			local previousDirection = Attributes.Get(humanoid, "SAChargeDirection") :: Vector3?
			local initial = Vector3.new(aim.X, 0, aim.Z)
			if initial.Magnitude <= 0.001 then
				initial = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			end
			local direction = if previousDirection and elapsed >= dt * 1.5 then previousDirection else initial.Unit
			local wanted = Vector3.new(sample.Aim.X, 0, sample.Aim.Z)
			if wanted.Magnitude > 0.001 then
				local angle = math.atan2(direction:Cross(wanted.Unit).Y, direction:Dot(wanted.Unit))
				direction = CFrame.fromAxisAngle(Vector3.yAxis, math.clamp(angle, -math.rad(config.TurnRate) * dt, math.rad(config.TurnRate) * dt)):VectorToWorldSpace(direction)
			end
			Attributes.Set(humanoid, "SAChargeDirection", direction)
			local remaining = config.Duration - elapsed
			humanoid.WalkSpeed = if remaining < config.SlowDown
				then Config.Movement.WalkSpeed + (config.RunSpeed - Config.Movement.WalkSpeed) * (remaining / config.SlowDown)^2
				else config.RunSpeed
			humanoid:Move(direction, false)
		elseif ability == "Smash" and (not simulateLocalPlayer or abilityMovement.SmashRiseAndDive) then
			local config = Abilities.Abilities.Smash
			local upTime = (config.ImpactTime - config.DiveAnimTime) / config.RiseSpeed
			local riseTime = upTime * config.RiseFraction
			local steer = sample.Steer
			if elapsed < upTime then
				local function height(t: number): number
					if t < riseTime then return config.JumpHeight * (1 - (1 - t/riseTime)^2.2) end
					return config.JumpHeight + math.sin((t-riseTime)*3)*0.35*math.min(t-riseTime,1)
				end
				local desired = ((Attributes.Get(humanoid, "SAAbilityStartY") :: number?) or root.Position.Y)
					+ height(elapsed)
				local feedForward = (height(elapsed + dt) - height(elapsed)) / dt
				root.AssemblyLinearVelocity = Vector3.new(steer.X * config.HangSteer, math.clamp(feedForward + (desired-root.Position.Y)*10,-120,120), steer.Z * config.HangSteer)
			else
				local stand = humanoid.HipHeight + root.Size.Y / 2 + (if record.R6 then 2 else 0)
				local hit = Workspace:Raycast(root.Position, -Vector3.yAxis * (stand+2.6), params)
				if hit then
					Attributes.Set(humanoid, "SASmashImpact", true)
					Attributes.Set(humanoid, "SASmashImpactAt", now)
					Attributes.Set(humanoid, "SASmashPosition", hit.Position)
					Attributes.Set(humanoid, "SAActiveAbility", "")
					root.AssemblyLinearVelocity = Vector3.zero
				else
					local floor = Workspace:Raycast(root.Position, -Vector3.yAxis*400, params)
					local distance = if floor then math.max(0,root.Position.Y-floor.Position.Y-stand) else 60
					local remaining = config.DiveAnimTime/config.DiveSpeed - (elapsed-upTime)
					local speed = math.clamp(if remaining>0.03 then distance/remaining else config.SlamSpeed,40,config.SlamSpeed*1.4)
					root.AssemblyLinearVelocity = Vector3.new(steer.X*config.SteerSpeed,-speed,steer.Z*config.SteerSpeed)
				end
			end
		end
	end
end

return Movement
