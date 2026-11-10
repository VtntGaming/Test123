--!strict
-- Locally fades character decals, particle emitters and BillboardGui contents during invisibility.
-- Call Start and Stop from the ability flow; this module does not activate abilities.

--// Services
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)

--// Constants
local FADE_DURATION = 0.375
local FADE_INFO = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RESTORE_INFO = TweenInfo.new(0)

--// Types
type Visual = {
	Defaults: { [string]: number },
	Hidden: { [string]: number },
	Tween: Tween?,
}

type State = {
	Character: Model,
	Active: boolean,
	Generation: number,
	Visuals: { [Instance]: Visual },
	Connections: { RBXScriptConnection },
}

export type InvisibleEffect = {
	Init: () -> (),
	Start: (player: Player) -> (),
	Stop: (player: Player) -> (),
}

--// Properties
local Initialized = false
local Cache: { [Player]: State } = {}

--// Controller
local InvisibleEffect = {} :: InvisibleEffect

--// APIs
local function Capture(instance: Instance, character: Model): { [string]: number }?
	if instance:IsA("Decal") or instance:IsA("ParticleEmitter") then
		return { LocalTransparencyModifier = instance.LocalTransparencyModifier }
	end
	local billboard = instance:FindFirstAncestorWhichIsA("BillboardGui")
	if not billboard or not billboard:IsDescendantOf(character) then
		return nil
	end
	-- The overhead controller composes invisibility with live combat/lives state.
	if billboard:GetAttribute("OverheadVisibilityManaged") == true then
		return nil
	end

	local defaults: { [string]: number } = {}
	if instance:IsA("GuiObject") then
		defaults.BackgroundTransparency = instance.BackgroundTransparency
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		defaults.TextTransparency = instance.TextTransparency
		defaults.TextStrokeTransparency = instance.TextStrokeTransparency
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		defaults.ImageTransparency = instance.ImageTransparency
	end
	if instance:IsA("UIStroke") then
		defaults.Transparency = instance.Transparency
	end
	if instance:IsA("ScrollingFrame") then
		defaults.ScrollBarImageTransparency = instance.ScrollBarImageTransparency
	end
	if instance:IsA("CanvasGroup") then
		defaults.GroupTransparency = instance.GroupTransparency
	end
	return if next(defaults) then defaults else nil
end

local function CancelTween(visual: Visual)
	local tween = visual.Tween
	visual.Tween = nil
	if tween then
		tween:Cancel()
		tween:Destroy()
	end
end

local function Restore(instance: Instance, visual: Visual)
	CancelTween(visual)
	if not instance.Parent then
		return
	end
	-- Reuse captured property names without classifying the instance again.
	local tween = TweenService:Create(instance, RESTORE_INFO, visual.Defaults)
	tween.Completed:Once(function()
		tween:Destroy()
	end)
	tween:Play()
end

local function Cleanup(player: Player, state: State)
	if Cache[player] ~= state then
		return
	end
	Cache[player] = nil
	for _, connection in state.Connections do
		connection:Disconnect()
	end
	for instance, visual in state.Visuals do
		Restore(instance, visual)
	end
	table.clear(state.Connections)
	table.clear(state.Visuals)
end

local function Fade(instance: Instance, visual: Visual, hidden: boolean)
	CancelTween(visual)
	local goals = if hidden then visual.Hidden else visual.Defaults
	local tween = TweenService:Create(instance, FADE_INFO, goals)
	visual.Tween = tween
	tween:Play()
end

local function AddVisual(state: State, instance: Instance)
	if not state.Active or not instance:IsDescendantOf(state.Character) or state.Visuals[instance] then
		return
	end
	local defaults = Capture(instance, state.Character)
	if not defaults then
		return
	end
	local hidden: { [string]: number } = {}
	for property in defaults do
		hidden[property] = 1
	end
	local visual: Visual = { Defaults = defaults, Hidden = hidden, Tween = nil }
	state.Visuals[instance] = visual
	Fade(instance, visual, true)
end

function InvisibleEffect.Init()
	if Initialized then
		return
	end
	Initialized = true
	Players.PlayerRemoving:Connect(function(player: Player)
		local state = Cache[player]
		if state then
			Cleanup(player, state)
		end
	end)

	local function OnPlayerAdded(player: Player)
		player.CharacterAdded:Connect(function()
			if PlayerData.Get(player, "Invisible") == true then
				InvisibleEffect.Start(player)
			end
		end)
		PlayerData.Observe(player, "Invisible", function(...)
			local isInvisible = PlayerData.Get(player, "Invisible")
			if isInvisible then
				InvisibleEffect.Start(player)
			else
				InvisibleEffect.Stop(player)
			end
		end)
		if PlayerData.Get(player, "Invisible") == true then
			InvisibleEffect.Start(player)
		end
	end
	Players.PlayerAdded:Connect(OnPlayerAdded)
	for _,player in ipairs(Players:GetPlayers()) do
		OnPlayerAdded(player)
	end
end

function InvisibleEffect.Start(player)
	InvisibleEffect.Init()
	local character = player.Character
	local state: State? = Cache[player]
	if state and state.Character ~= character then
		Cleanup(player, state)
		state = nil
	end
	if not character or not character.Parent then
		return
	end
	if state then
		state.Active = true
		state.Generation += 1
		for instance, visual in state.Visuals do
			Fade(instance, visual, true)
		end
		for _, instance in character:GetDescendants() do
			AddVisual(state, instance)
		end
	else
		local current: State = {
			Character = character,
			Active = true,
			Generation = 1,
			Visuals = {},
			Connections = {},
		}
		Cache[player] = current
		table.insert(current.Connections, character.DescendantAdded:Connect(function(instance: Instance)
			AddVisual(current, instance)
		end))
		table.insert(current.Connections, character.DescendantRemoving:Connect(function(instance: Instance)
			local visual = current.Visuals[instance]
			if visual then
				current.Visuals[instance] = nil
				Restore(instance, visual)
			end
		end))
		table.insert(current.Connections, player.CharacterRemoving:Connect(function(removingCharacter: Model)
			if removingCharacter == character then
				Cleanup(player, current)
			end
		end))
		table.insert(current.Connections, character.AncestryChanged:Connect(function()
			if not character.Parent then
				Cleanup(player, current)
			end
		end))
		for _, instance in character:GetDescendants() do
			AddVisual(current, instance)
		end
	end
end

function InvisibleEffect.Stop(player)
	local state = Cache[player]
	if not state or not state.Active then
		return
	end
	state.Active = false
	state.Generation += 1
	local generation = state.Generation
	for instance, visual in state.Visuals do
		if instance:IsDescendantOf(state.Character) then
			Fade(instance, visual, false)
		else
			state.Visuals[instance] = nil
			Restore(instance, visual)
		end
	end
	task.delay(FADE_DURATION, function()
		if Cache[player] == state and state.Generation == generation and not state.Active then
			Cleanup(player, state)
		end
	end)
end

return InvisibleEffect
