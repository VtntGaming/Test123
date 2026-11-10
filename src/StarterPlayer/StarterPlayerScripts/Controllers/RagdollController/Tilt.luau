--!strict
local Combat = require(game:GetService("ReplicatedStorage"):WaitForChild("Combat"))
-- Cosmetic flight tilt, horizontal Bounce lock and Rest yaw layered over Animator output. No limb flailing,
-- forces, root movement, or changes to the torso collider's world position.
local Tilt = {}
local Reaction = Combat.Reaction

-- Airborne visual tuning for Cartoon reactions.
local MAX_TILT = math.rad(110)
local BLEND_SPEED = 14
local MIN_SPEED = 2
local FULL_SPEED = 12

-- Local joint layer applied after Animator evaluation and removed before the next evaluation.
export type State = {
	joint: Instance?, -- Root-to-body Motor6D or AnimationConstraint receiving the tilt layer.
	waist: Instance?, -- Body-to-UpperTorso joint used to reconstruct an R15 torso pose.
	core: BasePart?, -- Torso or UpperTorso whose visible orientation and center are tracked.
	root: BasePart?, -- Current HumanoidRootPart; replacement resets the cached layer.
	base: CFrame?, -- Animator's joint Transform saved before applying this frame's tilt.
	applied: CFrame?, -- Last joint Transform written by Tilt, used to avoid overwriting another writer.
	rotation: CFrame, -- Current additional rotation expressed relative to the root.
	heading: CFrame?, -- Initial horizontal root orientation used as the flight-tilt reference.
	direction: Vector3, -- Horizontal target heading from movement or the saved no-slide landing.
	dirty: boolean, -- Whether rig changes require binding the body joints again.
	nextScan: number, -- Local os.clock() deadline limiting repeated searches for missing joints.
	restFrom: CFrame?, -- Starting correction for Rest blending when no reaction transition is supplied.
	restElapsed: number, -- Seconds elapsed in that fallback Rest blend.
	restYaw: CFrame, -- World-Y correction cached by the fallback Rest orientation calculation.
	transitionToken: number, -- Last reaction transition initialized by the tilt layer.
	transitionFrom: CFrame, -- Additional rotation captured at the start of the current transition.
	restTilt: CFrame, -- Captured world-space pitch/roll after removing yaw, faded out during Rest.
	yaw: number, -- Current world-Y correction angle in radians.
	yawAlpha: number, -- Previous blend progress used to advance yaw without restarting its blend.
	bounceFrom: CFrame, -- Displayed torso world orientation captured for the horizontal Bounce blend.
	pendingOrientation: CFrame?, -- World orientation held while a contact category is unconfirmed.
	releaseOrientation: CFrame?, -- Held orientation used as the starting pose after confirmation arrives.
	releaseStarted: number, -- Local os.clock() time when blending out of the orientation hold began.
	releaseDuration: number, -- Seconds used to blend from the held orientation to the confirmed pose.
}

function Tilt.New(): State
	return {joint = nil, waist = nil, core = nil, root = nil,
		base = nil, applied = nil, rotation = CFrame.identity, heading = nil,
		direction = -Vector3.zAxis, dirty = true, nextScan = 0,
		restFrom = nil, restElapsed = 0, restYaw = CFrame.identity,
		transitionToken = -1, transitionFrom = CFrame.identity, restTilt = CFrame.identity, yaw = 0, yawAlpha = 0,
		bounceFrom = CFrame.identity, pendingOrientation = nil, releaseOrientation = nil,
		releaseStarted = 0, releaseDuration = 0}
end

local function jointFrames(joint: Instance): (BasePart?, BasePart?, CFrame?, CFrame?)
	if joint:IsA("Motor6D") then
		return joint.Part0, joint.Part1, joint.C0, joint.C1
	elseif joint.ClassName == "AnimationConstraint" then
		local animated: any = joint
		local a0, a1 = animated.Attachment0, animated.Attachment1
		if a0 and a1 and a0.Parent and a1.Parent and a0.Parent:IsA("BasePart") and a1.Parent:IsA("BasePart") then
			return a0.Parent, a1.Parent, a0.CFrame, a1.CFrame
		end
	end
	return nil, nil, nil, nil
end

function Tilt.Restore(state: State)
	local joint, base, applied = state.joint, state.base, state.applied
	if joint and joint.Parent and base and applied then
		local animated: any = joint
		-- Do not restore a stale baseline over a newer Animator/other-system write.
		if animated.Transform == applied then animated.Transform = base end
	end
	state.base, state.applied = nil, nil
end

