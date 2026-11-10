--!strict
-- Shared data only. Server-only ragdoll settings live under RagdollService.Config.
local Animation = require(script:WaitForChild("Animation"))
local Weapon = require(script:WaitForChild("Weapon"))
local Network = require(script:WaitForChild("Network"))
return table.freeze({Animation = Animation, Weapon = Weapon, Network = Network})

