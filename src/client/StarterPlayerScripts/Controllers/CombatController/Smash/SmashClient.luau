--!strict
-- Presents Smash anticipation and dive feedback without controlling predicted character physics.

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local SmashEffect = require(script.Parent.SmashEffect)
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)

--// Types
type Context = {
	config: typeof(AbilityConfig.Abilities.Smash),
	character: Model,
	root: BasePart,
	humanoid: Humanoid,
	defaultFov: number,
	setFov: (number, number) -> (),
	alive: () -> boolean,
	onImpact: (Vector3) -> (),
	onFinish: () -> (),
}
export type SmashClient = { Start: (Context) -> () -> () }

--// Controller
local SmashClient: SmashClient = {} :: SmashClient

--// APIs
function SmashClient.Start(ctx)
	local player = Players.LocalPlayer :: Player
	local started = Attributes.Get(ctx.humanoid, "SAAbilityStarted") :: number
	local upTime = (ctx.config.ImpactTime - ctx.config.DiveAnimTime) / ctx.config.RiseSpeed
	local riseTime = upTime * ctx.config.RiseFraction
	local cancelled, hung, diving = false, false, false
	local connection: RBXScriptConnection?
	local function cleanup()
		if cancelled then
			return
		end
		cancelled = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		SmashEffect.StopTelegraph(player)
		ctx.setFov(ctx.defaultFov, 0.25)
	end
	SmashEffect.Takeoff(ctx.root.Position - Vector3.yAxis * (ctx.humanoid.HipHeight + ctx.root.Size.Y / 2))
	SmashEffect.StartTelegraph(player, ctx.character, ctx.config.HitRadius)
	ctx.setFov(ctx.defaultFov + 10, riseTime)
	connection = RunService.PreRender:Connect(function()
		if cancelled then
			return
		end
		if not ctx.alive() then
			cleanup()
			return
		end
		local elapsed = time() - started
		if not hung and elapsed >= riseTime then
			hung = true
			ctx.setFov(ctx.defaultFov + 18, math.max(0.2, upTime - riseTime))
			SmashEffect.Rumble(1.4, math.max(0.2, upTime - riseTime))
		end
		if not diving and elapsed >= upTime then
			diving = true
			ctx.setFov(ctx.defaultFov + 28, 0.12)
			SmashEffect.Dive(ctx.root.Position)
		end
		if
			Attributes.Get(ctx.humanoid, "SASmashImpact") == true
			or time() >= ((Attributes.Get(ctx.humanoid, "SAAbilityEndsAt") :: number?) or started + upTime + 5)
		then
			cleanup()
			ctx.onFinish()
		end
	end)
	return cleanup
end
return SmashClient
