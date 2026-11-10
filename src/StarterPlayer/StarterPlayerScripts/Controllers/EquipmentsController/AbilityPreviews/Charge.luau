--!strict
--// Services
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
local ChargeEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.Charge.ChargeEffect)
local Dummy = require(ControllerFolder.Dummy)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// References
local LocalPlayer = game:GetService("Players").LocalPlayer
local SFXFolder = SoundService.SFX

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
function AbilityPreview.ShowcaseAbility(context: AbilityPreviewContext)
	local currentCharacter = context.Character
	local animator = context.Animator
	if not currentCharacter or not animator then
		return
	end
	local config = AbilityConfig.Abilities.Charge
	local duration = config.Duration
	local animation = Instance.new("Animation")
	animation.AnimationId = `rbxassetid://{config.Animation}`
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	track.Priority = Enum.AnimationPriority.Movement
	while track.Length == 0 do
		task.wait()
	end

	if ShowcaseProperties.ExistingRunningTrack then
		ShowcaseProperties.ExistingRunningTrack:Stop()
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Stop()
	end
	track:Play()

	local start = time()
	local dashOutTime = 0.75
	local dashOutDistance = 100
	local lastHologram = 0
	local hologramDelay = 0.04
	local trackSpeed = 5
	local dashInTime = 1.5
	local dashInDistance = 200
	ChargeEffect.Start(LocalPlayer, currentCharacter, duration)
	while time() - start < dashOutTime do
		local elapsed = time() - start
		local alpha = elapsed / dashOutTime
		local value = TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
		if time() - lastHologram >= hologramDelay then
			context.SpawnDashHologram(currentCharacter, 1 - alpha)
			lastHologram = time()
		end
		track:AdjustSpeed(1 + alpha * trackSpeed)
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, 0, -dashOutDistance * value)
		task.wait()
	end

	local x, y, z = currentCharacter:GetPivot():ToEulerAnglesXYZ()
	local dummy = Dummy.new(ShowcaseProperties.CharacterCFrame * CFrame.Angles(x, y, z) * CFrame.new(0, -3, 10))
	start = time()
	SoundService:PlayLocalSound(SFXFolder.Complete)
	while time() - start < dashInTime do
		local elapsed = time() - start
		local alpha = elapsed / dashInTime
		local value = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
		if time() - lastHologram >= hologramDelay then
			context.SpawnDashHologram(currentCharacter, alpha)
			lastHologram = time()
		end
		track:AdjustSpeed(1 + (1 - alpha) * trackSpeed)
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, 0, dashInDistance * value)
		task.wait()
	end

	track:Stop()
	track:Destroy()
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end
	if ShowcaseProperties.ExistingRunningTrack then
		ShowcaseProperties.ExistingRunningTrack:AdjustSpeed(1)
		ShowcaseProperties.ExistingRunningTrack:Play()
	end

	dummy:Push(currentCharacter:GetPivot().LookVector, 50, 10)
	ChargeEffect.Impact(LocalPlayer, ShowcaseProperties.CharacterCFrame.Position)
	ChargeEffect.ChargerHit(10)
	ChargeEffect.Stop(LocalPlayer)
	ShowcaseProperties.CharacterVectorOffset = Vector3.zero
	ShowcaseProperties.CameraFollowCharacter = false
	ShowcaseProperties.UseSmoothCameraAnimation = true

	local trackTime = 1
	start = time()
	while time() - start < trackTime do
		task.wait()
		local model = dummy.Model
		local cFrame = model and model:GetPivot()
		ShowcaseProperties.CustomFollowPosition = if cFrame then cFrame.Position else nil
	end
	ShowcaseProperties.CustomFollowPosition = nil
	task.wait(1)
end

function AbilityPreview.StopPreview()
	ChargeEffect.Stop(LocalPlayer)
end

return AbilityPreview
