--!strict
--// Services
local Players = game:GetService("Players")

--// Modules
local ControllerFolder = script.Parent.Parent
local ThrowEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.Throw.ThrowEffect)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local LocalPlayer = Players.LocalPlayer
local EquipmentShowcase = ShowcaseProperties.EquipmentShowcase

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
function AbilityPreview.ShowcaseAbility(context: AbilityPreviewContext)
	local character = context.Character
	local root = context.Root
	local animator = context.Animator
	if not character or not root or not animator then
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = `rbxassetid://{AbilityConfig.Abilities.Throw.Animation}`
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	track.Priority = Enum.AnimationPriority.Action2
	while track.Length == 0 do
		task.wait()
	end

	local start = time()
	track:Play()
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Stop()
	end
	task.wait(0.5)

	local config = AbilityConfig.Abilities.Throw
	local forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	forward = if forward.Magnitude > 0.01 then forward.Unit else Vector3.zAxis
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local origin = if hand and hand:IsA("BasePart") then hand.Position else root.Position + Vector3.new(0, 1, 0)
	local range = config.Range or 55
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { EquipmentShowcase }
	local hit = workspace:Raycast(origin, forward * range, raycastParams)
	if hit then
		range = math.max(6, hit.Distance - 2)
	end

	local weapon = character:FindFirstChild("EquippedWeapon") :: Model?
	local weaponName = weapon
		and (weapon:GetAttribute("WeaponName") or weapon:GetAttribute("WeaponId"))
		or LocalPlayer:GetAttribute("EquippedWeaponName")
	if type(weaponName) ~= "string" then
		weaponName = ""
	end
	if weapon then
		weapon.Name = "EquippedWeapon"
	end
	ThrowEffect.Launch(LocalPlayer, character, {
		origin = origin,
		forward = forward,
		range = range,
		curve = math.min(config.Curve or 12, range * 0.3),
		outTime = config.OutTime or 0.55,
		hoverTime = config.HoverTime or 0.3,
		returnTime = config.ReturnTime or 0.7,
		startTime = workspace:GetServerTimeNow(),
		weaponName = weaponName,
	})
	if weapon and weapon.Parent == character then
		weapon.Name = "EquippedWeapon"
	end

	ShowcaseProperties.UseSmoothCameraAnimation = true
	ShowcaseProperties.CameraFollowCharacter = true
	while time() - start < 3 do
		task.wait()
		local combatLocalEffects = workspace:FindFirstChild("CombatLocalEffects")
		local currentWeapon = combatLocalEffects and combatLocalEffects:FindFirstChild("ThrownWeapon")
		if currentWeapon and currentWeapon:IsA("Model") then
			ShowcaseProperties.CustomFollowPosition = currentWeapon:GetPivot().Position
		else
			ShowcaseProperties.CustomFollowPosition = nil
		end
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end
	track:Stop()
	track:Destroy()
end

return AbilityPreview
