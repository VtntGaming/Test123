--!strict
--// Modules
local ControllerFolder = script.Parent.Parent
local AbilityConfig = require(game:GetService("ReplicatedStorage").SharedModules.AbilityConfig)
local ShowcaseProperties = require(ControllerFolder.ShowcaseProperties)
local AbilityPreviewTypes = require(ControllerFolder.AbilityPreviewTypes)

--// Properties
local AbilityPreview = {}

--// Types
type AbilityPreviewContext = typeof(AbilityPreviewTypes.AbilityPreviewContext)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)
export type AbilityPreview = AbilityPreviewModule

--// APIs
function AbilityPreview.ShowcaseAbility(_context: AbilityPreviewContext)
	local start = time()
	local targetTransparency = AbilityConfig.Abilities.Invisible.Transparency
	local duration = AbilityConfig.Abilities.Invisible.Duration
	local shrinkTime = 0.25

	while time() - start < shrinkTime do
		local alpha = (time() - start) / shrinkTime
		ShowcaseProperties.CharacterTransparency = math.lerp(0, targetTransparency, alpha)
		task.wait()
	end

	ShowcaseProperties.CharacterTransparency = targetTransparency
	task.wait(duration - shrinkTime)
end

return AbilityPreview
