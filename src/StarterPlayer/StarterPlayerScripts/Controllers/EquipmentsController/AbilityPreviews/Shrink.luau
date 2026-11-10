--!strict
--// Services
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local ShrinkScale = require(game:GetService("ReplicatedStorage").SharedModules.ShrinkScale)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
local function ApplyCharacterScale(character: Model, scale: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	ShrinkScale.Apply(character, humanoid, root, scale, AbilityConfig.Abilities.Shrink.ScaleWeapon)
	ShowcaseProperties.CurrentCharScale = scale
end

AbilityPreview.ApplyCharacterScale = ApplyCharacterScale

function AbilityPreview.ShowcaseAbility(_context: AbilityPreviewContext)
	local character = _context.Character
	if not character then
		return
	end
	ShowcaseProperties.ShrinkPreviewCharacter = character

	local targetScale = AbilityConfig.Abilities.Shrink.Scale
	local shrinkDuration = 0.25
	local start = time()

	while time() - start < shrinkDuration do
		local alpha = (time() - start) / shrinkDuration
		local value = TweenService:GetValue(
			alpha,
			Enum.EasingStyle.Quart,
			Enum.EasingDirection.Out
		)
		ShowcaseProperties.CharacterScale = math.lerp(1, targetScale, value)
		task.wait()
	end

	ShowcaseProperties.CharacterScale = targetScale
	task.wait(AbilityConfig.Abilities.Shrink.Duration - shrinkDuration)
	ShowcaseProperties.CharacterScale = 1
	if character.Parent then
		ApplyCharacterScale(character, 1)
	end
	ShowcaseProperties.ShrinkPreviewCharacter = nil
end

function AbilityPreview.StopShrinkPreview()
	local character = ShowcaseProperties.ShrinkPreviewCharacter
	if not character then
		return
	end
	ShowcaseProperties.ShrinkPreviewCharacter = nil
	if ShowcaseProperties.AbilityShowcaseThread then
		task.cancel(ShowcaseProperties.AbilityShowcaseThread)
		ShowcaseProperties.AbilityShowcaseThread = nil
	end
	ShowcaseProperties.CharacterScale = 1
	if character.Parent then
		ApplyCharacterScale(character, 1)
	end
end

function AbilityPreview.StopPreview()
	AbilityPreview.StopShrinkPreview()
end

return AbilityPreview
