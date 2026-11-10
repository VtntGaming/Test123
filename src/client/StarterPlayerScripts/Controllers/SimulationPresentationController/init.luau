--!strict
-- Presents immediate local camera facing, smoothed scripted rotation, and damped reconciliation offsets.
-- Only temporary decorative rigs are changed; physics and the real Animator remain authoritative.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Modules
local Simulation = require(ReplicatedStorage.Simulation)
local State = require(ReplicatedStorage.Simulation.State)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Types = require(ReplicatedStorage.Simulation.Types)
local Attributes = require(ReplicatedStorage.Simulation.Attributes)
local ActorTimelines = require(ReplicatedStorage.Simulation.ActorTimelines)
local Timelines = require(ReplicatedStorage.Simulation.Timelines)
local Config = require(ReplicatedStorage.Config.Simulation)
local AnimationConfig = require(ReplicatedStorage.Config.Animation)
local VisualRig = require(script.Parent.RagdollController.VisualRig)
local Clock = require(script.Clock)
local Smoothing = require(script.Smoothing)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local Settings = Config.ClientPresentation

--// Constants
-- Three seconds of samples at 60 Hz; history is visual-only and never feeds gameplay.
local HISTORY_FRAMES = 180

--// Types
type Record = {
	Root: BasePart,
	Generation: string,
	At: number,
	Frame: CFrame,
	Velocity: Vector3,
	Rotation: CFrame,
	Correction: Smoothing.Offset,
	Facing: boolean,
	Moving: boolean,
	Displayed: CFrame?,
	History: { [number]: CFrame },
	Times: { number },
	Next: number,
	PendingPosition: Vector3?,
	PendingRotation: CFrame?,
}
export type Controller = {
	-- Initializes shared simulation and presentation listeners once, calling Setup before Start.
	Init: () -> (),
	-- Starts gameplay dependencies and the isolated visual-rig renderer.
	Setup: (Controller) -> (),
	-- Captures completed simulation frames; presents timelines before the camera and final local facing after camera updates.
	Start: (Controller) -> (),
}

--// Properties
local Initialized = false
local Records: { [Types.Actor]: Record } = {}

--// Controller
local Controller: Controller = {} :: Controller

local function Release(actor: Types.Actor)
	Records[actor] = nil
	VisualRig.Present(actor, nil)
	VisualRig.Release(actor, "Simulation")
end

local function ForcedFacing(source: Types.ActorRecord): boolean
	local actor = source.Actor
	local ability = if source.Humanoid then Attributes.Get(source.Humanoid, "SAActiveAbility") else nil
	return not source.Alive
		or actor:GetAttribute("IsFrozen") == true
		or actor:GetAttribute("TimeStopped") == true
		or actor:GetAttribute("MovementLocked") == true
		or Attributes.Get(source.Root, "KBActive") == true
		or Attributes.Get(source.Root, "SADropAt") ~= nil
		or ability == "Throw"
		or ability == "Push"
		or ability == "Pull"
		or ability == "Charge"
end

local function FacingGoal(source: Types.ActorRecord, forced: boolean): CFrame?
	if
		not Settings.FacingRotationSmoothing
		or source.Owner ~= LocalPlayer
		or not source.Alive
		or PlayerData.Get(LocalPlayer, "ShiftLock") ~= true
		or not (PlayerData.Get(LocalPlayer, "IsOnArena") == true or PlayerData.Get(LocalPlayer, "IsInTrainingArea") == true)
		or forced
	then
		return nil
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local direction = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	return if direction.Magnitude > 0.001 then CFrame.lookAt(Vector3.zero, direction) else nil
end

local function SamplePrediction()
	local now = time()
	local replaying = RunService:IsResimulating()
	for actor, record in Records do
		local source = State.Records[actor]
		if
			not source
			or not source.Ready
			or source.Root ~= record.Root
			or source.Generation ~= record.Generation
			or RunService:GetPredictionStatus(record.Root) ~= Enum.PredictionStatus.Predicted
		then
			continue
		end
		local frame = record.Root.CFrame
		local previous = record.History[now]
		if replaying and previous then
			-- Compare the same simulated instant, not an old server snapshot with a newer input frame.
			record.PendingPosition = previous.Position - frame.Position
			record.PendingRotation = frame.Rotation:ToObjectSpace(previous.Rotation)
		end
		if not previous then
			record.Next = record.Next % HISTORY_FRAMES + 1
			local expired = record.Times[record.Next]
			if expired then
				record.History[expired] = nil
			end
			record.Times[record.Next] = now
		end
		record.History[now] = frame
	end
end

