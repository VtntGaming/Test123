--!strict
-- Coordinates visual-rig reactions, tilt, trails and camera ownership for real actor lifetimes.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local Actors = require(ReplicatedStorage.Knockback.Actors)
local Config = require(ReplicatedStorage.Config.Animation)
local SimulationConfig = require(ReplicatedStorage.Config.Simulation)
local Motion = require(script.CartoonPresentation)
local VisualRig = require(script.VisualRig)
local Reactions = require(script.Reactions)
local Tilt = require(script.Tilt)

--// References
local LocalPlayer = Players.LocalPlayer :: Player

--// Types
type Record = {
	Actor: Actors.Actor,
	Visual: VisualRig.Record,
	Reactions: Reactions.State,
	Tilt: Tilt.State,
	Trail: Trail?,
	Attachments: { Attachment },
	RecoveringAt: number?,
	Revision: number,
}
export type Controller = { Init: () -> (), Setup: (Controller) -> (), Start: (Controller) -> () }

--// Properties
local Records: { [Actors.Actor]: Record } = {}
local Initialized = false

--// Controller
local Controller: Controller = {} :: Controller
local function Release(actor: Actors.Actor, keepVisual: boolean?)
	local record = Records[actor]
	if not record then
		if not keepVisual then
			VisualRig.Release(actor)
		end
		return
	end
	Records[actor] = nil
	Reactions.Destroy(record.Reactions)
	Tilt.Reset(record.Tilt)
	if record.Trail then
		record.Trail:Destroy()
	end
	for _, attachment in record.Attachments do
		attachment:Destroy()
	end
	if not keepVisual then
		VisualRig.Release(actor)
	end
end
local function Acquire(actor: Actors.Actor, root: BasePart): Record?
	local old = Records[actor]
	if
		old
		and not old.Visual.Destroyed
		and old.Visual.Generation == actor:GetAttribute("RagdollGeneration")
		and old.Revision == Attributes.Get(root, "KBSession")
		and old.Visual.SourceRoot == root
	then
		return old
	end
	Release(
		actor,
		old ~= nil
			and not old.Visual.Destroyed
			and old.Visual.SourceRoot == root
			and old.Visual.Generation == actor:GetAttribute("RagdollGeneration")
	)
	local visual = VisualRig.Acquire(actor, root)
	if not visual then
		return nil
	end
	local record: Record = {
		Actor = actor,
		Visual = visual,
		Reactions = Reactions.New(),
		Tilt = Tilt.New(),
		Trail = nil,
		Attachments = {},
		RecoveringAt = nil,
		Revision = (Attributes.Get(root, "KBSession") :: number?) or 0,
	}
	Records[actor] = record
	local body = visual.Model:FindFirstChild("UpperTorso") or visual.Model:FindFirstChild("Torso") or visual.Root
	if body:IsA("BasePart") and ReplicatedValues.GetBoolean(actor, "RagdollShowTrail") ~= false then
		local first, second = Instance.new("Attachment"), Instance.new("Attachment")
		local halfWidth = math.clamp(body.Size.X * 0.3, 0.3, 1.2) * 0.5
		first.Position, second.Position =
			Vector3.new(-halfWidth, 0, body.Size.Z * 0.5), Vector3.new(halfWidth, 0, body.Size.Z * 0.5)
		first.Parent, second.Parent = body, body
		local trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = first, second
		trail.Lifetime, trail.FaceCamera, trail.LightEmission = 0.2, true, 1
		trail.MaxLength, trail.MinLength, trail.LightInfluence = 8, 0.05, 0
		trail.Transparency = NumberSequence.new(0.2, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
		trail.Parent = body
		record.Trail, record.Attachments = trail, { first, second }
	end
	return record
end
function Controller:Setup()
	Motion.Init()
	Reactions.Preload()
end
function Controller:Start()
	if not SimulationConfig.ClientPresentation.CartoonVisualRigs then
		return
	end
	Actors.Observe(function() end, function(actor)
		Release(actor)
	end)
	RunService.PreAnimation:Connect(function(dt: number)
		for _, actor in Actors.GetAll() do
			local root = Actors.GetRoot(actor)
			if not root then
				Release(actor)
				continue
			end
			local active = Attributes.Get(root, "KBActive") == true
			local record: Record? = Records[actor]
			if active then
				record = Acquire(actor, root)
				if record then
					record.RecoveringAt = nil
				end
			elseif record and record.Visual.Generation == actor:GetAttribute("RagdollGeneration") then
				local recoveringAt = record.RecoveringAt or os.clock()
				record.RecoveringAt = recoveringAt
				if os.clock() - recoveringAt >= Config.RestToNormalFadeTime then
					Release(actor)
					continue
				end
			else
				Release(actor)
				continue
			end
			if not record then
				continue
			end
			local model = record.Visual.Model
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid then
				Reactions.Observe(record.Reactions, model, humanoid, active)
				Reactions.Update(record.Reactions, model, humanoid, dt)
				Tilt.Restore(record.Tilt)
			end
			local camera = Workspace.CurrentCamera
			if actor == LocalPlayer.Character and camera and camera.CameraType == Enum.CameraType.Custom then
				local subject = camera.CameraSubject
				if subject == actor:FindFirstChildOfClass("Humanoid") or subject == root then
					VisualRig.FollowCamera(actor, camera, subject)
				end
			end
		end
	end)
	-- VisualRig copies source joint/attachment frames before the camera. Apply tilt
	-- afterwards so neither that copy nor fixed Animator evaluation erases the layer.
	RunService:BindToRenderStep("CartoonReactionTilt", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
		for _, record in Records do
			local state = record.Reactions.presentation
			local phase = Motion.GetState(record.Actor)
			Tilt.Apply(
				record.Tilt,
				record.Visual.Model,
				record.Visual.Root,
				Motion.GetVelocity(record.Actor),
				phase == "Fly" or (phase == "Bounce" and Config.BounceFollowVelocity),
				if record.Actor:GetAttribute("TimeStopped") == true then 0 else dt,
				Config.RestFadeTime,
				state.transition,
				if state.phase == "Bounce" and not Config.BounceFollowVelocity then state.category else nil,
				false,
				if state.phase == "Rest" then state.restDirection else nil
			)
			if record.Trail then
				record.Trail.Enabled = phase == "Fly" or phase == "Bounce"
			end
		end
	end)
end
function Controller.Init()
	if Initialized then
		return
	end
	Initialized = true
	Controller:Setup()
	Controller:Start()
end
return Controller
