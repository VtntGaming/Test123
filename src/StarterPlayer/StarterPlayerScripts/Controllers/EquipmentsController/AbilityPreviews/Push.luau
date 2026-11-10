--!strict
--// Services
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

--// Modules
local ControllerFolder = script.Parent.Parent
local Dummy = require(ControllerFolder.Dummy)
local PushEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.Push.PushEffect)
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

	local config = AbilityConfig.Abilities.Push
	local releaseTime = 0.15
	local forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	forward = if forward.Magnitude > 0.01 then forward.Unit else Vector3.zAxis

	local track: AnimationTrack? = nil
	local animator = context.Animator
	if animator and config.Animation then
		local animation = Instance.new("Animation")
		local animationId = tostring(config.Animation)
		if not string.find(animationId, "rbxassetid://", 1, true) then
			animationId = `rbxassetid://{animationId}`
		end
		animation.AnimationId = animationId
		local newTrack = animator:LoadAnimation(animation)
		animation:Destroy()
		while newTrack.Length == 0 do
			task.wait()
		end
		newTrack.Priority = Enum.AnimationPriority.Action2
		newTrack:Play()
		track = newTrack
	end

	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Stop()
	end
	PushEffect.Cast(LocalPlayer, character, {
		aim = forward,
		range = config.Range,
		angle = config.Angle,
		releaseTime = releaseTime,
		startTime = workspace:GetServerTimeNow(),
	})

	local charCFrame = character:GetPivot()
	local dummy = Dummy.new(charCFrame * CFrame.new(0, -3, -10) * CFrame.Angles(0, math.rad(180), 0))
	task.wait(0.15)
	dummy:Push(charCFrame.LookVector, 50, 20)
	if track then
		track:Stop(1)
		Debris:AddItem(track, 1.5)
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end

	local start = time()
	ShowcaseProperties.UseSmoothCameraAnimation = true
	ShowcaseProperties.CameraFollowCharacter = true
	while time() - start < 1 do
		task.wait()
		local model = dummy.Model
		local cFrame = model and model:GetPivot()
		ShowcaseProperties.CustomFollowPosition = if cFrame then cFrame.Position else nil
	end
	ShowcaseProperties.CustomFollowPosition = nil
	task.wait(1)
end

return AbilityPreview
