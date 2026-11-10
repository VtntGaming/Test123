--!strict
-- Observes accepted charge eligibility; shared movement owns slowdown and recovery.
local Weapons = require(script.Parent.WeaponConfig)
export type Charge = { airborne: boolean, stopped: boolean }
export type JumpAttackCharge = {
	Begin: (Model, boolean?) -> Charge,
	IsCharged: (Charge?, number) -> boolean,
	Update: (Charge?, number) -> (),
	Stop: (Charge?) -> (),
}
local JumpAttackCharge: JumpAttackCharge = {} :: JumpAttackCharge
function JumpAttackCharge.Begin(character, manageMovement)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return { airborne = humanoid ~= nil and humanoid.FloorMaterial == Enum.Material.Air, stopped = false }
end
function JumpAttackCharge.IsCharged(state, heldTime)
	return Weapons.ChargedJumpAttack.Enable
		and state ~= nil
		and state.airborne
		and heldTime >= Weapons.ChargedJumpAttack.MinHoldTime
end
function JumpAttackCharge.Update(state, heldTime) end
function JumpAttackCharge.Stop(state)
	if state then
		state.stopped = true
	end
end
return JumpAttackCharge
