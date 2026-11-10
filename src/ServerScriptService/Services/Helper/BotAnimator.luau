--!nonstrict
-- BotAnimator
-- Server-owned locomotion animation for bots: idle / run / jump / fall / landing.
--
-- Why this exists: the stock "Animate" script on the NPC rig was started while the avatar was still being swapped in
-- by HumanoidDescription:ApplyDescription, was toggled by NpcService / RagdollService (a knockback at the wrong moment
-- left it disabled for good) and caches joint state. Any of those left a bot stuck in a pose, sliding around like loose parts.
-- This module loads its own tracks on the bot's Animator and re-validates the rig every second (Animator present,
-- joints connected + enabled, tracks alive), repairing whatever broke, so animation can never stay dead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = ReplicatedStorage:WaitForChild("Assets")
local CharacterAnimations = Assets:WaitForChild("Animations"):WaitForChild("Character")
local NpcTemplate = Assets:WaitForChild("Npcs"):WaitForChild("Npc")
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))

local LANDING_ANIMATION_ID = "rbxassetid://98548063446402" -- the clip MatchController plays for players after the arena drop
local HEALTH_INTERVAL = 1
local REPAIR_COOLDOWN = 2
local R15_JOINTS = {
	"Root", "Waist", "Neck", "LeftShoulder", "LeftElbow", "LeftWrist", "RightShoulder", "RightElbow", "RightWrist",
	"LeftHip", "LeftKnee", "LeftAnkle", "RightHip", "RightKnee", "RightAnkle",
}

local function customId(name: string): string?
	local animation = CharacterAnimations:FindFirstChild(name)
	return if animation and animation:IsA("Animation") and animation.AnimationId ~= "" then animation.AnimationId else nil
end

local function stockId(folderName: string): string?
	local animate = NpcTemplate:FindFirstChild("Animate")
	local folder = animate and animate:FindFirstChild(folderName)
	local animation = folder and folder:FindFirstChildWhichIsA("Animation")
	return if animation and animation.AnimationId ~= "" then animation.AnimationId else nil
end

-- same clips NpcService used to push into the Animate script (custom idle/run/jump), stock fall
local DEFS = {
	Idle = { id = customId("Idle") or stockId("idle"), priority = Enum.AnimationPriority.Idle, looped = true },
	Run = { id = customId("Running") or stockId("run"), priority = Enum.AnimationPriority.Movement, looped = true },
	Jump = { id = customId("Jumping") or stockId("jump"), priority = Enum.AnimationPriority.Action, looped = false },
	Fall = { id = stockId("fall") or customId("Jumping"), priority = Enum.AnimationPriority.Action, looped = true },
	Land = { id = LANDING_ANIMATION_ID, priority = Enum.AnimationPriority.Action4, looped = false },
}

local BotAnimator = {}
BotAnimator.__index = BotAnimator

function BotAnimator.new(model: Model, humanoid: Humanoid, root: BasePart)
	local self = setmetatable({
		model = model, humanoid = humanoid, root = root,
		animator = nil, tracks = {}, current = nil,
		landingUntil = 0, nextCheck = 0, lastRepair = 0,
		animate = nil, animateWasEnabled = nil, destroyed = false,
	}, BotAnimator)

	-- RagdollService reads this: never hand the stock Animate script back to a bot after a knockback
	model:SetAttribute("BotAnimated", true)
	local animate = model:FindFirstChild("Animate")
	if animate and animate:IsA("BaseScript") then
		self.animate, self.animateWasEnabled = animate, animate.Enabled
		animate.Enabled = false
	end
	self:_bind(true)
	return self
end

-- Stops and destroys every loaded track. Loaded tracks count towards the Animator's 64-track limit until destroyed.
function BotAnimator:_releaseTracks()
	for _, track in self.tracks do
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
	table.clear(self.tracks)
end

-- (Re)creates the Animator and the tracks when something replaced them.
function BotAnimator:_bind(stopForeign: boolean)
	local humanoid = self.humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if animator ~= self.animator then
		self:_releaseTracks() -- the old Animator's tracks keep counting towards its limit until destroyed
		self.animator = animator
		self.current = nil
	end
	if stopForeign then
		for _, track in animator:GetPlayingAnimationTracks() do track:Stop(0) end
		self.current = nil
	end
	for name, def in DEFS do
		local track = self.tracks[name]
		-- NOTE: AnimationTrack.Parent is always nil, so it can never be compared with the Animator. Doing so reloaded every
		-- track on every health check (5 leaked tracks / second / bot) until the 64-track limit froze all animation.
		if def.id and not track then
			local animation = Instance.new("Animation")
			animation.AnimationId = def.id
			local ok, loaded = pcall(animator.LoadAnimation, animator, animation)
			animation:Destroy()
			if ok and loaded then
				loaded.Priority, loaded.Looped = def.priority, def.looped
				self.tracks[name] = loaded
			else
				self.tracks[name] = nil
			end
		end
	end