function Tilt.Reset(state: State)
	Tilt.Restore(state)
	state.joint, state.waist, state.core, state.root = nil, nil, nil, nil
	state.rotation, state.heading = CFrame.identity, nil
	state.direction = -Vector3.zAxis
	state.restFrom, state.restElapsed, state.restYaw = nil, 0, CFrame.identity
	state.transitionToken, state.transitionFrom, state.restTilt = -1, CFrame.identity, CFrame.identity
	state.yaw, state.yawAlpha = 0, 0
	state.bounceFrom = CFrame.identity
	state.pendingOrientation, state.releaseOrientation = nil, nil
	state.releaseStarted, state.releaseDuration = 0, 0
	state.dirty, state.nextScan = true, 0
end

function Tilt.ClearPending(state: State)
	state.pendingOrientation, state.releaseOrientation = nil, nil
	state.releaseStarted, state.releaseDuration = 0, 0
end

-- Called before removing last frame's layer or evaluating the next animation.
function Tilt.CapturePending(state: State, character: Model)
	if state.pendingOrientation then return end
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		state.pendingOrientation = torso.CFrame.Rotation
		state.releaseOrientation = nil
	end
end

function Tilt.MarkDirty(state: State)
	Tilt.Restore(state)
	state.dirty, state.nextScan = true, 0
end

local function bindJoints(state: State, character: Model, root: BasePart): boolean
	if state.root ~= root then Tilt.Reset(state); state.root = root end
	if not state.dirty and state.joint and state.joint:IsDescendantOf(character)
		and state.core and state.core.Parent == character
		and (not state.waist or state.waist:IsDescendantOf(character)) then return true end
	local now = os.clock()
	if now < state.nextScan then return false end
	state.nextScan = now + 0.5 -- Missing/streaming joints are retried without a per-frame scan.
	state.joint, state.waist, state.core = nil, nil, nil
	local core = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	if not core or not core:IsA("BasePart") then return false end
	local body: BasePart? = nil
	local joints: {Instance} = {}
	for _, candidate in character:GetDescendants() do
		if candidate:IsA("Motor6D") or candidate.ClassName == "AnimationConstraint" then
			table.insert(joints, candidate)
			local p0, p1 = jointFrames(candidate)
			if p0 and p1 and p0.Parent == character and p1.Parent == character then
				local other = if p0 == root then p1 elseif p1 == root then p0 else nil
				if other and (other.Name == "Torso" or other.Name == "LowerTorso" or other.Name == "UpperTorso") then
					state.joint, body = candidate, other
				end
			end
		end
	end
	if not state.joint or not body then return false end
	if body ~= core then
		for _, candidate in joints do
			local p0, p1 = jointFrames(candidate)
			if (p0 == body and p1 == core) or (p1 == body and p0 == core) then
				state.waist = candidate
				break
			end
		end
		if not state.waist then return false end
	end
	state.core, state.dirty = core, false
	return true
end

local function flatHeading(root: BasePart): CFrame
	local forward = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if forward.Magnitude < 0.001 then
		local right = root.CFrame.RightVector * Vector3.new(1, 0, 1)
		forward = if right.Magnitude > 0.001 then Vector3.yAxis:Cross(right.Unit) else -Vector3.zAxis
	end
	return CFrame.lookAt(Vector3.zero, forward.Unit)
end

local function horizontalBounceRotation(direction: Vector3, category: string): CFrame
	-- Torso +Y points toward the head. Keep it horizontal and head-first, with
	-- the selected contact side facing down. Only travel yaw changes this frame.
	local right: Vector3
	if category == "LeftSide" then
		right = Vector3.yAxis
	elseif category == "RightSide" then
		right = -Vector3.yAxis
	elseif category == "Back" then
		right = -(direction:Cross(Vector3.yAxis))
	else -- Chest (also the fallback for an unknown category).
		right = direction:Cross(Vector3.yAxis)
	end
	return CFrame.fromMatrix(Vector3.zero, right, direction)
end

