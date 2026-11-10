--!strict
local Combat = require(game:GetService("ReplicatedStorage"):WaitForChild("Combat"))
-- Pure server motion helper; RagdollService owns the single fixed-step scheduler.
local Motion = {}
local Workspace = game:GetService("Workspace")
local SKIN = 0.025
local GROUND_Y = 0.35
local STOP_SPEED = 0.05
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.RespectCanCollide = true
castParams.IgnoreWater = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.RespectCanCollide = true
-- Do not truncate bounding-box candidates before exact surface filtering.
overlapParams.MaxParts = 0

-- Initial collision volume stored only on the server; no replicated Part is needed.
export type Collider = {
	position: Vector3, -- Initial world-space sphere center, before overlap correction.
	radius: number, -- Torso-derived radius retained throughout this active knockback.
}

-- Server-only scripted motion for one hit; visual limbs do not drive this state.
export type State = {
	root: BasePart, -- Real character root or bag mesh associated with this motion.
	profile: any, -- Validated, per-hit motion settings, including charge scaling.
	weaponId: string, -- Base weapon family associated with the hit.
	position: Vector3, -- Current sphere center in world space, in studs.
	velocity: Vector3, -- Current scripted world-space velocity, in studs per second.
	radius: number, -- Sphere sweep radius in studs.
	gravity: number, -- Scripted downward acceleration derived from this hit's height and apex time.
	heading: CFrame, -- Fixed horizontal root orientation captured when motion begins.
	rootToTorso: Vector3, -- Initial root-to-sphere offset expressed in the heading's local axes.
	phase: string, -- Current Stun, Fly, Bounce, Slide, or Rest motion phase.
	stunUntil: number, -- Server timestamp when the initial held phase ends.
	launchVelocity: Vector3, -- Flight velocity stored while Stun holds current velocity at zero.
	stunOffset: CFrame, -- Sphere-to-root transform that preserves the held pose during Stun.
	groundBounces: number, -- Remaining permitted ground rebounds for this hit.
	wallBounces: number, -- Remaining permitted wall rebounds for this hit.
	restTime: number, -- Seconds accumulated in uninterrupted Rest.
	flyTime: number, -- Accumulated simulation seconds in Fly.
	support: BasePart?, -- Supporting BasePart, if any; terrain does not use this part reference.
	supportFrame: CFrame?, -- Previous supporting-part transform for platform motion tracking.
	supportLocal: Vector3?, -- Contact point in the supporting part's local coordinates.
	supportSize: Vector3?, -- Previously sampled support size for handling shrinking platforms.
	supportNormal: Vector3, -- World-space normal of the currently tracked ground surface.
	supportVelocity: Vector3, -- Estimated support movement velocity for this simulation step.
	lastSafe: Vector3?, -- Last sphere position considered safe, used if overlap correction fails.
	changed: boolean, -- Whether the current step changed motion state and needs publication.
	contactsLeft: number, -- Remaining collision-resolution contacts allowed in this fixed step.
	impacts: { Combat.ReactionImpact }, -- Bounded contact history used for reaction selection and validation.
	impactId: number, -- Last assigned collision ID within this motion session.
	stepTime: number, -- Server timeline timestamp of the current fixed simulation step.
	events: { any }, -- Pending reliable phase/contact events awaiting the owning service.
}

function Motion.SetFilter(excluded: { Instance })
	castParams.FilterDescendantsInstances = excluded
	overlapParams.FilterDescendantsInstances = excluded
end

