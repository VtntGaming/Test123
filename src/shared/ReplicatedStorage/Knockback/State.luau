--!strict
-- Serializes every solver input into tracked attributes so prediction can rewind without private state history.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Motion = require(script.Parent.CartoonMotion)
local SimulationState = require(ReplicatedStorage.Simulation.State)
local Combat = require(ReplicatedStorage.Combat)
local WeaponProfiles = require(ReplicatedStorage.Config.Weapon)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local ClientSimulation = SimulationConfig.ClientSimulation
local Profiles = Motion.ValidateProfiles(WeaponProfiles)

--// Types
export type Presentation = {
	generation: string,
	revision: number,
	weaponId: string,
	phase: string,
	phaseTime: number,
	presentedTime: number,
	timestamp: number,
	bootstrap: boolean,
	impacts: { Combat.ReactionImpact },
	consumedImpactId: number,
}
export type State = {
	Read: (BasePart, boolean?) -> Motion.State?,
	Write: (BasePart, Motion.State) -> (),
	Begin: (BasePart, Motion.State, number, number, boolean, boolean, boolean?) -> (),
	Step: (number, number) -> (),
	Present: (BasePart) -> Presentation?,
}

--// Properties
local Names: { string } = {}
for name in Profiles do
	table.insert(Names, name)
end
table.sort(Names)

--// Controller
local State: State = {} :: State

--// APIs
local function IsBag(root: BasePart): boolean
	return bit32.band((Attributes.Get(root, "KBFlags") :: number?) or 0, 1) ~= 0
end
function State.Read(root, includeInactive)
	if Attributes.Get(root, "KBProfile") == nil or (Attributes.Get(root, "KBActive") ~= true and not includeInactive) then
		return nil
	end
	-- Separate carriers may arrive at different times during initial replication or streaming.
	local session = Attributes.Get(root, "KBSession")
	if
		type(session) ~= "number"
		or Attributes.Get(root, "KBMotionSession") ~= session
		or Attributes.Get(root, "KBSupportSession") ~= session
		or Attributes.Get(root, "KBImpactSession") ~= session
	then
		return nil
	end
	local name = Names[Attributes.Get(root, "KBProfile") :: number]
	local profile = table.clone(Profiles[name])
	local strength = Attributes.Get(root, "KBStrength") :: number
	profile.HorizontalSpeed *= strength
	profile.LaunchHeight *= strength
	profile.TimeToApex *= math.sqrt(strength)
	if IsBag(root) then
		profile.FlyVisualOffset, profile.RestVisualOffset, profile.FlyTimeout = Vector3.zero, Vector3.zero, 0
		if bit32.band((Attributes.Get(root, "KBFlags") :: number?) or 0, 2) ~= 0 then
			profile.HorizontalSpeed, profile.RestDuration, profile.GroundBounceCount, profile.WallBounceCount =
				0, 0, 0, 0
		end
	elseif bit32.band((Attributes.Get(root, "KBFlags") :: number?) or 0, 4) ~= 0 then
		profile.FlyTimeoutRequiresJump = true
	end
	local impactId = Attributes.Get(root, "KBImpactId") :: number
	local impacts: { Combat.ReactionImpact } = {}
	if impactId > 0 then
		table.insert(impacts, {
			id = impactId,
			time = Attributes.Get(root, "KBImpactTime") :: number,
			normal = Attributes.Get(root, "KBImpactNormal") :: Vector3,
			outcome = Attributes.Get(root, "KBImpactOutcome") :: string,
			category = Combat.Reaction.Classify(
				CFrame.new(Attributes.Get(root, "KBPosition") :: Vector3) * (Attributes.Get(root, "KBHeading") :: CFrame),
				Attributes.Get(root, "KBImpactNormal") :: Vector3,
				nil,
				Attributes.Get(root, "KBImpactPosition") :: Vector3?
			),
			contactPosition = Attributes.Get(root, "KBImpactPosition") :: Vector3?,
			restDirection = Attributes.Get(root, "KBRestDirection") :: Vector3?,
		})
	end
	return {
		root = root,
		profile = profile,
		weaponId = name,
		position = Attributes.Get(root, "KBPosition") :: Vector3,
		velocity = Attributes.Get(root, "KBVelocity") :: Vector3,
		radius = Attributes.Get(root, "KBRadius") :: number,
		gravity = Attributes.Get(root, "KBGravity") :: number,
		heading = Attributes.Get(root, "KBHeading") :: CFrame,
		rootToTorso = Attributes.Get(root, "KBRootToTorso") :: Vector3,
		phase = Attributes.Get(root, "KBPhase") :: string,
		stunUntil = Attributes.Get(root, "KBStunUntil") :: number,
		launchVelocity = Attributes.Get(root, "KBLaunchVelocity") :: Vector3,
		stunOffset = Attributes.Get(root, "KBStunOffset") :: CFrame,
		groundBounces = Attributes.Get(root, "KBGroundBounces") :: number,
		wallBounces = Attributes.Get(root, "KBWallBounces") :: number,
		restTime = Attributes.Get(root, "KBRestTime") :: number,
		flyTime = Attributes.Get(root, "KBFlyTime") :: number,
		support = SimulationState.Surface((Attributes.Get(root, "KBSupportId") :: number?) or 0),
		supportFrame = Attributes.Get(root, "KBSupportFrame") :: CFrame?,
		supportLocal = Attributes.Get(root, "KBSupportLocal") :: Vector3?,
		supportSize = Attributes.Get(root, "KBSupportSize") :: Vector3?,
		supportNormal = Attributes.Get(root, "KBSupportNormal") :: Vector3,
		supportVelocity = Attributes.Get(root, "KBSupportVelocity") :: Vector3,
		lastSafe = Attributes.Get(root, "KBLastSafe") :: Vector3?,
		changed = false,
		contactsLeft = 3,
		impacts = impacts,
		impactId = impactId,
		stepTime = time(),
		events = {},
	}
