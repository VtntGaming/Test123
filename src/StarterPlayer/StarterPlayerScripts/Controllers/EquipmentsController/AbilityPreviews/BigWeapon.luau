--!strict
--// Services
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local EquipmentShowcase = ShowcaseProperties.EquipmentShowcase

--// Properties
local AbilityPreview = {}
local BigWeaponPreview = nil :: { Weapon: Model, BaseScale: number }?

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
local function ScalePreviewWeapon(weapon: Model, scale: number)
	local main = weapon:FindFirstChild("Main", true)
	if not main or not main:IsA("BasePart") then
		return
	end
	local mainFrame = main.CFrame
	local grips: { { Joint: WeldConstraint, Part1: BasePart } } = {}
	for _, descendant in weapon:GetDescendants() do
		if descendant:IsA("WeldConstraint") and descendant.Enabled then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 and (not part0:IsDescendantOf(weapon) or not part1:IsDescendantOf(weapon)) then
				table.insert(grips, { Joint = descendant, Part1 = part1 })
				descendant.Enabled = false
				descendant.Part1 = nil :: any
			end
		end
	end
	weapon:ScaleTo(scale)
	weapon:PivotTo(mainFrame * main.CFrame:Inverse() * weapon:GetPivot())
	for _, grip in grips do
		grip.Joint.Part1 = grip.Part1
		grip.Joint.Enabled = true
	end
end

function AbilityPreview.ShowcaseAbility(context: AbilityPreviewContext)
	local weapon = context.Weapon
	local character = context.Character
	if not weapon or not character then
		return
	end
	local config = AbilityConfig.Abilities.BigWeapon
	local baseScale = context.LastWeaponOriginScale
	local targetScale = baseScale * config.Scale
	BigWeaponPreview = { Weapon = weapon, BaseScale = baseScale }

	local function animateScale(fromScale: number, toScale: number, duration: number, direction: Enum.EasingDirection): boolean
		local startedAt = time()
		repeat
			if weapon.Parent ~= character or character.Parent ~= EquipmentShowcase then
				return false
			end
			local alpha = if duration > 0 then math.min((time() - startedAt) / duration, 1) else 1
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, direction)
			ScalePreviewWeapon(weapon, math.lerp(fromScale, toScale, eased))
			if alpha >= 1 then
				return true
			end
			task.wait()
		until false
	end

	local start = time()
	ShowcaseProperties.UseSmoothCameraAnimation = true
	ShowcaseProperties.CameraOffset = Vector3.new(0, 0, 10)
	local grew = animateScale(baseScale, targetScale, config.GrowTime, Enum.EasingDirection.Out)
	while grew and weapon.Parent == character and character.Parent == EquipmentShowcase
		and time() - start < config.Duration do
		task.wait()
	end
	ShowcaseProperties.CameraOffset = Vector3.zero
	if grew then
		animateScale(targetScale, baseScale, config.ShrinkTime, Enum.EasingDirection.InOut)
	end
	if weapon.Parent then
		ScalePreviewWeapon(weapon, baseScale)
	end
	BigWeaponPreview = nil
	task.wait(1)
end

function AbilityPreview.StopBigWeaponPreview()
	local preview = BigWeaponPreview
	if not preview then
		return
	end
	BigWeaponPreview = nil
	if ShowcaseProperties.AbilityShowcaseThread then
		task.cancel(ShowcaseProperties.AbilityShowcaseThread)
		ShowcaseProperties.AbilityShowcaseThread = nil
	end
	if preview.Weapon.Parent then
		ScalePreviewWeapon(preview.Weapon, preview.BaseScale)
	end
	ShowcaseProperties.UseSmoothCameraAnimation = false
	ShowcaseProperties.CameraOffset = Vector3.zero
end

function AbilityPreview.StopPreview()
	AbilityPreview.StopBigWeaponPreview()
end

return AbilityPreview