function Tilt.Apply(state: State, character: Model, root: BasePart, velocity: Vector3?, flying: boolean,
	dt: number, fadeTime: number, transition: Combat.ReactionTransition?, horizontalBounce: string?,
	pendingContact: boolean?, restDirection: Vector3?)
	-- Also safe if more than one simulation callback occurs between animations.
	Tilt.Restore(state)
	if not bindJoints(state, character, root) then return end
	if not state.heading then
		local heading = flatHeading(root)
		state.heading, state.direction = heading, heading.LookVector
	end
	local motion = velocity
	if motion and (motion.X ~= motion.X or motion.Y ~= motion.Y or motion.Z ~= motion.Z
		or motion.Magnitude == math.huge) then motion = nil end
	local horizontal = if motion then motion * Vector3.new(1, 0, 1) else Vector3.zero
	-- Keep following bounces/slides, then retain the last heading at zero speed.
	if horizontal.Magnitude > 0.05 then state.direction = horizontal.Unit end
	-- A no-slide landing carries its incoming heading even though movement is already zero.
	if restDirection and not flying and not horizontalBounce and not pendingContact then
		local landingHeading = restDirection * Vector3.new(1, 0, 1)
		local magnitude = landingHeading.Magnitude
		if magnitude > 0.05 and magnitude < math.huge then
			state.direction = landingHeading.Unit
		end
	end
	local joint = state.joint
	if not joint then return end
	local p0, p1, c0, c1 = jointFrames(joint)
	if not p0 or not p1 or not c0 or not c1 or (p0 ~= root and p1 ~= root) then
		Tilt.Reset(state)
		return
	end
	local animated: any = joint
	if not animated.Enabled then return end
	local base: CFrame = animated.Transform
	local rootFrame = root.CFrame
	local body = if p0 == root then p1 else p0
	local bodyFrame = if p0 == root then rootFrame * c0 * base * c1:Inverse()
		else rootFrame * c1 * base:Inverse() * c0:Inverse()
	local coreFrame = bodyFrame
	if state.waist then
		local w0, w1, wc0, wc1 = jointFrames(state.waist)
		if not w0 or not w1 or not wc0 or not wc1 then Tilt.MarkDirty(state); return end
		local waistTransform: CFrame = (state.waist :: any).Transform
		if w0 == body and w1 == state.core then
			coreFrame = bodyFrame * wc0 * waistTransform * wc1:Inverse()
		elseif w1 == body and w0 == state.core then
			coreFrame = bodyFrame * wc1 * waistTransform:Inverse() * wc0:Inverse()
		else
			Tilt.MarkDirty(state)
			return
		end
	end
	local rootRotation = rootFrame.Rotation
	local held = state.pendingOrientation
	if not pendingContact and held then
		state.releaseOrientation = held
		state.releaseStarted = os.clock()
		state.releaseDuration = if transition then transition.duration else fadeTime
		state.pendingOrientation = nil
		-- Confirmation keeps the animation token; explicitly rebase the tilt blend.
		state.transitionToken = -1
	end
	if pendingContact then
		-- New/streamed joints may not yet have been bound when CapturePending ran.
		local orientation = held or coreFrame.Rotation
		state.pendingOrientation, state.releaseOrientation = orientation, nil
		local correction = orientation * coreFrame.Rotation:Inverse()
		state.rotation = rootRotation:Inverse() * correction * rootRotation
	elseif transition then
		local alpha = Reaction.Alpha(transition, os.clock())
		if state.transitionToken ~= transition.token then
			state.transitionToken, state.transitionFrom = transition.token, state.rotation
			local world = rootRotation * state.rotation * rootRotation:Inverse()
			state.bounceFrom = world * coreFrame.Rotation
			local forward = world.LookVector
			local yaw = if Vector3.new(forward.X, 0, forward.Z).Magnitude > 0.001
				then math.atan2(-forward.X, -forward.Z)
				else math.atan2(-world.RightVector.Z, world.RightVector.X)
			state.yaw, state.yawAlpha = yaw, 0
			state.restTilt = CFrame.fromAxisAngle(Vector3.yAxis, -yaw) * world
		end
		if transition.to == "Normal" then
			state.rotation = state.transitionFrom:Lerp(CFrame.identity, alpha)
		elseif horizontalBounce then
			-- Blend the DISPLAYED torso toward a fixed horizontal orientation.
			-- Cancel the animation's torso pitch/roll every frame so upright Bounce
			-- clips (and their held final frames) cannot lift the body back upright.
			local desired = horizontalBounceRotation(state.direction, horizontalBounce)
			local displayed = state.bounceFrom:Lerp(desired, alpha)
			local correction = displayed * coreFrame.Rotation:Inverse()
			state.rotation = rootRotation:Inverse() * correction * rootRotation
		elseif flying then
			local target = CFrame.identity
			if motion and motion.Magnitude > MIN_SPEED then
				local angle = math.clamp(math.atan2(horizontal.Magnitude, motion.Y), 0, MAX_TILT)
				local axis = Vector3.yAxis:Cross(state.direction).Unit
				local desired = CFrame.fromAxisAngle(axis, angle) * (state.heading :: CFrame)
				local strength = math.clamp((motion.Magnitude - MIN_SPEED) / (FULL_SPEED - MIN_SPEED), 0, 1)
				target = CFrame.identity:Lerp(rootRotation:Inverse() * desired, strength)
			end
			if alpha < 1 then state.rotation = state.transitionFrom:Lerp(target, alpha)
			else state.rotation = state.rotation:Lerp(target, 1 - math.exp(-BLEND_SPEED * math.clamp(dt, 0, 0.1))) end
		else
			-- Fade pitch/roll to identity independently of world yaw. Never slerp
			-- a changing Rest target: its quaternion path can flip across 180 degrees.
			local residualTilt = state.restTilt:Lerp(CFrame.identity, alpha)
			local forward = (residualTilt * coreFrame.Rotation).UpVector * Vector3.new(1, 0, 1)
			if forward.Magnitude > 0.001 then
				forward = forward.Unit
				local targetYaw = math.atan2(forward:Cross(state.direction).Y, forward:Dot(state.direction))
				local unwrapped = Reaction.Unwrap(state.yaw, targetYaw)
				local step = if state.yawAlpha < 1 then math.clamp((alpha - state.yawAlpha) / (1 - state.yawAlpha), 0, 1) else 1
				state.yaw += (unwrapped - state.yaw) * step
			end
			state.yawAlpha = alpha
			state.rotation = rootRotation:Inverse() * CFrame.fromAxisAngle(Vector3.yAxis, state.yaw) * residualTilt * rootRotation
		end
	else
		if horizontalBounce then
			local desired = horizontalBounceRotation(state.direction, horizontalBounce)
			state.rotation = rootRotation:Inverse() * desired * coreFrame.Rotation:Inverse() * rootRotation
		elseif flying then
			state.restFrom, state.restElapsed = nil, 0
			local target = CFrame.identity
			if motion and motion.Magnitude > MIN_SPEED then
				-- Keep the existing trajectory tilt and front/back hit differences.
				local angle = math.clamp(math.atan2(horizontal.Magnitude, motion.Y), 0, MAX_TILT)
				local axis = Vector3.yAxis:Cross(state.direction).Unit
				local desired = CFrame.fromAxisAngle(axis, angle) * (state.heading :: CFrame)
				local strength = math.clamp((motion.Magnitude - MIN_SPEED) / (FULL_SPEED - MIN_SPEED), 0, 1)
				target = CFrame.identity:Lerp(rootRotation:Inverse() * desired, strength)
			end
			state.rotation = state.rotation:Lerp(target, 1 - math.exp(-BLEND_SPEED * math.clamp(dt, 0, 0.1)))
		else
			-- The lying pose travels head-first: torso +Y points toward the head,
			-- while LookVector points out of the chest and makes the body sideways.
			-- Read the authored pose before our layer; correct around world Y only.
			local forward = coreFrame.UpVector * Vector3.new(1, 0, 1)
			if forward.Magnitude > 0.001 then
				forward = forward.Unit
				local yaw = math.atan2(forward:Cross(state.direction).Y, forward:Dot(state.direction))
				state.restYaw = CFrame.fromAxisAngle(Vector3.yAxis, yaw)
			end
			local target = rootRotation:Inverse() * state.restYaw * rootRotation
			if not state.restFrom then state.restFrom = state.rotation; state.restElapsed = 0 end
			state.restElapsed += math.max(0, dt)
			local alpha = if fadeTime > 0 then math.clamp(state.restElapsed / fadeTime, 0, 1) else 1
			-- Remove the flight tilt over the same duration as the animation fade.
			state.rotation = (state.restFrom :: CFrame):Lerp(target, alpha)
		end
	end
	-- Crossfade the displayed orientation, not yesterday's correction matrix.
	-- This stays continuous even if replicated animation advances during the wait.
	local release = state.releaseOrientation
	if release and not pendingContact then
		local alpha = if state.releaseDuration > 0
			then math.clamp((os.clock() - state.releaseStarted) / state.releaseDuration, 0, 1) else 1
		local desired = rootRotation * state.rotation * rootRotation:Inverse() * coreFrame.Rotation
		local displayed = release:Lerp(desired, alpha)
		state.rotation = rootRotation:Inverse() * displayed * coreFrame.Rotation:Inverse() * rootRotation
		if alpha >= 1 then state.releaseOrientation = nil end
	end
	-- Rotate the animated body about the CURRENT posed torso center. In R15,
	-- include the Waist transform to keep the displayed torso center fixed.
	local delta = rootRotation * state.rotation * rootRotation:Inverse()
	local pivot = coreFrame.Position
	local posedBody = CFrame.new(pivot) * delta * CFrame.new(-pivot) * bodyFrame
	local posed = if p0 == root then (rootFrame * c0):Inverse() * posedBody * c1
		else (posedBody * c0):Inverse() * rootFrame * c1
	state.base = base
	animated.Transform = posed
	-- Joint properties can normalize the rotation; compare against the stored
	-- value next frame so this layer never accumulates on its own output.
	state.applied = animated.Transform
end

return Tilt