end

function State.Write(root, state)
	Attributes.Set(root, "KBMotionAt", state.stepTime)
	Attributes.Set(root, "KBPosition", state.position)
	Attributes.Set(root, "KBVelocity", state.velocity)
	Attributes.Set(root, "KBRadius", state.radius)
	Attributes.Set(root, "KBGravity", state.gravity)
	Attributes.Set(root, "KBHeading", state.heading)
	Attributes.Set(root, "KBRootToTorso", state.rootToTorso)
	if Attributes.Get(root, "KBPhase") ~= state.phase then
		Attributes.Set(root, "KBPhaseTime", state.stepTime)
	end
	Attributes.Set(root, "KBPhase", state.phase)
	Attributes.Set(root, "KBStunUntil", state.stunUntil)
	Attributes.Set(root, "KBLaunchVelocity", state.launchVelocity)
	Attributes.Set(root, "KBStunOffset", state.stunOffset)
	Attributes.Set(root, "KBGroundBounces", state.groundBounces)
	Attributes.Set(root, "KBWallBounces", state.wallBounces)
	Attributes.Set(root, "KBRestTime", state.restTime)
	Attributes.Set(root, "KBFlyTime", state.flyTime)
	Attributes.Set(root, "KBSupportId", if state.support then state.support:GetAttribute("SASurfaceId") else 0)
	Attributes.Set(root, "KBSupportFrame", state.supportFrame)
	Attributes.Set(root, "KBSupportLocal", state.supportLocal)
	Attributes.Set(root, "KBSupportSize", state.supportSize)
	Attributes.Set(root, "KBSupportNormal", state.supportNormal)
	Attributes.Set(root, "KBSupportVelocity", state.supportVelocity)
	Attributes.Set(root, "KBLastSafe", state.lastSafe)
	Attributes.Set(root, "KBImpactId", state.impactId)
	local latest = state.impacts[#state.impacts]
	if latest then
		Attributes.Set(root, "KBImpactTime", latest.time)
		Attributes.Set(root, "KBImpactNormal", latest.normal)
		Attributes.Set(root, "KBImpactOutcome", latest.outcome)
		Attributes.Set(root, "KBImpactPosition", latest.contactPosition)
		Attributes.Set(root, "KBRestDirection", latest.restDirection)
	end
end

function State.Begin(root, state, session, strength, bag, idle, npc)
	Attributes.Set(root, "KBPauseAt", nil)
	Attributes.Set(root, "KBPausedTime", 0)
	Attributes.Set(root, "KBProfile", table.find(Names, state.weaponId))
	Attributes.Set(root, "KBStrength", strength)
	Attributes.Set(root, "KBFlags", (if bag then 1 else 0) + (if idle then 2 else 0) + (if npc then 4 else 0))
	Attributes.Set(root, "KBSession", session)
	Attributes.Set(root, "KBFinished", false)
	Attributes.Set(root, "KBFinishReason", nil)
	Attributes.Set(root, "KBRecoveryRequested", false)
	Attributes.Set(root, "KBBagCheckAt", 0)
	State.Write(root, state)
	Attributes.Set(root, "KBMotionSession", session)
	Attributes.Set(root, "KBSupportSession", session)
	Attributes.Set(root, "KBImpactSession", session)
	Attributes.Set(root, "KBActive", true)
end

function State.Step(dt, now)
	for _, record in SimulationState.Records do
		if not record.Ready then
			continue
		end
		if not IsServer then
			if record.Owner == LocalPlayer and not ClientSimulation.LocalPlayer.CartoonMotion then
				continue
			end
			if not ClientSimulation.NPCs.CartoonMotion and record.Actor:GetAttribute("KnockbackActorKind") == "NPC" then
				continue
			end
		end
		local root = record.Root
		if
			not root.Parent
			or (not IsServer and RunService:GetPredictionStatus(root) ~= Enum.PredictionStatus.Predicted)
		then
			continue
		end
		local state = State.Read(root)
		if not state and Attributes.Get(root, "KBActive") == true then
			continue
		end
		for _, part in record.Parts do
			if state then
				part.CanCollide, part.CanQuery, part.CanTouch = false, false, false
			else
				local collide = part:GetAttribute("SAPreCollide")
				local query = part:GetAttribute("SAPreQuery")
				local touch = part:GetAttribute("SAPreTouch")
				if type(collide) == "boolean" and type(query) == "boolean" and type(touch) == "boolean" then
					part.CanCollide = false
					part.CanQuery, part.CanTouch = query, touch
					part.CanCollide = collide
					part:SetAttribute("SAPreCollide", nil)
					part:SetAttribute("SAPreQuery", nil)
					part:SetAttribute("SAPreTouch", nil)
				end
			end
		end
		if not state or Attributes.Get(root, "KBFinished") == true then
			continue
		end
		root.Anchored = true
		local pauseAt = Attributes.Get(root, "KBPauseAt") :: number?
		if record.Actor:GetAttribute("TimeStopped") == true then
			if pauseAt == nil then
				Attributes.Set(root, "KBPauseAt", now)
			end
			root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			continue
		elseif pauseAt ~= nil then
			local paused = math.max(0, now - pauseAt)
			state.stunUntil += paused
			Attributes.Set(root, "KBStunUntil", state.stunUntil)
			Attributes.Set(root, "KBPhaseTime", ((Attributes.Get(root, "KBPhaseTime") :: number?) or now) + paused)
			Attributes.Set(root, "KBPausedTime", ((Attributes.Get(root, "KBPausedTime") :: number?) or 0) + paused)
			Attributes.Set(root, "KBPauseAt", nil)
		end
		if IsBag(root) and state.phase == "Rest" then
			local support = state.support
			if
				support
				and support.Parent
				and support.CanCollide
				and support.CFrame == state.supportFrame
				and support.Size == state.supportSize
				and now < ((Attributes.Get(root, "KBBagCheckAt") :: number?) or 0)
			then
				continue
			end
			Attributes.Set(root, "KBBagCheckAt", now + 0.5)
		end
		local complete, reason = Motion.Step(state, dt, now)
		if IsBag(root) and state.phase == "Rest" then
			state.restTime = math.min(state.restTime, state.profile.RestDuration)
		end
		State.Write(root, state)
		root.CFrame = Motion.RootFrame(state)
		if complete and not IsBag(root) then
			Attributes.Set(root, "KBFinished", true)
			Attributes.Set(root, "KBFinishReason", reason or "Recovered")
		end
	end
end

function State.Present(root)
	local state = State.Read(root)
	if not state then
		return nil
	end
	local actor = root.Parent
	return {
		generation = (if actor then actor:GetAttribute("RagdollGeneration") :: string? else nil) :: string,
		revision = Attributes.Get(root, "KBSession") :: number,
		weaponId = state.weaponId,
		phase = state.phase,
		phaseTime = (Attributes.Get(root, "KBPhaseTime") :: number?) or state.stepTime,
		presentedTime = time(),
		timestamp = time(),
		bootstrap = false,
		impacts = state.impacts,
		consumedImpactId = 0,
	}
end

return State