function Motion.ValidateProfiles(raw: any): { [string]: any }
	assert(type(raw) == "table", "Config.Weapon must return a table")
	local profiles: { [string]: any } = {}
	for id, source in raw do
		assert(type(id) == "string" and id ~= "" and type(source) == "table", "Invalid Cartoon profile")
		local profile: any = table.clone(source)
		if profile.SlideEnabled == nil then
			profile.SlideEnabled = true
		end
		assert(type(profile.SlideEnabled) == "boolean", id .. ".SlideEnabled must be a boolean")
		if profile.FlyTimeout == nil then
			profile.FlyTimeout = 1.25
		end
		assert(
			type(profile.FlyTimeout) == "number"
				and profile.FlyTimeout == profile.FlyTimeout
				and profile.FlyTimeout >= 0
				and profile.FlyTimeout <= 60,
			id .. ".FlyTimeout must be between zero and sixty; zero disables"
		)
		if profile.FlyTimeoutRequiresJump == nil then
			profile.FlyTimeoutRequiresJump = false
		end
		assert(
			type(profile.FlyTimeoutRequiresJump) == "boolean",
			id .. ".FlyTimeoutRequiresJump must be a boolean"
		)
		assert(
			type(profile.StunDuration) == "number"
				and profile.StunDuration == profile.StunDuration
				and profile.StunDuration >= 0
				and profile.StunDuration <= 10,
			id .. ".StunDuration must be between zero and ten"
		)
		for _, key in
			{
				"HorizontalSpeed",
				"LaunchHeight",
				"TimeToApex",
				"GroundBounceCount",
				"GroundBounceHeight",
				"GroundSpeedRetention",
				"WallBounceCount",
				"WallSpeedRetention",
				"SlideDeceleration",
				"RestDuration",
				"MaxDuration",
			}
		do
			local value = profile[key]
			assert(
				type(value) == "number" and value == value and value >= 0 and value < math.huge,
				"Config.Weapon." .. id .. "." .. key .. " must be finite and nonnegative"
			)
		end
		assert(
			profile.TimeToApex >= 0.05
				and profile.LaunchHeight > 0
				and profile.SlideDeceleration > 0
				and profile.MaxDuration > 0,
			"Cartoon timing/height/deceleration must be positive"
		)
		assert(
			profile.HorizontalSpeed <= 500
				and profile.LaunchHeight <= 200
				and profile.GroundBounceHeight <= 200
				and profile.MaxDuration <= 60,
			"Cartoon speed/height/duration exceed supported bounds"
		)
		local gravity = 2 * profile.LaunchHeight / profile.TimeToApex ^ 2
		local maxUpward = math.max(
			2 * profile.LaunchHeight / profile.TimeToApex,
			math.sqrt(2 * gravity * profile.GroundBounceHeight)
		)
		assert(
			(maxUpward + gravity * profile.MaxDuration + profile.HorizontalSpeed) / 60 < 1000,
			id .. " can exceed the sphere sweep distance limit; reduce height/gravity/duration"
		)
		for _, key in { "GroundSpeedRetention", "WallSpeedRetention" } do
			assert(profile[key] <= 1, id .. "." .. key .. " must be between zero and one")
		end
		for _, key in { "GroundBounceCount", "WallBounceCount" } do
			assert(
				profile[key] % 1 == 0 and profile[key] <= 20,
				id .. "." .. key .. " must be an integer from 0 to 20"
			)
		end
		for _, key in { "FlyVisualOffset", "RestVisualOffset" } do
			local value = profile[key] or Vector3.zero
			assert(
				typeof(value) == "Vector3"
					and value.X == value.X
					and value.Y == value.Y
					and value.Z == value.Z
					and value.Magnitude <= 20,
				id .. "." .. key .. " must be a finite Vector3 within 20 studs"
			)
			profile[key] = value
		end
		profiles[id] = table.freeze(profile)
	end
	return table.freeze(profiles)
end

function Motion.IsAirborne(state: State): boolean
	return state.phase == "Fly" or state.phase == "Bounce"
end

function Motion.RootFrame(state: State): CFrame
	if state.phase == "Stun" then
		return CFrame.new(state.position) * state.stunOffset
	end
	local offset = if state.phase == "Fly"
		then state.profile.FlyVisualOffset
		else state.profile.RestVisualOffset
	return CFrame.new(state.position) * state.heading * CFrame.new(-state.rootToTorso + offset)
end

