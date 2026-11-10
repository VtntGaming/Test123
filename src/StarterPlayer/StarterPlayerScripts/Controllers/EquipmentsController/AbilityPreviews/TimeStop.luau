--!strict
--// Services
local Players = game:GetService("Players")

--// Modules
local ControllerFolder = script.Parent.Parent
local Dummy = require(ControllerFolder.Dummy)
local TimeStopEffect = require(game:GetService("StarterPlayer").StarterPlayerScripts.Controllers.CombatController.TimeStop.TimeStopEffect)
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
	if not character then
		return
	end
	ShowcaseProperties.TimeStopPreviewActive = true
	local config = AbilityConfig.Abilities.TimeStop
	local readyTime = config.ReadyTime
	local stopDuration = config.StopDuration
	local start = time()
	TimeStopEffect.Ready(LocalPlayer, character, {
		readyTime = readyTime,
		soundMode = config.ReadySoundMode,
	})

	local dummy = Dummy.new(character:GetPivot() * CFrame.new(0, -3, -4) * CFrame.Angles(0, math.rad(180), 0))
	while time() - start < readyTime do
		task.wait()
	end
	TimeStopEffect.Start(LocalPlayer, character, {
		stopDuration = stopDuration,
		since = workspace:GetServerTimeNow(),
	})

	local punchCount = 0
	local nextPunch = readyTime + 0.5
	while time() - start < readyTime + stopDuration do
		task.wait()
		local elapsed = time() - start
		if elapsed >= nextPunch then
			punchCount += 1
			TimeStopEffect.Mark(dummy.Model, punchCount)
			local attackTrack = ShowcaseProperties.ExistingAttackTrack
			if attackTrack then
				attackTrack:Play()
			end
			nextPunch += 0.5 + math.random() * 0.5
		end
	end

	TimeStopEffect.End(LocalPlayer)
	ShowcaseProperties.TimeStopPreviewActive = false
end

function AbilityPreview.StopTimeStopPreview()
	if not ShowcaseProperties.TimeStopPreviewActive then
		return
	end
	ShowcaseProperties.TimeStopPreviewActive = false
	if ShowcaseProperties.AbilityShowcaseThread then
		task.cancel(ShowcaseProperties.AbilityShowcaseThread)
		ShowcaseProperties.AbilityShowcaseThread = nil
	end
	TimeStopEffect.Cancel(LocalPlayer, true)
	Dummy.DestroyAll()
end

function AbilityPreview.StopPreview()
	AbilityPreview.StopTimeStopPreview()
end

return AbilityPreview
