-- Presents spectate controller behavior using logical Player data access.
local SpectateController = {}
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local VisualRig = require(script.Parent.RagdollController.VisualRig)
local LocalPlayer = Players.LocalPlayer
local requestStreamingEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("SpectateRequestStreaming")

local changed = Instance.new("BindableEvent")
SpectateController.AvailabilityChanged = changed.Event

local initialized = false
local isSpectating = false
local targets = {}
local selected = nil
local skipped = {}
local watches = {}
local ui = nil
local previousFOV = nil
local restorePending = false
local refreshQueued = false
local refresh
local selectTarget

local function outsideCombat()
	return PlayerData.Get(LocalPlayer, "IsOnArena") ~= true and PlayerData.Get(LocalPlayer, "IsInTrainingArea") ~= true
end

local function eligible(player)
	if player == LocalPlayer or player.Parent ~= Players
		or PlayerData.Get(player, "IsOnArena") ~= true
		--or (player:GetAttribute("Lives") or 0) <= 0 
	then 
		return false 
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health > 0
end

local function getSubject(player)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character and character:IsDescendantOf(workspace)
		and humanoid and humanoid.Health > 0 and root then
		return if VisualRig.Get(character) then VisualRig.Subject(character) else humanoid
	end
	return nil
end

local function restoreCamera()
	local camera = workspace.CurrentCamera
	if not camera then return end
	camera.CameraType = Enum.CameraType.Custom
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	restorePending = humanoid == nil
	if humanoid then camera.CameraSubject = humanoid end
	if previousFOV then camera.FieldOfView = previousFOV end
end

