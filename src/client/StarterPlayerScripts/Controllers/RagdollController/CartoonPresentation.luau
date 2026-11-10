--!strict
-- Reads current predicted Cartoon state; rendering never writes the real root.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Actors = require(ReplicatedStorage.Knockback.Actors)
local State = require(ReplicatedStorage.Knockback.State)
local VisualRig = require(script.Parent.VisualRig)

--// Types
export type Controller = {
	Init: () -> (),
	GetState: (Instance) -> (string?, string?),
	GetVelocity: (Instance) -> Vector3?,
	GetPresentation: (Instance) -> State.Presentation?,
	GetDiagnostics: () -> { enabled: boolean, counters: { [string]: number } },
}

--// Properties
local Records: { [Instance]: State.Presentation } = {}
local Initialized = false

--// Controller
local Controller: Controller = {} :: Controller
function Controller.GetPresentation(actor)
	actor = VisualRig.Original(actor) or actor
	local root = Actors.GetRoot(actor)
	if not root then
		return nil
	end
	local current = State.Present(root)
	if not current then
		Records[actor] = nil
		return nil
	end
	current.generation = actor:GetAttribute("RagdollGeneration") :: string
	local record = Records[actor]
	local before = record and record.impacts[#record.impacts]
	local latest = current.impacts[#current.impacts]
	if
		not record
		or record.generation ~= current.generation
		or record.revision ~= current.revision
		or (
			before
			and (not latest or latest.id < before.id or (latest.id == before.id and latest.normal ~= before.normal))
		)
	then
		current.bootstrap = true
		Records[actor] = current
		return current
	end
	record.bootstrap = false
	record.phase, record.phaseTime = current.phase, current.phaseTime
	record.presentedTime, record.timestamp, record.impacts = current.presentedTime, current.timestamp, current.impacts
	return record
end
function Controller.GetState(actor)
	local record = Controller.GetPresentation(actor)
	return if record then record.phase else "Stop", if record then record.weaponId else nil
end
function Controller.GetVelocity(actor)
	local root = Actors.GetRoot(VisualRig.Original(actor) or actor)
	return if root then Attributes.Get(root, "KBVelocity") :: Vector3? else nil
end
function Controller.GetDiagnostics()
	return VisualRig.GetDiagnostics()
end
function Controller.Init()
	if Initialized then
		return
	end
	Initialized = true
	Actors.Init()
	VisualRig.Init()
	Actors.Observe(function() end, function(actor)
		Records[actor] = nil
	end)
end
return Controller
