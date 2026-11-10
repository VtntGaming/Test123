--!strict
-- Queues a shared physical scale timeline; joint offsets project that state outside simulation.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local State = require(ReplicatedStorage.Simulation.State)
local ActorTimelines = require(ReplicatedStorage.Simulation.ActorTimelines)
local Settings = require(ReplicatedStorage.SharedModules.AbilityConfig).Abilities.Shrink

--// Types
export type ShrinkScale = {
	-- Queues a body-scale path starting at the previous path's exact current scale, optionally scaling its weapon too.
	Apply: (Model, Humanoid, BasePart, number, boolean) -> (),
}

--// Controller
local ShrinkScale: ShrinkScale = {} :: ShrinkScale

--// APIs
function ShrinkScale.Apply(character, humanoid, root, scale, scaleWeapon)
	local record = State.Records[character]
	if not record then
		return
	end
	local ratio = scale / record.Scale
	State.Queue(character, function()
		local now = time()
		local from = ActorTimelines.Scale(character, now, true, (Attributes.Get(root, "SABodyScale") :: number?) or 1)
		character:SetAttribute("SAScaleFrom", from)
		character:SetAttribute("SAScaleTo", ratio)
		character:SetAttribute("SAScaleAt", now)
		character:SetAttribute("SAScaleDuration", Settings.TweenTime)
		Attributes.Set(root, "SAScaleWeapon", scaleWeapon)
	end)
end
return ShrinkScale
