--!strict
--// Services
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
local GameplayController = require(ControllerFolder.Parent.GameplayController)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local SFXFolder = SoundService.SFX

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
function AbilityPreview.ShowcaseAbility(_context: AbilityPreviewContext)
	local start = time()
	local jumpTime = 0.5
	local jumpHeight = 65
	local fallTime = 1.5
	local cameraDistance = 30

	SoundService:PlayLocalSound(SFXFolder.Jump)
	local root = _context.Root
	if root then
		GameplayController.PlayVFX("JumpEffect", root.CFrame + Vector3.new(0, -2, 0))
	end
	ShowcaseProperties.CameraFollowCharacter = true
	ShowcaseProperties.UseSmoothCameraAnimation = true
	while time() - start < jumpTime do
		local elapsed = time() - start
		local alpha = elapsed / jumpTime
		local value = TweenService:GetValue(alpha, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
		ShowcaseProperties.CameraOffset = Vector3.new(0, 0, cameraDistance * value)
		task.wait()
	end

	start = time()
	while time() - start < fallTime do
		local elapsed = time() - start
		local alpha = elapsed / fallTime
		local value = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		ShowcaseProperties.CameraOffset = Vector3.new(0, 0, cameraDistance * value)
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
		task.wait()
	end

	ShowcaseProperties.CameraOffset = Vector3.zero
	ShowcaseProperties.CharacterVectorOffset = Vector3.zero
	task.wait(0.25)
end

return AbilityPreview