local function overlapCorrection(state: State, position: Vector3, checkTerrain: boolean): Vector3?
	for _, part in Workspace:GetPartBoundsInRadius(position, state.radius, overlapParams) do
		-- Bounds only choose candidates. ClosestPoint respects collision geometry,
		-- including mesh fidelity, and returns position itself when it is inside.
		local closest = part:GetClosestPointOnSurface(position)
		local delta = position - closest
		local distance = delta.Magnitude
		if distance >= state.radius - 0.005 then
			continue
		end
		local localPoint = part.CFrame:PointToObjectSpace(position)
		local half = part.Size * 0.5
		if distance <= 0.00001 then
			-- Conservatively escape the nearest bounding-box face. This also
			-- handles an embedded wedge/mesh without guessing a surface's inside.
			local gaps = half
				- Vector3.new(math.abs(localPoint.X), math.abs(localPoint.Y), math.abs(localPoint.Z))
			local axis: Vector3
			local depth: number
			if gaps.Y <= gaps.X and gaps.Y <= gaps.Z then
				axis, depth = Vector3.yAxis * (if localPoint.Y >= 0 then 1 else -1), gaps.Y
			elseif gaps.X <= gaps.Z then
				axis, depth = Vector3.xAxis * (if localPoint.X >= 0 then 1 else -1), gaps.X
			else
				axis, depth = Vector3.zAxis * (if localPoint.Z >= 0 then 1 else -1), gaps.Z
			end
			return part.CFrame:VectorToWorldSpace(axis) * (depth + state.radius + SKIN)
		elseif distance < state.radius - 0.005 then
			return (if distance > 0.001 then delta.Unit else Vector3.yAxis) * (state.radius - distance + SKIN)
		end
	end
	if not checkTerrain then
		return nil
	end
	-- Spatial overlaps omit Terrain voxels. These bounded shell probes also
	-- cover a terrain wall or ceiling surrounding the starting sphere.
	for _, axis in
		{ Vector3.yAxis, -Vector3.yAxis, Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis, -Vector3.zAxis }
	do
		local terrain = Workspace:Raycast(
			position + axis * (state.radius * 2 + SKIN),
			-axis * (state.radius * 4 + SKIN * 2),
			castParams
		)
		if
			terrain
			and terrain.Instance:IsA("Terrain")
			and terrain.Distance > SKIN
			and terrain.Normal:Dot(axis) > 0.05
		then
			local penetration = state.radius - (position - terrain.Position):Dot(terrain.Normal)
			if penetration > 0.005 then
				return terrain.Normal * (penetration + SKIN)
			end
		end
	end
	return nil
end

local function correctOverlap(state: State, checkTerrain: boolean): boolean
	local origin = state.position
	for _ = 1, 4 do
		local correction = overlapCorrection(state, state.position, checkTerrain)
		if not correction then
			state.lastSafe = state.position
			return true
		end
		if (state.position + correction - origin).Magnitude > math.max(2, state.radius * 2) then
			break
		end
		state.position += correction
	end
	if not overlapCorrection(state, state.position, checkTerrain) then
		state.lastSafe = state.position
		return true
	end
	local fallback = state.lastSafe
	if fallback and not overlapCorrection(state, fallback, checkTerrain) then
		state.position = fallback
		state.velocity = Vector3.zero
		return true
	end
	state.position = origin
	return false
end

local function setPhase(state: State, phase: string)
	if state.phase ~= phase then
		state.phase = phase
		state.changed = true
	end
end

local function setSupport(state: State, result: RaycastResult)
	local part = result.Instance
	state.support = if part:IsA("BasePart") then part else nil
	state.supportNormal = result.Normal
	if state.support then
		state.supportFrame = state.support.CFrame
		state.supportLocal = state.support.CFrame:PointToObjectSpace(result.Position)
		state.supportSize = state.support.Size
	else
		state.supportFrame, state.supportLocal, state.supportSize = nil, nil, nil
	end
end

local function detach(state: State)
	state.support, state.supportFrame, state.supportLocal, state.supportSize = nil, nil, nil, nil
	state.restTime = 0
	setPhase(state, "Fly")
