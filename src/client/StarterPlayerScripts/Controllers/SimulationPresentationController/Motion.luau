--!strict
-- Projects completed Cartoon samples for presentation without running collision or gameplay logic.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local State = require(ReplicatedStorage.Knockback.State)
local CartoonMotion = require(ReplicatedStorage.Knockback.CartoonMotion)

--// Constants
local PROJECTION_LIMIT = 0.1

--// Types
export type Sample = {
	At: number,
	Session: number,
	Impact: number,
	Phase: string,
	Center: Vector3,
	Frame: CFrame,
	Velocity: Vector3,
	SupportVelocity: Vector3,
	Gravity: number,
}
export type Motion = {
	Capture: (BasePart, Sample?) -> Sample?,
	Frame: (Sample, number, boolean) -> CFrame,
	Discontinuous: (Sample, Sample) -> boolean,
}

--// Controller
local Motion: Motion = {} :: Motion

--// APIs
function Motion.Capture(root, previous)
	if Attributes.Get(root, "KBActive") ~= true then
		return nil
	end
	local at = Attributes.Get(root, "KBMotionAt") :: number?
	if not at then
		return nil
	end
	if
		previous
		and previous.At == at
		and previous.Session == Attributes.Get(root, "KBSession")
		and previous.Impact == Attributes.Get(root, "KBImpactId")
		and previous.Phase == Attributes.Get(root, "KBPhase")
		and previous.Center == (Attributes.Get(root, "KBPosition") :: Vector3?)
		and previous.Velocity == (Attributes.Get(root, "KBVelocity") :: Vector3?)
		and previous.SupportVelocity == (Attributes.Get(root, "KBSupportVelocity") :: Vector3?)
	then
		return previous
	end
	local state = State.Read(root)
	if not state then
		return nil
	end
	return {
		At = at,
		Session = Attributes.Get(root, "KBSession") :: number,
		Impact = state.impactId,
		Phase = state.phase,
		Center = state.position,
		Frame = CartoonMotion.RootFrame(state),
		Velocity = state.velocity,
		SupportVelocity = state.supportVelocity,
		Gravity = state.gravity,
	}
end

function Motion.Frame(sample, now, frozen)
	local elapsed = if frozen then 0 else math.clamp(now - sample.At, 0, PROJECTION_LIMIT)
	if sample.Phase == "Stun" then
		return sample.Frame
	end
	local displacement = (sample.Velocity + sample.SupportVelocity) * elapsed
	if sample.Phase == "Fly" or sample.Phase == "Bounce" then
		displacement -= Vector3.yAxis * (sample.Gravity * elapsed * elapsed * 0.5)
	end
	return sample.Frame + displacement
end

function Motion.Discontinuous(previous, current)
	return current.At < previous.At
		or current.Session ~= previous.Session
		or current.Impact ~= previous.Impact
		or current.Phase ~= previous.Phase
end

return Motion