end

-- true when a joint is missing or detached (what makes limbs move as loose parts). Re-enables joints left disabled.
-- NOTE: modern R15 rigs hold BOTH a Motor6D and a same-named AnimationConstraint, so a name lookup can return the wrong class
-- (that made every bot look "broken" each second: rig rebuilt + tracks stopped = statues). Check by class, per name.
function BotAnimator:_rigBroken(): boolean
	local model = self.model
	local ragdolled = model:GetAttribute("IsRagdolled") == true
	local motors, constraints = {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then motors[d.Name] = d
		elseif d:IsA("AnimationConstraint") then constraints[d.Name] = d end
	end
	local function valid(joint): boolean
		return joint ~= nil and joint.Part0 ~= nil and joint.Part1 ~= nil
			and joint.Part0:IsDescendantOf(model) and joint.Part1:IsDescendantOf(model)
	end
	for _, jointName in R15_JOINTS do
		local motor, constraint = motors[jointName], constraints[jointName]
		if not (valid(motor) or valid(constraint)) then return true end
		-- plain Motor6D rig: make sure it is enabled (with an AnimationConstraint the engine manages the Motor6D itself)
		if motor and not constraint and not motor.Enabled and not ragdolled then motor.Enabled = true end
	end
	return false
end

function BotAnimator:_health(now: number)
	self.nextCheck = now + HEALTH_INTERVAL
	local humanoid = self.humanoid
	if humanoid.Parent ~= self.model then return end
	self:_bind(false)
	if humanoid.RigType == Enum.HumanoidRigType.R15 and now - self.lastRepair >= REPAIR_COOLDOWN and self:_rigBroken() then
		self.lastRepair = now
		warn(("[BotAnimator] rebuilding broken rig of %s"):format(self.model.Name))
		pcall(humanoid.BuildRigFromAttachments, humanoid)
		self:_bind(true)
	end
end

function BotAnimator:_play(name: string, flatSpeed: number)
	local tracks = self.tracks
	local key = if tracks[name] then name elseif name == "Fall" and tracks.Jump then "Jump" else "Idle"
	local track = tracks[key]
	if not track then return end
	local def = DEFS[key]
	if self.current ~= key or (def.looped and not track.IsPlaying) then
		local previous = self.current and tracks[self.current]
		local fade = if key == "Idle" then 0.2 else 0.12
		if previous and previous ~= track and previous.IsPlaying then previous:Stop(fade) end
		track:Play(fade)
		self.current = key
	end
	if key == "Run" then
		track:AdjustSpeed(math.clamp(flatSpeed / math.max(GameConfig.Movement.WalkSpeed, 1), 0.7, 1.6))
	end
end

-- Call every AI tick. Cheap: one state read and (rarely) a track switch.
function BotAnimator:update(now: number)
	if self.destroyed then return end
	local model, humanoid, root = self.model, self.humanoid, self.root
	if not model.Parent or not root.Parent then return end
	if model:GetAttribute("IsRagdolled") == true then
		-- RagdollService stops server tracks during a knockback; resume cleanly once it is over
		self.current = nil
		return
	end
	if now >= self.nextCheck then self:_health(now) end
	if now < self.landingUntil then return end

	local velocity = root.AssemblyLinearVelocity
	local flatSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local want
	if root.Anchored then
		want = "Idle"
	elseif humanoid.FloorMaterial == Enum.Material.Air then
		want = if velocity.Y > 2 then "Jump" else "Fall"
	elseif flatSpeed > 1.5 then
		want = "Run"
	else
		want = "Idle"
	end
	self:_play(want, flatSpeed)
end

-- Plays the landing clip (same one players get after the arena drop). Returns how long the bot should stay put.
function BotAnimator:land(now: number): number
	self:_bind(false)
	local track = self.tracks.Land
	if not track then return 0 end
	for _, name in { "Jump", "Fall" } do
		local other = self.tracks[name]
		if other and other.IsPlaying then other:Stop(0.05) end
	end
	track:Play(0.05)
	local duration = math.clamp(if track.Length > 0 then track.Length * 0.85 else 0.7, 0.4, 1.2)
	self.landingUntil = now + duration
	self.current = nil
	return duration
end

function BotAnimator:destroy(restoreStock: boolean?)
	if self.destroyed then return end
	self.destroyed = true
	self:_releaseTracks()
	if self.model.Parent then self.model:SetAttribute("BotAnimated", nil) end
	if restoreStock and self.animate and self.animate.Parent and self.animateWasEnabled ~= nil then
		self.animate.Enabled = self.animateWasEnabled
	end
end

return BotAnimator
