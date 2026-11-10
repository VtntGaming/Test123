--!strict
-- Tweens replicated Shrink activation for every player while preserving movement and motion.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--// Modules
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local ShrinkScale = require(ReplicatedStorage.SharedModules.ShrinkScale)

--// Types
type Transition = {
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Original: {
		Scale: number,
		RootSize: Vector3,
	},
	VisualScale: number,
	Shrinking: boolean,
	Connection: RBXScriptConnection?,
}

type Observer = {
	Character: Model?,
	Transition: Transition?,
	Connections: { RBXScriptConnection },
	CharacterConnections: { RBXScriptConnection },
}

export type ShrinkEffect = {
	Init: () -> (),
	Setup: (self: ShrinkEffect) -> (),
	Start: (self: ShrinkEffect) -> (),
	Destroy: (self: ShrinkEffect) -> (),
}

--// Properties
local Initialized = false
local Observers: { [Player]: Observer } = {}
local Connections: { RBXScriptConnection } = {}

--// Controller
local ShrinkEffect = {} :: ShrinkEffect

--// APIs
local function Disconnect(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function CancelTween(transition: Transition)
	if transition.Connection then
		transition.Connection:Disconnect()
		transition.Connection = nil
	end
end

local function ApplyScale(transition: Transition, scale: number)
	local character, root = transition.Character, transition.Root
	-- Geometry can replicate before or after the activation attribute. Derive the local
	-- canonical scale from the actual root size instead of assuming it matches the server.
	local targetRootSize = transition.Original.RootSize * (scale / transition.Original.Scale)
	local localScale = character:GetScale() * targetRootSize.X / root.Size.X
	ShrinkScale.Apply(character, transition.Humanoid, root, localScale, AbilityConfig.Abilities.Shrink.ScaleWeapon)
	-- A server size update can arrive while this client already has a ScaleTo cache.
	-- Reconcile once after applying it so that cache cannot produce a doubled resize.
	if (root.Size - targetRootSize).Magnitude > 0.0001 then
		localScale = character:GetScale() * targetRootSize.X / root.Size.X
		ShrinkScale.Apply(character, transition.Humanoid, root, localScale, AbilityConfig.Abilities.Shrink.ScaleWeapon)
	end
	transition.VisualScale = scale
end

local function CleanupCharacter(observer: Observer)
	Disconnect(observer.CharacterConnections)
	local transition = observer.Transition
	observer.Transition = nil
	observer.Character = nil
	if not transition then
		return
	end
	CancelTween(transition)
	if
		transition.Character.Parent
		and transition.Humanoid:IsDescendantOf(transition.Character)
		and transition.Root:IsDescendantOf(transition.Character)
	then
		ApplyScale(transition, transition.Original.Scale)
	end
end

local function TweenScale(player: Player, observer: Observer, transition: Transition)
	CancelTween(transition)
	local fromScale = transition.VisualScale
	local targetScale = transition.Original.Scale
	if transition.Shrinking then
		targetScale *= AbilityConfig.Abilities.Shrink.Scale
	end
	local elapsed = 0
	local duration = AbilityConfig.Abilities.Shrink.TweenTime

	transition.Connection = RunService.PreSimulation:Connect(function(deltaTime: number)
		if
			observer.Transition ~= transition
			or player.Character ~= transition.Character
			or not transition.Character.Parent
			or not transition.Humanoid:IsDescendantOf(transition.Character)
			or not transition.Root:IsDescendantOf(transition.Character)
		then
			CleanupCharacter(observer)
			return
		end

		elapsed += deltaTime
		local alpha = if duration <= 0 then 1 else math.min(elapsed / duration, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		local scale = if alpha == 1 then targetScale else fromScale + (targetScale - fromScale) * eased
		ApplyScale(transition, scale)

		if alpha == 1 then
			CancelTween(transition)
			if not transition.Shrinking then
				observer.Transition = nil
			end
		end
	end)
end

local function SyncCharacter(player: Player, observer: Observer)
	local character = observer.Character
	if not character or not character.Parent or player.Character ~= character then
		return
	end
	local shrinking = character:GetAttribute("shrink") == true
	local transition = observer.Transition
	if not transition then
		if not shrinking then
			return
		end
		local humanoid = character:FindFirstChildWhichIsA("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or not root:IsA("BasePart") then
			return
		end
		local originalScale = character:GetAttribute("ShrinkOriginalScale")
		local originalRootSize = character:GetAttribute("ShrinkOriginalRootSize")
		if typeof(originalScale) ~= "number" or typeof(originalRootSize) ~= "Vector3" then
			return
		end
		local current: Transition = {
			Character = character,
			Humanoid = humanoid,
			Root = root,
			Original = { Scale = originalScale, RootSize = originalRootSize },
			VisualScale = originalScale,
			Shrinking = shrinking,
			Connection = nil,
		}
		observer.Transition = current
		TweenScale(player, observer, current)
		return
	end
	if transition.Shrinking == shrinking then
		return
	end
	transition.Shrinking = shrinking
	TweenScale(player, observer, transition)
end

local function BindCharacter(player: Player, observer: Observer, character: Model)
	CleanupCharacter(observer)
	observer.Character = character
	table.insert(
		observer.CharacterConnections,
		character:GetAttributeChangedSignal("shrink"):Connect(function()
			SyncCharacter(player, observer)
		end)
	)
	table.insert(
		observer.CharacterConnections,
		character.DescendantAdded:Connect(function()
			if not observer.Transition then
				SyncCharacter(player, observer)
			end
		end)
	)
	for _, attribute in { "ShrinkOriginalScale", "ShrinkOriginalRootSize" } do
		table.insert(
			observer.CharacterConnections,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				if not observer.Transition then
					SyncCharacter(player, observer)
				end
			end)
		)
	end
	table.insert(
		observer.CharacterConnections,
		character.AncestryChanged:Connect(function()
			if not character.Parent then
				CleanupCharacter(observer)
			end
		end)
	)
	SyncCharacter(player, observer)
end

local function ObservePlayer(player: Player)
	if Observers[player] then
		return
	end
	local observer: Observer = {
		Character = nil,
		Transition = nil,
		Connections = {},
		CharacterConnections = {},
	}
	Observers[player] = observer
	table.insert(
		observer.Connections,
		player.CharacterAdded:Connect(function(character: Model)
			BindCharacter(player, observer, character)
		end)
	)
	table.insert(
		observer.Connections,
		player.CharacterRemoving:Connect(function(character: Model)
			if observer.Character == character then
				CleanupCharacter(observer)
			end
		end)
	)
	if player.Character then
		BindCharacter(player, observer, player.Character)
	end
end

function ShrinkEffect:Setup()
	for _, player in Players:GetPlayers() do
		ObservePlayer(player)
	end
end

function ShrinkEffect:Start()
	table.insert(Connections, Players.PlayerAdded:Connect(ObservePlayer))
	table.insert(
		Connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			local observer = Observers[player]
			if observer then
				Observers[player] = nil
				CleanupCharacter(observer)
				Disconnect(observer.Connections)
			end
		end)
	)
end

function ShrinkEffect.Init()
	if Initialized then
		return
	end
	Initialized = true
	ShrinkEffect:Setup()
	ShrinkEffect:Start()
end

function ShrinkEffect:Destroy()
	Initialized = false
	Disconnect(Connections)
	for player, observer in Observers do
		CleanupCharacter(observer)
		Disconnect(observer.Connections)
		Observers[player] = nil
	end
end

return ShrinkEffect
