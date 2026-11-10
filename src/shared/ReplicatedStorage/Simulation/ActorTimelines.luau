--!strict
-- Evaluates actor scale and drop-in paths from replicated parameters, never from the previous frame.
-- Gameplay samples these paths in a dedicated callback; presentation can sample the same paths at render time.

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Types = require(script.Parent.Types)
local Attributes = require(script.Parent.Attributes)
local Timelines = require(script.Parent.Timelines)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)

--// References
local IsServer = RunService:IsServer()
local LocalPlayer = Players.LocalPlayer
local LocalSimulation = SimulationConfig.ClientSimulation.LocalPlayer

--// Types
export type Drop = {
	-- Synchronized simulation timestamp at which the path starts, in seconds.
	At: number,
	-- Seconds from the starting transform to the destination.
	Duration: number,
	-- Complete starting transform, including orientation.
	From: CFrame,
	-- Complete destination transform, including orientation.
	To: CFrame,
	-- Teleport revision identifying this drop, used by the server's completion listener.
	Token: number,
}
export type ActorTimelines = {
	-- Evaluates a complete scale description; returns the fallback during partial replication and whether presentation is changing.
	Scale: (Instance, number, boolean, number) -> (number, boolean),
	-- Reads a complete drop description, or nil while absent or partially replicated.
	Drop: (BasePart) -> Drop?,
	-- Projects absolute-time scales and drop paths onto eligible physical actors, including drop completion markers.
	Project: ({ [Types.Actor]: Types.ActorRecord }, number) -> (),
}

--// Controller
local ActorTimelines: ActorTimelines = {} :: ActorTimelines

--// APIs
function ActorTimelines.Scale(instance, now, eased, current)
	local at = instance:GetAttribute("SAScaleAt") :: number?
	local duration = instance:GetAttribute("SAScaleDuration") :: number?
	local from = instance:GetAttribute("SAScaleFrom") :: number?
	local target = instance:GetAttribute("SAScaleTo") :: number?
	if at == nil or duration == nil or from == nil or target == nil then
		return current, false
	end
	local scale = Timelines.Scale(now, at, duration, from, target, eased)
	return scale, now < at + duration or math.abs(scale - current) > 0.0001
end

function ActorTimelines.Drop(root)
	local at = Attributes.Get(root, "SADropAt") :: number?
	local duration = Attributes.Get(root, "SADropDuration") :: number?
	local from = Attributes.Get(root, "SADropFrom") :: CFrame?
	local destination = Attributes.Get(root, "SADropTo") :: CFrame?
	local token = Attributes.Get(root, "SADropToken") :: number?
	if at == nil or duration == nil or from == nil or destination == nil or token == nil then
		return nil
	end
	return { At = at, Duration = duration, From = from, To = destination, Token = token }
end

function ActorTimelines.Project(records, now)
	for _, record in records do
		local root = record.Root
		if
			not record.Ready
			or (not IsServer and RunService:GetPredictionStatus(root) ~= Enum.PredictionStatus.Predicted)
		then
			continue
		end
		local bodyScaling = IsServer or record.Owner ~= LocalPlayer or LocalSimulation.BodyScaling
		local weaponScaling = IsServer or record.Owner ~= LocalPlayer or LocalSimulation.WeaponScaling
		local bodyScale = (Attributes.Get(root, "SABodyScale") :: number?) or 1
		local weaponScale = (Attributes.Get(root, "SAWeaponScale") :: number?) or 1
		local revision = (record.Actor:GetAttribute("WeaponRevision") :: number?) or 0
		if Attributes.Get(root, "SAWeaponScaleRevision") ~= revision then weaponScale = 1 end
		if bodyScaling then
			bodyScale = ActorTimelines.Scale(record.Actor, now, true, bodyScale)
			Attributes.Set(root, "SABodyScale", bodyScale)
		end
		if weaponScaling and record.Weapon then
			weaponScale = ActorTimelines.Scale(record.Weapon, now, false, weaponScale)
			Attributes.Set(root, "SAWeaponScale", weaponScale)
			Attributes.Set(root, "SAWeaponScaleRevision", revision)
		end
		local includeWeapon = Attributes.Get(root, "SAScaleWeapon") == true
		for _, item in record.Geometry do
			if item.Part.Parent and (if item.Weapon then weaponScaling else bodyScaling) then
				local scale = if item.Weapon then weaponScale * (if includeWeapon then bodyScale else 1) else bodyScale
				item.Part.Size = item.Size * scale
			end
		end
		local humanoid = record.Humanoid
		if bodyScaling and humanoid then
			humanoid.HipHeight = record.HipHeight * bodyScale
		end
		if not humanoid or not record.Alive or (not IsServer and record.Owner ~= LocalPlayer) then
			continue
		end
		local drop = ActorTimelines.Drop(root)
		if drop then
			root.CFrame = Timelines.Drop(drop.From, drop.To, now, drop.At, drop.Duration)
			root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
			local completed = Timelines.Progress(now, drop.At, drop.Duration) >= 1
			root.Anchored = not completed
			humanoid.Jump = false
			humanoid.WalkSpeed = 0
			if completed then
				Attributes.Set(root, "SADropAt", nil)
				Attributes.Set(root, "SADropDone", drop.Token)
			end
		end
	end
end

return ActorTimelines
