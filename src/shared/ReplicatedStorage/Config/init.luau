--!strict
-- Shared data only. Server-only ragdoll settings live under RagdollService.Config.
local Animation = require(script:WaitForChild("Animation"))
local Weapon = require(script:WaitForChild("Weapon"))
local Simulation = require(script.Simulation)
return table.freeze({ Animation = Animation, Weapon = Weapon, Simulation = Simulation })

