--!strict
--// Services
local Players = game:GetService("Players")

--// Modules
local ControllerFolder = script.Parent.Parent
local PullEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.Pull.PullEffect)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local LocalPlayer = Players.LocalPlayer

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
	if not character or not root then
		return
	end

	local config = AbilityConfig.Abilities.Pull
	local releaseTime = config.ReleaseTime or 0.35
	local forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	forward = if forward.Magnitude > 0.01 then forward.Unit else Vector3.zAxis

	local track: AnimationTrack? = nil
	local animator = context.Animator
	if animator and config.Animation then
		local animation = Instance.new("Animation")
		animation.AnimationId = config.Animation
		local newTrack = animator:LoadAnimation(animation)
		animation:Destroy()
		newTrack.Priority = Enum.AnimationPriority.Action2
		while newTrack.Length == 0 do
			task.wait()
		end
		newTrack:Play()
		track = newTrack
	end

	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Stop()
	end
	PullEffect.Cast(LocalPlayer, character, {
		aim = forward,
		range = config.Range,
		angle = config.Angle,
		releaseTime = releaseTime,
		startTime = workspace:GetServerTimeNow(),
	})
	task.wait(config.Duration or releaseTime)
	if track then
		track:Stop(0.1)
		track:Destroy()
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end
end

return AbilityPreview
