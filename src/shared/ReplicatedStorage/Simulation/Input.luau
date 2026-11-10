--!strict
-- Routes device and HUD input through replayable InputActions owned by each Player.

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--// Modules
local Types = require(script.Parent.Types)

--// References
local IsServer = RunService:IsServer()

--// Types
type ActionSample = Types.ActionSample
type ActionName = "Attack" | "Ability" | "Jump" | "Aim" | "Facing" | "Steer"
type Actions = { [string]: InputAction? }
export type Input = {
	-- Observes existing and future player input contexts once and releases cached connections when players leave.
	Init: () -> (),
	-- Attaches an existing gameplay input context, or creates its actions and device bindings on the server.
	Register: (Player) -> (),
	-- Samples action buttons and sanitized direction vectors; missing or invalid inputs produce false or zero values.
	Read: (Player) -> ActionSample,
	-- Fires the local player's script binding when available, using a boolean for buttons or a Vector3 for direction actions.
	Fire: (ActionName, boolean | Vector3) -> (),
	-- Remembers a HUD button and binds it to the local player's action when that action becomes available.
	BindButton: (ActionName, GuiButton) -> (),
}

--// Properties
local Contexts: { [Player]: InputContext } = {}
local PlayerActions: { [Player]: Actions } = {}
local Initialized = false
local ContextConnections: { [Player]: { RBXScriptConnection } } = {}
local Buttons: { [GuiButton]: ActionName } = {}

--// Controller
local Input: Input = {} :: Input

local function Attach(player: Player, context: InputContext)
	if Contexts[player] == context then
		return
	end
	local previous = ContextConnections[player]
	if previous then
		for _, connection in previous do
			connection:Disconnect()
		end
	end
	local actions: Actions = {}
	Contexts[player], PlayerActions[player] = context, actions
	local function added(child: Instance)
		if not child:IsA("InputAction") then
			return
		end
		actions[child.Name] = child
		if player == Players.LocalPlayer then
			for button, name in Buttons do
				if button.Parent then
					Input.BindButton(name :: ActionName, button)
				else
					Buttons[button] = nil
				end
			end
		end
	end
	ContextConnections[player] = {
		context.ChildAdded:Connect(added),
		context.ChildRemoved:Connect(function(child)
			if actions[child.Name] == child then
				actions[child.Name] = nil
			end
		end),
	}
	for _, child in context:GetChildren() do
		added(child)
	end
end

local function Binding(action: InputAction, name: string, key: Enum.KeyCode?): InputBinding
	local binding = Instance.new("InputBinding")
	binding.Name = name
	if key then binding.KeyCode = key else binding.Type = Enum.InputBindingType.Scriptable end
	binding.Parent = action
	return binding
end

--// APIs
function Input.Register(player)
	local existing = player:FindFirstChild("GameplayInput")
	if existing and existing:IsA("InputContext") then Attach(player, existing)
return end
	if not IsServer then
		return
	end
	local context = Instance.new("InputContext")
	context.Name, context.Priority, context.Sink = "GameplayInput", 3000, true
	for _, name in { "Attack", "Ability", "Jump", "Aim", "Facing", "Steer" } do
		local action = Instance.new("InputAction")
		action.Name = name
		action.Type = if name == "Attack" or name == "Ability" or name == "Jump"
			then Enum.InputActionType.Bool else Enum.InputActionType.Direction3D
		Binding(action, "Script", nil)
		if name == "Attack" then
			Binding(action, "Mouse", Enum.KeyCode.MouseLeftButton)
			Binding(action, "Gamepad", Enum.KeyCode.ButtonR2)
		elseif name == "Ability" then
			Binding(action, "Mouse", Enum.KeyCode.MouseRightButton)
			Binding(action, "Gamepad", Enum.KeyCode.ButtonL2)
		elseif name == "Jump" then
			Binding(action, "Keyboard", Enum.KeyCode.Space)
			Binding(action, "Gamepad", Enum.KeyCode.ButtonA)
		end
		action.Parent = context
	end
	context.Parent = player
	Attach(player, context)
end

function Input.Read(player)
	local actions = PlayerActions[player]
	local aim = if actions and actions.Aim then actions.Aim:GetState() else Vector3.zero
	local facing = if actions and actions.Facing then actions.Facing:GetState() else Vector3.zero
	local steer = if actions and actions.Steer then actions.Steer:GetState() else Vector3.zero
	-- Gameplay aim is untrusted. Normalize only finite, nonzero vectors.
	local validAim = typeof(aim) == "Vector3" and aim.X == aim.X and aim.Y == aim.Y and aim.Z == aim.Z
		and aim.Magnitude < math.huge and aim.Magnitude > 0.001
	local validSteer = typeof(steer) == "Vector3" and steer.Magnitude < math.huge
	local validFacing = typeof(facing) == "Vector3" and facing.Magnitude < math.huge and facing.Magnitude > 0.001
	return {
		Attack = actions ~= nil and actions.Attack ~= nil and actions.Attack:GetState() == true,
		Ability = actions ~= nil and actions.Ability ~= nil and actions.Ability:GetState() == true,
		Jump = actions ~= nil and actions.Jump ~= nil and actions.Jump:GetState() == true,
		Aim = if validAim then aim.Unit else Vector3.zero,
		Facing = if validFacing then facing.Unit else Vector3.zero,
		Steer = if validSteer then (if steer.Magnitude > 1 then steer.Unit else steer) else Vector3.zero,
	}
end

function Input.Fire(name, value)
	local actions = PlayerActions[Players.LocalPlayer]
	local action = actions and actions[name]
	local binding = action and action:FindFirstChild("Script")
	if binding and binding:IsA("InputBinding") then binding:Fire(value) end
end

function Input.BindButton(name, button)
	Buttons[button] = name
	local actions = PlayerActions[Players.LocalPlayer]
	local action = actions and actions[name]
	if not action then return end
	local existing = action:FindFirstChild("HUD_" .. button.Name)
	if existing and existing:IsA("InputBinding") then existing.UIButton = button
return end
	local binding = Binding(action, "HUD_" .. button.Name, nil)
	binding.Type, binding.UIButton = Enum.InputBindingType.Automatic, button
end

function Input.Init()
	if Initialized then return end
	Initialized = true
	local function observe(player: Player)
		Input.Register(player)
		player.ChildAdded:Connect(function(child)
			if child.Name == "GameplayInput" and child:IsA("InputContext") then Attach(player, child) end
		end)
	end
	Players.PlayerAdded:Connect(observe)
	Players.PlayerRemoving:Connect(function(player)
		local connections = ContextConnections[player]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
		end
		ContextConnections[player] = nil
		Contexts[player], PlayerActions[player] = nil, nil
	end)
	for _, player in Players:GetPlayers() do observe(player) end
end

return Input
