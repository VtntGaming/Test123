local WeaponConfig = require(script.Parent.WeaponConfig)
local TweenService = game:GetService("TweenService")
local JumpAttackCharge = {}
local settings = WeaponConfig.ChargedJumpAttack
local pendingRestores = {}
assert(type(settings.Enable) == "boolean", "Invalid ChargedJumpAttack.Enable")
for name, enumType in { EasingStyle = Enum.EasingStyle, EasingDirection = Enum.EasingDirection } do
	local value = settings[name]
	assert(typeof(value) == "EnumItem" and value.EnumType == enumType, "Invalid ChargedJumpAttack." .. name)
end

local function movementLocked(character)
	return character:GetAttribute("IsFrozen")
		or character:GetAttribute("MovementLocked")
		or character:GetAttribute("IsRagdolled")
end

local function clearRestore(state)
	if state.restoreConnections then
		for _, connection in state.restoreConnections do
			connection:Disconnect()
		end
		state.restoreConnections = nil
	end
	if pendingRestores[state.humanoid] == state then
		pendingRestores[state.humanoid] = nil
	end
	state.appliedWalkSpeed = nil
end

local function restoreSpeed(state)
	local humanoid, character = state.humanoid, state.character
	if not humanoid.Parent or humanoid.Health <= 0 or not character.Parent then
		clearRestore(state)
		return
	end
	if movementLocked(character) then
		return
	end
	local applied = state.appliedWalkSpeed
	clearRestore(state)
	if applied ~= nil and math.abs(humanoid.WalkSpeed - applied) <= 0.0001 then
		humanoid.WalkSpeed = state.walkSpeed
	end
end

for _, name in { "MinHoldTime", "StopTime" } do
	local value = settings[name]
	assert(
		type(value) == "number"
			and value == value
			and value < math.huge
			and value >= 0,
		"Invalid ChargedJumpAttack." .. name
	)
end

function JumpAttackCharge.Begin(character, manageMovement)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local pending = humanoid and pendingRestores[humanoid]
	if pending then
		restoreSpeed(pending)
		-- A new charge must never inherit a stale recovery callback.
		clearRestore(pending)
	end
	return {
		character = character,
		humanoid = humanoid,
		root = root,
		airborne = humanoid ~= nil and humanoid.FloorMaterial == Enum.Material.Air,
		walkSpeed = if humanoid then humanoid.WalkSpeed else 0,
		manageMovement = manageMovement ~= false,
	}
end

function JumpAttackCharge.IsCharged(state, heldTime)
	return settings.Enable and state ~= nil and state.airborne and heldTime >= settings.MinHoldTime
end

function JumpAttackCharge.Update(state, heldTime)
	if not state or not state.manageMovement or state.stopped or not JumpAttackCharge.IsCharged(state, heldTime) then
		return
	end
	local humanoid, root, character = state.humanoid, state.root, state.character
	if
		not humanoid
		or not humanoid.Parent
		or humanoid.Health <= 0
		or not root
		or not root.Parent
		or root.Anchored
		or character:GetAttribute("IsFrozen")
		or character:GetAttribute("MovementLocked")
		or character:GetAttribute("IsRagdolled")
	then
		return
	end
	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	state.horizontalSpeed = state.horizontalSpeed or horizontal.Magnitude
	local progress = if heldTime >= settings.MinHoldTime + settings.StopTime
		then 1
		elseif settings.StopTime > 0 then math.clamp((heldTime - settings.MinHoldTime) / settings.StopTime, 0, 1)
		else 1
	-- Clamp overshooting curves (Back/Elastic) to the original speed range, and stop exactly at the deadline.
	local eased = if progress >= 1
		then 1
		else TweenService:GetValue(progress, settings.EasingStyle, settings.EasingDirection)
	local remaining = 1 - math.clamp(eased, 0, 1)
	humanoid.WalkSpeed = state.walkSpeed * remaining
	-- Humanoid properties round to engine precision; keep the stored value, not the Lua calculation.
	state.appliedWalkSpeed = humanoid.WalkSpeed
	-- local limit = state.horizontalSpeed * remaining
	-- if horizontal.Magnitude > limit then
	-- 	horizontal = if limit > 0 then horizontal.Unit * limit else Vector3.zero
	-- 	root.AssemblyLinearVelocity = horizontal + Vector3.yAxis * velocity.Y
	-- end
end

function JumpAttackCharge.Stop(state)
	if not state or state.stopped then
		return
	end
	state.stopped = true
	local humanoid, character = state.humanoid, state.character
	if
		humanoid
		and humanoid.Parent
		and state.appliedWalkSpeed ~= nil
		and math.abs(humanoid.WalkSpeed - state.appliedWalkSpeed) <= 0.0001
	then
		if movementLocked(character) then
			-- Keep the baseline until recovery instead of permanently forgetting it at the hit.
			humanoid.WalkSpeed = 0
			state.appliedWalkSpeed = humanoid.WalkSpeed
			pendingRestores[humanoid] = state
			state.restoreConnections = {}
			local function changed()
				restoreSpeed(state)
			end
			for _, flag in { "IsFrozen", "MovementLocked", "IsRagdolled" } do
				table.insert(state.restoreConnections, character:GetAttributeChangedSignal(flag):Connect(changed))
			end
			table.insert(state.restoreConnections, character.AncestryChanged:Connect(changed))
			table.insert(state.restoreConnections, humanoid.AncestryChanged:Connect(changed))
			table.insert(state.restoreConnections, humanoid.Died:Connect(changed))
			restoreSpeed(state)
			return
		end
		humanoid.WalkSpeed = state.walkSpeed
	end
	state.appliedWalkSpeed = nil
end

return JumpAttackCharge
