--!strict
--// Services
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local ControllerFolder = script.Parent.Parent
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
function AbilityPreview.ShowcaseAbility(context: AbilityPreviewContext)
	local start = time()
	local dashOutTime = 0.25
	local dashOutDistance = 100
	local lastHologram = 0
	local hologramDelay = 0.04
	local trackSpeed = 10

	SoundService:PlayLocalSound(SFXFolder.Dash)
	while time() - start < dashOutTime do
		local elapsed = time() - start
		local alpha = elapsed / dashOutTime
		local value = TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.In)
		if context.Character and time() - lastHologram >= hologramDelay then
			context.SpawnDashHologram(context.Character, 1 - alpha)
			lastHologram = time()
		end
		local currentTrack = ShowcaseProperties.ExistingRunningTrack
		if currentTrack then
			currentTrack:AdjustSpeed(1 + alpha * trackSpeed)
		end
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, 0, -dashOutDistance * value)
		task.wait()
	end

	local dashInTime = 0.5
	local dashInDistance = 200
	start = time()
	SoundService:PlayLocalSound(SFXFolder.Complete)
	while time() - start < dashInTime do
		local elapsed = time() - start
		local alpha = elapsed / dashInTime
		local value = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
		if context.Character and time() - lastHologram >= hologramDelay then
			context.SpawnDashHologram(context.Character, alpha)
			lastHologram = time()
		end
		local currentTrack = ShowcaseProperties.ExistingRunningTrack
		if currentTrack then
			currentTrack:AdjustSpeed(1 + (1 - alpha) * trackSpeed)
		end
		ShowcaseProperties.CharacterVectorOffset = Vector3.new(0, 0, dashInDistance * value)
		task.wait()
	end
end

return AbilityPreview
