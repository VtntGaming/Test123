--!strict
-- Applies character scaling while preserving current movement and optionally keeping the weapon size.

--// Types
type WeaponJoint = {
	Joint: WeldConstraint | Weld,
	Part0: BasePart,
	Part1: BasePart,
	C1: CFrame?,
}

type WeaponGrip = {
	Host: BasePart,
	HostSize: Vector3,
	Offset: CFrame,
}

export type ShrinkScale = {
	Apply: (character: Model, humanoid: Humanoid, root: BasePart, scale: number, scaleWeapon: boolean) -> (),
}

--// Controller
local ShrinkScale = {} :: ShrinkScale

--// APIs
function ShrinkScale.Apply(character, humanoid, root, scale, scaleWeapon)
	local original = {
		WalkSpeed = humanoid.WalkSpeed,
		JumpHeight = humanoid.JumpHeight,
		JumpPower = humanoid.JumpPower,
		LinearVelocity = root.AssemblyLinearVelocity,
		AngularVelocity = root.AssemblyAngularVelocity,
	}

	local weapon = character:FindFirstChild("EquippedWeapon")
	local main = weapon and weapon:FindFirstChild("Main")
	local weaponSize: Vector3? = nil
	local joints: { WeaponJoint } = {}
	local attachment: WeaponGrip? = nil
	if not scaleWeapon and weapon and weapon:IsA("Model") and main and main:IsA("BasePart") then
		weaponSize = main.Size
		-- Grip joints can live on the hand instead of inside the equipped weapon.
		for _, descendant in character:GetDescendants() do
			if not (descendant:IsA("WeldConstraint") or descendant:IsA("Weld")) or not descendant.Enabled then
				continue
			end
			local part0, part1 = descendant.Part0, descendant.Part1
			if not part0 or not part1 then
				continue
			end
			local part0InWeapon = part0:IsDescendantOf(weapon)
			local part1InWeapon = part1:IsDescendantOf(weapon)
			if not part0InWeapon and not part1InWeapon then
				continue
			end
			local host = if part0InWeapon then part1 else part0
			if not attachment and part0InWeapon ~= part1InWeapon and host:IsDescendantOf(character) then
				attachment = {
					Host = host,
					HostSize = host.Size,
					Offset = host.CFrame:ToObjectSpace(main.CFrame),
				}
			end
			table.insert(joints, {
				Joint = descendant,
				Part0 = part0,
				Part1 = part1,
				C1 = if descendant:IsA("Weld") then descendant.C1 else nil,
			})
			if descendant:IsA("Weld") then
				descendant.Enabled = false
			elseif descendant:IsA("WeldConstraint") then
				descendant.Enabled = false
			end
			-- Disconnect endpoints so scaled cached constraint offsets cannot pull parts back.
			descendant:ResetPropertyToDefault("Part1")
		end
	end

	character:ScaleTo(scale)

	if weaponSize and weapon and weapon:IsA("Model") and main and main:IsA("BasePart") then
		local grip = main.CFrame
		if attachment then
			local ratio = attachment.Host.Size.X / attachment.HostSize.X
			grip = attachment.Host.CFrame * CFrame.new(attachment.Offset.Position * ratio) * attachment.Offset.Rotation
		end
		weapon:ScaleTo(weapon:GetScale() * weaponSize.X / main.Size.X)
		if (main.Size - weaponSize).Magnitude > 0.0001 then
			weapon:ScaleTo(weapon:GetScale() * weaponSize.X / main.Size.X)
		end
		weapon:PivotTo((grip * main.CFrame:Inverse()) * weapon:GetPivot())
	end
	for _, saved in joints do
		local joint = saved.Joint
		if joint:IsA("Weld") then
			if saved.C1 then
				joint.C1 = saved.C1
				joint.C0 = saved.Part0.CFrame:ToObjectSpace(saved.Part1.CFrame * saved.C1)
			end
			joint.Part0 = saved.Part0
			joint.Part1 = saved.Part1
			joint.Enabled = true
		elseif joint:IsA("WeldConstraint") then
			joint.Part0 = saved.Part0
			joint.Part1 = saved.Part1
			joint.Enabled = true
		end
	end

	humanoid.WalkSpeed = original.WalkSpeed
	humanoid.JumpHeight = original.JumpHeight
	humanoid.JumpPower = original.JumpPower
	root.AssemblyLinearVelocity = original.LinearVelocity
	root.AssemblyAngularVelocity = original.AngularVelocity
	-- HipHeight follows the rig size, and UseJumpPower is left unchanged.
end

return ShrinkScale
