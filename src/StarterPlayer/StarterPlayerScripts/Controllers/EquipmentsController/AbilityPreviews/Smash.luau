--!strict
--// Services
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
local Dummy = require(ControllerFolder.Dummy)
local SmashEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.Smash.SmashEffect)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local LocalPlayer = game:GetService("Players").LocalPlayer
local Camera = workspace.CurrentCamera :: Camera

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
function AbilityPreview.ShowcaseAbility(context: AbilityPreviewContext)
	local animator = context.Animator
	local currentCharacter = context.Character
	if not animator or not currentCharacter then
		return
	end

	local config = AbilityConfig.Abilities.Smash
	local impactTime = config.ImpactTime
	local jumpHeight = config.JumpHeight
	local hitRadius = config.HitRadius
	local cameraBackDistancePeak = 25
	local cameraBackDistanceMid = 20
	local cameraRestoreTime = 2
	local animation = Instance.new("Animation")
	animation.AnimationId = config.M2
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	track.Priority = Enum.AnimationPriority.Action2
	while track.Length == 0 do
		task.wait()
	end

	local start = time()
	track:Play()
	local characterCFrame = ShowcaseProperties.CharacterCFrame
	local characterPosition = characterCFrame.Position
	SmashEffect.Dive(characterPosition)
	SmashEffect.Takeoff(characterPosition)
	ShowcaseProperties.CameraFollowCharacter = true
	ShowcaseProperties.UseSmoothCameraAnimation = true
	local dummyCFrame = characterCFrame * CFrame.new(0, -3, 0)
	local pushDirection = (Camera.CFrame * CFrame.Angles(0, math.rad(-45), 0)).LookVector
	local dummy: Dummy.DummyType? = nil

	while time() - start < impactTime do
		local alpha = (time() - start) / impactTime
		if alpha <= 0.7 then
			alpha /= 0.7
		else
			alpha = 1 - (alpha - 0.7) / 0.3
		end
		local value = TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
		local distance = 0
		if alpha <= 0.7 then
			distance = cameraBackDistancePeak * value
		else
			if not dummy then
				dummy = Dummy.new(dummyCFrame)
				SmashEffect.StartTelegraph(LocalPlayer, currentCharacter)
			end
			distance = math.lerp(cameraBackDistanceMid, cameraBackDistancePeak, value)
		end
		ShowcaseProperties.CameraOffset = Vector3.new(0, 0, distance)
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
		task.wait()
	end

	if dummy then
		dummy:Push(pushDirection, 30, 30)
	end
	start = time()
	SmashEffect.Impact(currentCharacter:GetPivot().Position + Vector3.new(0, -8, 0), hitRadius)
	ShowcaseProperties.CameraOffset = Vector3.new(0, 0, cameraBackDistanceMid)
	ShowcaseProperties.CharacterVectorOffset = Vector3.zero
	ShowcaseProperties.CameraFollowCharacter = false
	SmashEffect.StopTelegraph(LocalPlayer)
	while time() - start < cameraRestoreTime do
		local alpha = (time() - start) / cameraRestoreTime
		local value = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
		ShowcaseProperties.CameraOffset = Vector3.new(0, 0, cameraBackDistanceMid * value)
		task.wait()
	end
	track:Stop()
	track:Destroy()
end

function AbilityPreview.StopPreview()
	SmashEffect.StopTelegraph(LocalPlayer)
end

return AbilityPreview
