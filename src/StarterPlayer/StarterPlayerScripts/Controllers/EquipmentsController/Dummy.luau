--!strict
--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local ShowcaseProperties = require(script.Parent.ShowcaseProperties)
local TimeStopEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.TimeStop.TimeStopEffect)

--// References
local Assets = ReplicatedStorage:WaitForChild("Assets")
local NpcTemplate = Assets:WaitForChild("Npcs"):WaitForChild("Npc")
local DummyContainer = ShowcaseProperties.EquipmentShowcase
local AnimFolder = Assets.Animations.Knockback.Global
local BounceBackAnimation = AnimFolder.Bounce_Back
local FlyAnimation = AnimFolder.Fly
local IdleAnimation = DummyContainer.IdleAnim
local WeaponHoldAnim = DummyContainer.WeaponHold
local WeaponsFolder = ReplicatedStorage.Assets.Weapons
local PUSH_PITCH_ANGLE = math.rad(150)

--// Types
export type DummyNPC = typeof(NpcTemplate)
export type DummyType = {
	__index: DummyType,
	Model: DummyNPC,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Animator: Animator,
	ShouldLand: boolean,
	MoveConnection: RBXScriptConnection?,
	AnimTrack: AnimationTrack?,
	new: (cFrame: CFrame, shouldLand: boolean?) -> (DummyType),
	DestroyAll: () -> (),
	Destroy: (self: DummyType) -> (),
	Push: (self: DummyType, direction: Vector3, distance: number?, height: number?, duration: number?) -> (),
}

local ActiveDummies: {[DummyType]: boolean} = {}
local Dummy = {} :: DummyType
Dummy.__index = Dummy

function Dummy.new(cframe: CFrame, shouldLand: boolean?): DummyType
	local model = NpcTemplate:Clone()
	model.Name = "Dummy"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local rootPart = model:FindFirstChild("HumanoidRootPart")
	assert(rootPart and rootPart:IsA("BasePart"), "Npc template must contain a BasePart named HumanoidRootPart")
	rootPart.Anchored = true

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	assert(humanoid, "Npc template must contain a Humanoid")

	local animator = humanoid:FindFirstChildOfClass("Animator")

	model:PivotTo(cframe)
	model.Parent = DummyContainer

	if animator then
		local idleTrack = animator:LoadAnimation(IdleAnimation)
		idleTrack.Priority = Enum.AnimationPriority.Idle		
		
		local weaponTrack = animator:LoadAnimation(WeaponHoldAnim)
		weaponTrack.Priority = Enum.AnimationPriority.Action

		idleTrack:Play()
		weaponTrack:Play()
	end

	local hand = model:FindFirstChild("RightHand")
	local weaponTemplate = WeaponsFolder:FindFirstChild("Slap")
	
	if hand and weaponTemplate then
		local weapon = weaponTemplate:Clone() :: Model
		local weaponMainPart = weapon:FindFirstChild("Main", true) :: BasePart
		weapon.Name = "Weapon"
		weapon.Parent = model
		
		weapon:PivotTo(hand.CFrame)

		if weaponMainPart then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = weaponMainPart
			weld.Parent = weaponMainPart
		end
	end

	local self = setmetatable({
		Model = model,
		RootPart = rootPart,
		Humanoid = humanoid,
		Animator = animator,
		ShouldLand = shouldLand or false,
		MoveConnection = nil,
		AnimTrack = nil,
	}, Dummy) :: DummyType

	ActiveDummies[self] = true
	return self
end

function Dummy:Push(
	direction: Vector3,
	distance: number?,
	height: number?,
	duration: number?
)
	local horizontalDirection = Vector3.new(direction.X, 0, direction.Z)
	assert(horizontalDirection.Magnitude > 0, "Push direction must have a non-zero horizontal component")

	local pushDistance = distance or 20
	local arcHeight = height or 8
	local pushDuration = duration or 0.7
	assert(pushDistance >= 0, "Push distance cannot be negative")
	assert(arcHeight >= 0, "Push height cannot be negative")
	assert(pushDuration > 0, "Push duration must be greater than zero")

	self.RootPart.Anchored = true
	self.Humanoid.PlatformStand = false
	self.Humanoid.AutoRotate = true

	if self.MoveConnection then
		self.MoveConnection:Disconnect()
		self.MoveConnection = nil
	end
	if self.AnimTrack then
		self.AnimTrack:Stop(0.1)
		self.AnimTrack:Destroy()
	end

	local animationTrack = self.Animator:LoadAnimation(BounceBackAnimation)
	animationTrack.Priority = Enum.AnimationPriority.Action
	animationTrack:Play()
	self.AnimTrack = animationTrack

	local startCFrame = self.Model:GetPivot()
	local startPosition = startCFrame.Position
	local rotation = startCFrame - startPosition
	local pushVector = horizontalDirection.Unit * pushDistance
	local elapsed = 0
	local isFalling = false

	self.MoveConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not self.Model.Parent then
			self:Destroy()
			return
		end

		if isFalling then
			return
		end

		elapsed += deltaTime
		local alpha = math.min(elapsed / pushDuration, 1)
		local arcOffset = 4 * arcHeight * alpha * (1 - alpha)
		local position = startPosition + pushVector * alpha + Vector3.yAxis * arcOffset
		local pitch = CFrame.Angles(PUSH_PITCH_ANGLE, 0, 0)
		self.Model:PivotTo(CFrame.new(position) * rotation * pitch)

		if alpha >= 0.5 then
			isFalling = true
			local connection = self.MoveConnection
			if connection then
				connection:Disconnect()
			end
			self.MoveConnection = nil

			if self.AnimTrack then
				self.AnimTrack:Stop(0.1)
				self.AnimTrack:Destroy()
			end

			local flyTrack = self.Animator:LoadAnimation(FlyAnimation)
			flyTrack.Priority = Enum.AnimationPriority.Action
			flyTrack.Looped = true
			flyTrack:Play()
			self.AnimTrack = flyTrack

			for _, descendant in self.Model:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.CanCollide = false
				end
			end
			self.RootPart.CanCollide = self.ShouldLand

			self.Humanoid.AutoRotate = false
			self.Humanoid.PlatformStand = true
			self.Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			self.RootPart.Anchored = false
			self.RootPart.AssemblyLinearVelocity = pushVector / pushDuration
		end
	end)
end

function Dummy:Destroy()
	if self.MoveConnection then
		self.MoveConnection:Disconnect()
		self.MoveConnection = nil
	end
	if self.AnimTrack then
		self.AnimTrack:Stop(0.1)
		self.AnimTrack:Destroy()
		self.AnimTrack = nil
	end

	ActiveDummies[self] = nil
	self.Model:Destroy()
end

function Dummy.DestroyAll()
	for dummy in pairs(ActiveDummies) do
		TimeStopEffect.RemoveMark(dummy.Model)
		dummy:Destroy()
	end
end

return Dummy