local function Capture()
	local now = time()
	for actor, source in State.Records do
		if not source.Ready then
			continue
		end
		local previous: Record? = Records[actor]
		if previous and (previous.Root ~= source.Root or previous.Generation ~= source.Generation) then
			Release(actor)
			previous = nil
		end
		if not previous then
			Records[actor] = {
				Root = source.Root,
				Generation = source.Generation,
				At = now,
				Frame = source.Root.CFrame,
				Velocity = source.Root.AssemblyLinearVelocity,
				Rotation = source.Root.CFrame.Rotation,
				Correction = Smoothing.NewOffset(),
				Displayed = nil,
				History = {},
				Times = {},
				Next = 0,
				PendingPosition = nil,
				PendingRotation = nil,
				Facing = false,
				Moving = false,
			}
		else
			local frame = source.Root.CFrame
			if
				now < previous.At
				or (frame.Position - previous.Frame.Position).Magnitude > AnimationConfig.CorrectionSnapDistance
			then
				previous.Rotation = frame.Rotation
				Smoothing.Reset(previous.Correction)
				previous.PendingPosition, previous.PendingRotation = nil, nil
				table.clear(previous.History)
				table.clear(previous.Times)
				previous.Next = 0
				previous.Facing = false
				previous.Moving = false
			end
			local position, rotation = previous.PendingPosition, previous.PendingRotation
			if
				(
					Settings.MotionCorrectionSmoothing
					or (Settings.FacingRotationSmoothing and source.Owner == LocalPlayer)
				)
				and position
				and rotation
				and position.Magnitude <= AnimationConfig.CorrectionSnapDistance
				and actor:GetAttribute("IsFrozen") ~= true
				and actor:GetAttribute("TimeStopped") ~= true
				and Attributes.Get(source.Root, "KBActive") ~= true
			then
				-- Camera intent is independent of replayed yaw; scripted rotation also keeps its own interpolation.
				local orientation = previous.Correction.Value.Rotation
				if not FacingGoal(source, ForcedFacing(source)) and not previous.Moving then
					-- The raw-root display target changed; compensate its complete delta, including tiny updates.
					orientation = rotation * orientation
				end
				local offset = if Settings.MotionCorrectionSmoothing
					then previous.Correction.Value.Position + position
					else Vector3.zero
				if offset.Magnitude <= AnimationConfig.CorrectionSnapDistance then
					Smoothing.Rebase(previous.Correction, CFrame.new(offset) * orientation)
				else
					Smoothing.Reset(previous.Correction)
				end
			elseif position and position.Magnitude > AnimationConfig.CorrectionSnapDistance then
				Smoothing.Reset(previous.Correction)
			end
			previous.PendingPosition, previous.PendingRotation = nil, nil
			previous.Velocity = source.Root.AssemblyLinearVelocity
			previous.At, previous.Frame = now, frame
		end
	end
	for actor, record in Records do
		local source = State.Records[actor]
		if not source or not source.Ready or not record.Root.Parent then
			Release(actor)
		end
	end
end

