-- Integrate a virtual arena in its initial coordinate frame, independent of render cadence.
local Motion = {}
local STEP = 1 / 120
local EPSILON = 1e-9

function Motion.new(movements)
	return {
		movements = movements,
		index = 1,
		boundary = if movements[1] then movements[1].Duration else math.huge,
		time = 0,
		position = Vector3.zero,
		velocity = Vector3.zero,
		rotation = CFrame.identity,
	}
end

local function integrate(state, duration, movement)
	local angular = if movement then movement.AngularVelocity * (math.pi / 180) else Vector3.zero
	local speed = angular.Magnitude
	local turn = if speed > 0 then CFrame.fromAxisAngle(angular / speed, speed * duration) else CFrame.identity
	local halfTurn = if speed > 0
		then CFrame.fromAxisAngle(angular / speed, speed * duration * 0.5)
		else CFrame.identity
	local acceleration = (state.rotation * halfTurn):VectorToWorldSpace(
		if movement and state.index <= #state.movements then movement.Acceleration else Vector3.zero
	)
	return state.position + state.velocity * duration + acceleration * (0.5 * duration * duration),
		state.velocity + acceleration * duration,
		(state.rotation * turn):Orthonormalize()
end

function Motion.Evaluate(state, age)
	while true do
		if state.time >= state.boundary - EPSILON then
			state.index += 1
			local nextMovement = state.movements[state.index]
			state.boundary = if nextMovement then state.boundary + nextMovement.Duration else math.huge
		end
		local movement = state.movements[math.min(state.index, #state.movements)]
		if state.index > #state.movements then
			-- Coasting has no acceleration: evaluate it exactly without stepping through every second.
			local position, velocity, rotation = integrate(state, math.max(age - state.time, 0), movement)
			return CFrame.new(position) * rotation, velocity, if movement then movement.AngularVelocity else Vector3.zero
		end
		local nextTime = math.min(state.time + STEP, state.boundary)
		if nextTime > age + EPSILON then
			-- Preview partial steps without committing them; all FPS use the same integration grid.
			local position, velocity, rotation = integrate(state, math.max(age - state.time, 0), movement)
			return CFrame.new(position) * rotation, velocity, if movement then movement.AngularVelocity else Vector3.zero
		end
		state.position, state.velocity, state.rotation = integrate(state, nextTime - state.time, movement)
		state.time = nextTime
	end
end

return Motion