local function updateUI()
	if not ui then return end
	local index = table.find(targets, selected) or 0
	local ready = getSubject(selected) ~= nil
	ui.Label.Text = if selected and ready
		then string.format("%s (@%s) (%d/%d)", selected.DisplayName, selected.Name, index, #targets)
		else "Loading player..."
	local enabled = #targets > 1
	ui.Left.Interactable, ui.Right.Interactable = enabled, enabled
	ui.Left.TextTransparency, ui.Right.TextTransparency = if enabled then 0 else 0.6, if enabled then 0 else 0.6
end

local function applyCamera()
	if not isSpectating then return end
	local subject = getSubject(selected)
	local camera = workspace.CurrentCamera
	if subject and camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = subject
	end
	updateUI()
end

function SpectateController.CanSpectate()
	if not outsideCombat() then return false end
	for _, player in Players:GetPlayers() do
		if eligible(player) then return true end
	end
	return false
end

local function createUI()
	local sg = Instance.new("ScreenGui")
	sg.Name, sg.ResetOnSpawn, sg.Enabled = "SpectateGui", false, false
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	local frame = Instance.new("Frame")
	frame.Name = "SpectateFrame"
	frame.Size = UDim2.fromOffset(380, 55)
	frame.AnchorPoint, frame.Position = Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -40)
	frame.BackgroundColor3, frame.BackgroundTransparency = Color3.new(0, 0, 0), 0.5
	frame.Parent = sg
	local constraint = Instance.new("UISizeConstraint", frame)
	constraint.MaxSize = Vector2.new(380, 55)
	frame.Size = UDim2.new(0.9, 0, 0, 55)
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 14)
	local stroke = Instance.new("UIStroke", frame)
	stroke.Color, stroke.Thickness = Color3.new(0, 0, 0), 2.5
	local label = Instance.new("TextLabel")
	label.Name = "PlayerName"
	label.Size, label.Position = UDim2.new(1, -100, 1, 0), UDim2.fromOffset(50, 0)
	label.BackgroundTransparency, label.TextColor3 = 1, Color3.new(1, 1, 1)
	label.Font, label.TextSize, label.TextWrapped = Enum.Font.LuckiestGuy, 18, true
	label.Parent = frame
	local function arrow(name, text, position, direction)
		local button = Instance.new("TextButton")
		button.Name, button.Text = name, text
		button.Size, button.Position = UDim2.new(0, 50, 1, 0), position
		button.BackgroundTransparency, button.TextColor3 = 1, Color3.new(1, 1, 1)
		button.Font, button.TextSize, button.Parent = Enum.Font.LuckiestGuy, 22, frame
		button.Activated:Connect(function()
			if not isSpectating or #targets < 2 then return end
			local index = table.find(targets, selected) or 1
			selectTarget(targets[((index - 1 + direction) % #targets) + 1])
		end)
		return button
	end
	ui = {
		Gui = sg, Label = label,
		Left = arrow("PreviousPlayer", "◀", UDim2.fromOffset(0, 0), -1),
		Right = arrow("NextPlayer", "▶", UDim2.new(1, -50, 0, 0), 1),
	}
end

function SpectateController.Toggle(forceState)
	SpectateController.Init()
	local enabled = if forceState == nil then not isSpectating else forceState == true
	if enabled and not SpectateController.CanSpectate() then enabled = false end
	if enabled == isSpectating then return end
	isSpectating = enabled
	if enabled then
		local camera = workspace.CurrentCamera
		previousFOV = camera and camera.FieldOfView or nil
		table.clear(skipped)
		PlayerData.SetLocal(LocalPlayer, "ShiftLock", false)
		PlayerData.SetLocal(LocalPlayer, "IsSpectating", true)
		ui.Gui.Enabled = true
		refresh()
	else
		selected= nil 
		ui.Gui.Enabled = false
		PlayerData.SetLocal(LocalPlayer, "IsSpectating", false)
		restoreCamera()
		previousFOV = nil
		table.clear(skipped)
	end
	if not forceState then
		requestStreamingEvent:FireServer(nil)
	end
	changed:Fire()
end

selectTarget = function(player)
	if not isSpectating or not player then return end
	requestStreamingEvent:FireServer(player)
	selected = player
	applyCamera()
end

refresh = function()
	local oldIndex = table.find(targets, selected) or 1
	table.clear(targets)
	for _, player in Players:GetPlayers() do
		if eligible(player) and (not isSpectating or not skipped[player]) then
			table.insert(targets, player)
		end
	end
	table.sort(targets, function(a, b) return a.UserId < b.UserId end)
	if isSpectating then
		if not outsideCombat() or #targets == 0 then
			SpectateController.Toggle(false)
		elseif not table.find(targets, selected) then
			selectTarget(targets[math.min(oldIndex, #targets)])
		else
			applyCamera()
			updateUI()
		end
	end
	changed:Fire()
end

local function queueRefresh()
	if refreshQueued then return end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refresh()
	end)
end

local function disconnect(list)
	for _, connection in list do connection:Disconnect() end
	table.clear(list)
end

local function watchPlayer(player)
	if watches[player] then return end
	local watch = {player = {}, character = {}}
	watches[player] = watch
	local function watchCharacter(character)
		disconnect(watch.character)
		if not character then return end
		local humanoidConnection = nil
		local function bindHumanoid()
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and not humanoidConnection then
				humanoidConnection = humanoid.HealthChanged:Connect(queueRefresh)
				table.insert(watch.character, humanoidConnection)
			end
		end
		bindHumanoid()
		table.insert(watch.character, character.DescendantAdded:Connect(function(ins)
			if ins.Name == "HumanoidRootPart" then
				if skipped[player] then
					skipped[player] = false
				end
			end
			bindHumanoid()
			if player == LocalPlayer and restorePending and not isSpectating then restoreCamera() end
			queueRefresh()
		end))
		table.insert(watch.character, character.DescendantRemoving:Connect(function(instance)
			if player == selected and instance.Name == "HumanoidRootPart" then
				skipped[player] = true
			end
			queueRefresh()
		end))
		queueRefresh()
	end
	for _, attribute in {"IsOnArena", "IsInTrainingArea", "Lives"} do
		table.insert(watch.player, PlayerData.Observe(player, attribute, function()
			if player == LocalPlayer and isSpectating and not outsideCombat() then
				SpectateController.Toggle(false)
			end
			queueRefresh()
		end))
	end
	table.insert(watch.player, player.CharacterAdded:Connect(function(character)
		if player == LocalPlayer then SpectateController.Toggle(false) end
		watchCharacter(character)
	end))
	table.insert(watch.player, player.CharacterRemoving:Connect(function()
		if player == LocalPlayer then SpectateController.Toggle(false) end
		if player == selected then skipped[player] = true end
		disconnect(watch.character)
		queueRefresh()
	end))
	watchCharacter(player.Character)
end

function SpectateController.Init()
	RunService.PreRender:Connect(function()
		if isSpectating then
			applyCamera()
		end
	end)
	if initialized then return end
	initialized = true
	createUI()
	
	Players.PlayerAdded:Connect(function(player) watchPlayer(player)
queueRefresh() end)
	Players.PlayerRemoving:Connect(function(player)
		local watch = watches[player]
		if watch then disconnect(watch.player)
disconnect(watch.character)
watches[player] = nil end
		skipped[player] = true
		if player == selected then selected = nil end
		queueRefresh()
	end)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if isSpectating then applyCamera() else restoreCamera() end
	end)
	for _, player in Players:GetPlayers() do watchPlayer(player) end
	refresh()
end

return SpectateController