local function Render(dt: number)
	local now = Clock.Now()
	for actor, record in Records do
		local source = State.Records[actor]
		if
			not source
			or not source.Ready
			or not actor.Parent
			or not record.Root.Parent
			or source.Root ~= record.Root
			or source.Generation ~= record.Generation
		then
			Release(actor)
			continue
		end
		local root = record.Root
		local physicalBody = (Attributes.Get(root, "SABodyScale") :: number?) or 1
		local body, weapon = nil :: number?, nil :: number?
		local scaling = false
		if Settings.TimelineVisuals then
			local changingBody, changingWeapon = false, false
			body, changingBody = ActorTimelines.Scale(actor, now, true, physicalBody)
			if source.Weapon then
				weapon, changingWeapon = ActorTimelines.Scale(
					source.Weapon,
					now,
					false,
					(Attributes.Get(root, "SAWeaponScale") :: number?) or 1
				)
			end
			scaling = changingBody or changingWeapon
		end
		local drop = if Settings.TimelineVisuals and source.Alive then ActorTimelines.Drop(root) else nil
		local existing = VisualRig.Get(actor)
		local cartoon = Attributes.Get(root, "KBActive") == true
			or (existing ~= nil and existing.Owners.Cartoon == true)
		local frozen = actor:GetAttribute("IsFrozen") == true or actor:GetAttribute("TimeStopped") == true
		local forced = ForcedFacing(source)
		local goal = if not cartoon then FacingGoal(source, forced) else nil
		local ability = if source.Humanoid then Attributes.Get(source.Humanoid, "SAActiveAbility") else nil
		local scripted = ability == "Dash" or ability == "Charge" or ability == "MegaJump" or ability == "Smash"
		local npc = source.Owner == nil and actor:GetAttribute("KnockbackActorKind") == "NPC"
		local _, headingError = record.Rotation:ToObjectSpace(record.Frame.Rotation):ToAxisAngle()
		local moving = Settings.MotionCorrectionSmoothing
			and (scripted or (npc and (record.Velocity.Magnitude > 0.05 or math.abs(headingError) > 0.001)))
			and source.Alive
			and not cartoon
			and not frozen
			and RunService:GetPredictionStatus(root) == Enum.PredictionStatus.Predicted
		local target: CFrame? = nil
		if cartoon or frozen then
			Smoothing.Reset(record.Correction)
		end
		Smoothing.Step(record.Correction, Settings.CorrectionSmoothTime, dt, Settings.CorrectionDeadzone)
		if goal then
			-- Camera-facing yaw never inherits a correction retained by another presentation mode.
			Smoothing.ClearYaw(record.Correction)
		elseif forced and record.Facing then
			-- Forced facing takes control immediately instead of fading from the old camera heading.
			Smoothing.ClearYaw(record.Correction)
			record.Rotation = root.CFrame.Rotation
		end
		if drop and not cartoon then
			local frame = Timelines.Drop(drop.From, drop.To, now, drop.At, drop.Duration)
			target = frame
			record.Rotation = frame.Rotation
			Smoothing.Reset(record.Correction)
			record.Facing = false
		elseif not cartoon and not frozen then
			if record.Moving and not moving and record.Displayed then
				local offset = record.Displayed.Position - root.Position
				if offset.Magnitude <= AnimationConfig.CorrectionSnapDistance then
					Smoothing.Rebase(record.Correction, CFrame.new(offset) * record.Correction.Value.Rotation)
				end
			end
			if goal then
				-- Only the decorative rig follows the current camera directly; physical facing still replays normally.
				record.Rotation = goal
			elseif moving then
				record.Rotation =
					Smoothing.Facing(record.Rotation, record.Frame.Rotation, Settings.FacingVisualResponsiveness, dt)
			else
				if record.Facing and record.Displayed and not forced then
					Smoothing.Rebase(
						record.Correction,
						CFrame.new(record.Correction.Value.Position)
							* root.CFrame.Rotation:ToObjectSpace(record.Displayed.Rotation)
					)
				end
				record.Rotation = root.CFrame.Rotation
			end
			record.Facing = goal ~= nil
			local elapsed = if moving then math.clamp(now - record.At, 0, 1 / 60) else 0
			local position = if moving then record.Frame.Position + record.Velocity * elapsed else root.Position
			local frame = (CFrame.new(position) * record.Rotation) + record.Correction.Value.Position
			target = frame * record.Correction.Value.Rotation
		else
			record.Rotation = root.CFrame.Rotation
			record.Facing = false
		end
		-- Held micro-offsets still need a visual owner, even after active damping has stopped.
		local correcting = Smoothing.HasOffset(record.Correction)

		if
			scaling
			and body
			and not cartoon
			and not drop
			and source.Humanoid
			and source.Humanoid.FloorMaterial ~= Enum.Material.Air
		then
			local baseSize = (root:GetAttribute("SABasePartSize") :: Vector3?) or root.Size
			local floorHeight = source.HipHeight + baseSize.Y * 0.5 + (if source.R6 then 2 * source.Scale else 0)
			target = (target or root.CFrame) + Vector3.yAxis * (floorHeight * (body - physicalBody))
		end
		record.Moving = moving
		record.Displayed = target or root.CFrame
		local wanted = scaling or (drop ~= nil and not cartoon) or goal ~= nil or moving or correcting
		if wanted then
			local visual = VisualRig.Acquire(actor, root, "Simulation")
			VisualRig.Present(actor, { Root = target, BodyScale = body, WeaponScale = weapon })
			if not drop and not scaling and not cartoon then
				VisualRig.RestoreCamera(actor)
			end
			local camera = Workspace.CurrentCamera
			if
				visual
				and (drop or scaling)
				and actor == LocalPlayer.Character
				and camera
				and camera.CameraType == Enum.CameraType.Custom
			then
				local subject = camera.CameraSubject
				if subject == source.Humanoid or subject == root then
					VisualRig.FollowCamera(actor, camera, subject :: Humanoid | BasePart)
				end
			end
		else
			VisualRig.Present(actor, nil)
			VisualRig.Release(actor, "Simulation")
		end
	end
end

local function RenderFacing()
	local actor = LocalPlayer.Character
	if not actor then
		return
	end
	local record, source = Records[actor], State.Records[actor]
	if
		not record
		or not record.Facing
		or not source
		or not source.Ready
		or record.Root ~= source.Root
		or record.Generation ~= source.Generation
	then
		return
	end
	local goal = FacingGoal(source, ForcedFacing(source))
	if not goal then
		return
	end
	Smoothing.ClearYaw(record.Correction)
	record.Rotation = goal
	-- Position/scale and damping were already evaluated before the camera. Only update the final visible rotation.
	local frame = VisualRig.PresentRotation(actor, goal * record.Correction.Value.Rotation)
	if frame then
		record.Displayed = frame
	end
end

--// APIs
function Controller:Setup()
	Simulation.Init()
	VisualRig.Init()
end

function Controller:Start()
	if
		not Settings.TimelineVisuals
		and not Settings.FacingRotationSmoothing
		and not Settings.MotionCorrectionSmoothing
	then
		return
	end
	RunService:BindToSimulation(SamplePrediction, Enum.StepFrequency.Hz60, Config.Priority + 2)
	RunService.PostSimulation:Connect(Capture)
	RunService:BindToRenderStep("SimulationPresentation", Enum.RenderPriority.Camera.Value - 2, Render)
	if Settings.FacingRotationSmoothing then
		RunService:BindToRenderStep("SimulationCameraFacing", Enum.RenderPriority.Camera.Value + 3, RenderFacing)
	end
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