end

local function project(vector: Vector3, normal: Vector3): Vector3
	return vector - normal * vector:Dot(normal)
end

local function impact(state: State, hit: RaycastResult, outcome: string, restDirection: Vector3?)
	state.impactId += 1
	table.insert(
		state.impacts,
		{
			id = state.impactId,
			time = state.stepTime,
			normal = hit.Normal,
			outcome = outcome,
			contactPosition = hit.Position,
			restDirection = restDirection,
		}
	)
	-- Bounded validation records; regular movement never carries this history.
	if #state.impacts > 64 then
		table.remove(state.impacts, 1)
	end
	table.insert(state.events, {
		kind = "Impact",
		impact = table.clone(state.impacts[#state.impacts]),
		position = state.position,
		velocity = state.velocity,
		phase = state.phase,
		time = state.stepTime,
	})
	state.changed = true
end

local function respond(state: State, hit: RaycastResult)
	local normal, velocity, profile = hit.Normal, state.velocity, state.profile
	if normal.Y >= GROUND_Y then
		if Motion.IsAirborne(state) then
			if state.groundBounces > 0 and profile.GroundBounceHeight > 0 then
				state.groundBounces -= 1
				state.velocity = project(
					Vector3.new(velocity.X, 0, velocity.Z) * profile.GroundSpeedRetention,
					normal
				) + Vector3.yAxis * math.sqrt(2 * state.gravity * profile.GroundBounceHeight)
				setPhase(state, "Bounce")
				impact(state, hit, "Rebound")
			else
				local restDirection: Vector3? = nil
				if profile.SlideEnabled == false then
					-- Use the same ground projection as sliding, but keep movement at zero.
					local slideVelocity = project(Vector3.new(velocity.X, 0, velocity.Z), normal)
					local horizontal = Vector3.new(slideVelocity.X, 0, slideVelocity.Z)
					restDirection = if horizontal.Magnitude > STOP_SPEED
						then horizontal.Unit
						else state.heading.LookVector
					state.velocity = Vector3.zero
					state.restTime = 0
					setPhase(state, "Rest")
				else
					state.velocity = project(Vector3.new(velocity.X, 0, velocity.Z), normal)
					setPhase(state, "Slide")
				end
				impact(state, hit, "Landing", restDirection)
				-- Reuse the landing contact; support is revalidated on later steps.
				setSupport(state, hit)
			end
		else
			state.velocity = project(velocity, normal)
			setSupport(state, hit)
		end
	elseif normal.Y <= -GROUND_Y then
		state.velocity = Vector3.new(velocity.X, math.min(0, velocity.Y), velocity.Z)
		if state.velocity:Dot(normal) < 0 then
			state.velocity = project(state.velocity, normal)
		end
	else
		local horizontalNormal = Vector3.new(normal.X, 0, normal.Z)
		if horizontalNormal.Magnitude < 0.001 then
			return
		end
		horizontalNormal = horizontalNormal.Unit
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
		local into = horizontal:Dot(horizontalNormal)
		if into < 0 then
			local rebounded = false
			if state.wallBounces > 0 then
				state.wallBounces -= 1
				horizontal = (horizontal - 2 * into * horizontalNormal) * profile.WallSpeedRetention
				if Motion.IsAirborne(state) then
					setPhase(state, "Bounce")
				end
				rebounded = true
			else
				horizontal -= into * horizontalNormal
			end
			state.velocity = horizontal + Vector3.yAxis * velocity.Y
			if rebounded then
				impact(state, hit, "Rebound")
			end
			state.changed = true
		end
	end
end

local function sweep(state: State, dt: number)
	local remaining = dt
	for _ = 1, 3 do
		if state.contactsLeft <= 0 then
			break
		end
		local delta = state.velocity * remaining
		if delta.Magnitude < 0.00001 then
			break
		end
		local hit = Workspace:Spherecast(state.position, state.radius, delta, castParams)
		if not hit then
			state.position += delta
			break
		end
		state.contactsLeft -= 1
		state.position += delta.Unit * math.max(0, hit.Distance) + hit.Normal * SKIN
		remaining *= math.clamp(1 - hit.Distance / delta.Magnitude, 0, 1)
		respond(state, hit)
		if remaining < 0.00001 then
			break
		end
	end
	-- Unconsumed movement after three contacts is deliberately discarded in corners.
end

local function supportProbe(state: State): RaycastResult?
	local hit = Workspace:Spherecast(
		state.position + Vector3.yAxis * 0.12,
		state.radius,
		-Vector3.yAxis * 0.32,
		castParams
	)
	if hit and hit.Normal.Y >= GROUND_Y then
		return hit
	end
	return nil
end

local function snapToSupport(state: State, hit: RaycastResult)
	-- Add clearance vertically, retaining the sweep center's X/Z. Adding a
	-- normal offset each probe would slowly drift a resting sphere down a slope.
	state.position = hit.Position + hit.Normal * state.radius + Vector3.yAxis * (SKIN / hit.Normal.Y)
	setSupport(state, hit)
end

function Motion.Start(
	root: BasePart,
	collider: Collider,
	profile: any,
	weaponId: string,
	direction: Vector3,
	previous: State?,
	stunDuration: number?
): State?
	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.001 then
		look = -Vector3.zAxis
	end
	local heading = if previous then previous.heading else CFrame.lookAt(Vector3.zero, look.Unit)
	local position = if previous then previous.position else collider.position
	local heldRoot = if previous then Motion.RootFrame(previous) else root.CFrame
	local delay = stunDuration or 0
	local state: State = {
		root = root,
		profile = profile,
		weaponId = weaponId,
		position = position,
		velocity = direction * profile.HorizontalSpeed
			+ Vector3.yAxis * (2 * profile.LaunchHeight / profile.TimeToApex),
		radius = collider.radius,
		gravity = 2 * profile.LaunchHeight / profile.TimeToApex ^ 2,
		heading = heading,
		rootToTorso = if previous
			then previous.rootToTorso
			else heading:VectorToObjectSpace(position - root.Position),
		stunUntil = 0,
		launchVelocity = Vector3.zero,
		stunOffset = CFrame.identity,
		phase = "Fly",
		groundBounces = profile.GroundBounceCount,
		wallBounces = profile.WallBounceCount,
		restTime = 0,
		flyTime = 0,
		support = nil,
		supportFrame = nil,
		supportLocal = nil,
		supportSize = nil,
		supportNormal = Vector3.yAxis,
		supportVelocity = Vector3.zero,
		lastSafe = if previous then previous.lastSafe else nil,
		changed = false,
		contactsLeft = 3,
		impacts = {},
		impactId = 0,
		stepTime = Workspace:GetServerTimeNow(),
		events = {},
	}
	if not correctOverlap(state, true) then
		return nil
	end
	state.stunOffset = CFrame.new(-state.position) * heldRoot
	if delay > 0 then
		state.phase, state.stunUntil = "Stun", state.stepTime + delay
		state.launchVelocity, state.velocity = state.velocity, Vector3.zero
	end
	return state
end

function Motion.Step(state: State, dt: number, stepTime: number?): (boolean, string?)
	state.stepTime = stepTime or Workspace:GetServerTimeNow()
	state.changed = false
	if state.phase == "Stun" then
		-- Hold in world space: no gravity, collision response or platform following yet.
		if state.stepTime < state.stunUntil then
			return false
		end
		setPhase(state, "Fly")
		state.velocity = state.launchVelocity
		table.insert(state.events, {
			kind = "Phase",
			position = state.position,
			velocity = state.velocity,
			phase = "Fly",
			time = state.stepTime,
		})
		return false -- Integrate the first flight step on the following fixed tick.
	end

	-- Use server time, so discarded catch-up steps cannot lengthen this safety deadline.
	if state.phase == "Fly" then
		state.flyTime += dt

		if state.profile.FlyTimeout > 0
			and state.flyTime >= state.profile.FlyTimeout
			and not state.profile.FlyTimeoutRequiresJump
		then
			return true, "FlyTimeout"
		end
	end
	
	local previousPhase, eventCount = state.phase, #state.events
	state.contactsLeft = 3
	if not Motion.IsAirborne(state) then
		local part, frame, point = state.support, state.supportFrame, state.supportLocal
		state.supportVelocity = Vector3.zero
		if part and frame and point and part.Parent and part.CanCollide then
			-- Resize the supporting surface point, never the sphere's radius/clearance.
			local oldSize = state.supportSize or part.Size
			local ratio = Vector3.new(
				part.Size.X / math.max(oldSize.X, 0.001),
				part.Size.Y / math.max(oldSize.Y, 0.001),
				part.Size.Z / math.max(oldSize.Z, 0.001)
			)
			local nextPoint = point * ratio
			local displacement = part.CFrame:PointToWorldSpace(nextPoint) - frame:PointToWorldSpace(point)
			if displacement.Magnitude > 0.00001 then
				-- Treat a platform teleport beyond the cast limit as a recovery,
				-- instead of issuing an invalid sweep or tunnelling across the map.
				if displacement.Magnitude > 1000 then
					return true
				end
				state.supportVelocity = displacement / dt
				local obstruction =
					Workspace:Spherecast(state.position, state.radius, displacement, castParams)
				if obstruction then
					state.contactsLeft -= 1
					state.position += displacement.Unit * obstruction.Distance + obstruction.Normal * SKIN
				else
					state.position += displacement
				end
				state.supportNormal =
					part.CFrame:VectorToWorldSpace(frame:VectorToObjectSpace(state.supportNormal))
				if not correctOverlap(state, true) then
					return true
				end
			end
		end
		local hit = supportProbe(state)
		if not hit then
			state.velocity += state.supportVelocity
			detach(state)
		else
			snapToSupport(state, hit)
		end
	end
	-- Spherecasts omit initial overlaps. A moving wall can enter the sphere
	-- between steps; correct that separately before performing the next sweep.
	-- Terrain is static between these steps and was checked at launch/platform movement.
	if not correctOverlap(state, false) then
		return true
	end
	if Motion.IsAirborne(state) then
		-- Midpoint integration makes an unobstructed arc reach the configured apex.
		state.velocity -= Vector3.yAxis * (state.gravity * dt * 0.5)
		sweep(state, dt)
		if Motion.IsAirborne(state) then
			state.velocity -= Vector3.yAxis * (state.gravity * dt * 0.5)
		end
	elseif state.phase == "Slide" then
		local tangent = project(state.velocity, state.supportNormal)
		local speed = tangent.Magnitude
		local nextSpeed = math.max(0, speed - state.profile.SlideDeceleration * dt)
		state.velocity = if speed > STOP_SPEED
			then tangent.Unit * ((speed + nextSpeed) * 0.5)
			else Vector3.zero
		sweep(state, dt)
		local resultSpeed = state.velocity.Magnitude
		state.velocity = if resultSpeed > STOP_SPEED
			then state.velocity.Unit * math.min(nextSpeed, resultSpeed)
			else Vector3.zero
		if state.velocity.Magnitude <= STOP_SPEED then
			state.velocity = Vector3.zero
			state.restTime = 0
			setPhase(state, "Rest")
		end
		local hit = supportProbe(state)
		if hit then
			snapToSupport(state, hit)
		else
			detach(state)
		end
	else
		state.restTime += dt
		if state.restTime >= state.profile.RestDuration then
			return true
		end
	end
	local lastEvent = if #state.events > eventCount then state.events[#state.events] else nil
	if
		(previousPhase ~= state.phase or state.changed) and (not lastEvent or lastEvent.phase ~= state.phase)
	then
		table.insert(state.events, {
			kind = "Phase",
			position = state.position,
			velocity = state.velocity,
			phase = state.phase,
			time = state.stepTime,
		})
	end
	state.lastSafe = state.position
	return false
end

return Motion
