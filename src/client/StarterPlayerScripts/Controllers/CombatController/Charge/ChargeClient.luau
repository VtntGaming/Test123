--!strict
-- Presents local Charge feedback; the shared simulation owns movement and animation.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local ChargeEffect = require(script.Parent.ChargeEffect)
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)

--// Types
type Context = {
	config: typeof(AbilityConfig.Abilities.Charge),
	character: Model,
	root: BasePart,
	humanoid: Humanoid,
	defaultFov: number,
	setFov: (number, number) -> (),
	alive: () -> boolean,
}
export type ChargeClient = { Start: (Context) -> () -> () }

--// Controller
local ChargeClient: ChargeClient = {} :: ChargeClient

--// APIs
function ChargeClient.Start(ctx)
	local player = Players.LocalPlayer :: Player
	ChargeEffect.Start(player, ctx.character, ctx.config.Duration)
	ctx.setFov(ctx.defaultFov + 14, 0.2)
	return function()
		ChargeEffect.Stop(player)
		ctx.setFov(ctx.defaultFov, 0.3)
	end
end
return ChargeClient
