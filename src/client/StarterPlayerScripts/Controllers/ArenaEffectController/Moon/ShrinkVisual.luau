--!strict
-- Moon now renders the shared physical surface directly; no local collision clone is needed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Arena = require(ReplicatedStorage.Simulation.Arena)
export type ShrinkVisual = { Init: () -> (), Setup: (ShrinkVisual) -> (), Start: (ShrinkVisual) -> () }
local ShrinkVisual: ShrinkVisual = {} :: ShrinkVisual
function ShrinkVisual:Setup()
	Arena.Init()
end
function ShrinkVisual:Start() end
function ShrinkVisual.Init()
	ShrinkVisual:Setup()
	ShrinkVisual:Start()
end
return ShrinkVisual
