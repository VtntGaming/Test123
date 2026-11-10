--!strict
-- Keeps the ability bootstrap compatible while the shared simulation owns physical and rendered scale.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Simulation = require(ReplicatedStorage.Simulation)
export type ShrinkEffect = { Init: () -> () }
local ShrinkEffect: ShrinkEffect = {} :: ShrinkEffect
function ShrinkEffect.Init()
	Simulation.Init()
end
return ShrinkEffect
