--!strict
-- Evaluates presentation smoothing explicitly per render frame without allocating tweens or Value objects.
-- Scripted facing uses exponential interpolation; reconciliation retains SmoothDamp velocity between updates.

--// Services
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Diagnostics = require(ReplicatedStorage.Simulation.Diagnostics)

--// Types
export type Offset = {
	-- Visual translation/rotation error relative to the current predicted display target.
	Value: CFrame,
	-- World-space damping velocity retained while correcting position.
	PositionVelocity: Vector3,
	-- Angular damping velocity for the shortest yaw error, in radians per second.
	YawVelocity: number,
	-- Native damping velocity for non-yaw rotational errors.
	TiltVelocity: CFrame,
	-- Whether accumulated position error has crossed its start threshold and has not reached its stop threshold.
	PositionActive: boolean,
	-- Whether accumulated yaw error has crossed its start threshold and has not reached its stop threshold.
	YawActive: boolean,
}
export type Deadzone = {
	-- Position error in studs required to begin correction.
	PositionStart: number,
	-- Position error in studs at which correction stops and holds the residual; smaller than PositionStart.
	PositionStop: number,
	-- Absolute yaw error in degrees required to begin correction.
	YawStartDegrees: number,
	-- Absolute yaw error in degrees at which correction stops and holds the residual; smaller than YawStartDegrees.
	YawStopDegrees: number,
}
export type Smoothing = {
	-- Creates an identity-valued reconciliation offset with zero native damping velocity.
	NewOffset: () -> Offset,
	-- Removes the current error and momentum for teleports, freezes and ownership changes.
	Reset: (Offset) -> (),
	-- Replaces the visual error while preserving its damping velocity across reconciliation updates.
	Rebase: (Offset, CFrame) -> (),
	-- Removes yaw correction and its momentum while retaining position and pitch/roll correction.
	ClearYaw: (Offset) -> (),
	-- Damps active channels using render dt and hysteresis, holding inactive residuals; nonpositive smooth time resets all error.
	Step: (Offset, number, number, Deadzone) -> (),
	-- Returns whether a cosmetic offset must remain applied, including held subthreshold residuals.
	HasOffset: (Offset) -> boolean,
	-- Follows a live facing target using a frame-rate-independent exponential response per second.
	Facing: (CFrame, CFrame, number, number) -> CFrame,
}

--// Controller
local Smoothing: Smoothing = {} :: Smoothing

--// APIs
function Smoothing.NewOffset()
	return {
		Value = CFrame.identity,
		PositionVelocity = Vector3.zero,
		YawVelocity = 0,
		TiltVelocity = CFrame.identity,
		PositionActive = false,
		YawActive = false,
	}
end

function Smoothing.Reset(offset)
	offset.Value = CFrame.identity
	offset.PositionVelocity, offset.YawVelocity, offset.TiltVelocity = Vector3.zero, 0, CFrame.identity
	offset.PositionActive, offset.YawActive = false, false
end

function Smoothing.Rebase(offset, value)
	Diagnostics.Correction(value)
	offset.Value = value
end

function Smoothing.ClearYaw(offset)
	local direction = offset.Value.LookVector
	local yaw = math.atan2(-direction.X, -direction.Z)
	local tilt = CFrame.Angles(0, yaw, 0):ToObjectSpace(offset.Value.Rotation)
	offset.Value = CFrame.new(offset.Value.Position) * tilt
	offset.YawVelocity, offset.YawActive = 0, false
end

function Smoothing.Step(offset, smoothTime, dt, deadzone)
	if smoothTime <= 0 then
		Smoothing.Reset(offset)
	elseif dt > 0 then
		local position = offset.Value.Position
		local direction = offset.Value.LookVector
		local yaw = math.atan2(-direction.X, -direction.Z)
		local tilt = CFrame.Angles(0, yaw, 0):ToObjectSpace(offset.Value.Rotation)
		if offset.PositionActive then
			if position.Magnitude <= deadzone.PositionStop then
				offset.PositionActive = false
				offset.PositionVelocity = Vector3.zero
			end
		elseif position.Magnitude >= deadzone.PositionStart then
			offset.PositionActive = true
		end
		if offset.YawActive then
			if math.abs(yaw) <= math.rad(deadzone.YawStopDegrees) then
				offset.YawActive = false
				offset.YawVelocity = 0
			end
		elseif math.abs(yaw) >= math.rad(deadzone.YawStartDegrees) then
			offset.YawActive = true
		end
		if offset.PositionActive then
			position, offset.PositionVelocity =
				TweenService:SmoothDamp(position, Vector3.zero, offset.PositionVelocity, smoothTime, math.huge, dt)
		end
		if offset.YawActive then
			yaw, offset.YawVelocity = TweenService:SmoothDamp(yaw, 0, offset.YawVelocity, smoothTime, math.huge, dt)
		end
		-- Pitch/roll are not camera yaw: let real non-yaw corrections settle normally.
		tilt, offset.TiltVelocity =
			TweenService:SmoothDamp(tilt, CFrame.identity, offset.TiltVelocity, smoothTime, math.huge, dt)
		offset.Value = CFrame.new(position) * CFrame.Angles(0, yaw, 0) * tilt
	end
end

function Smoothing.HasOffset(offset)
	local _, angle = offset.Value:ToAxisAngle()
	return offset.Value.Position.Magnitude > 0.00001 or math.abs(angle) > 0.00001
end

function Smoothing.Facing(current, target, responsiveness, dt)
	return current:Lerp(target, 1 - math.exp(-responsiveness * dt))
end

return Smoothing
