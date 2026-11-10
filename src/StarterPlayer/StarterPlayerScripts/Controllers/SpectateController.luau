local SpectateController = {}
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer :: Player
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
local botWatches = {}

local function outsideCombat()
	return LocalPlayer:GetAttribute("IsOnArena") ~= true
		and LocalPlayer:GetAttribute("IsInTrainingArea") ~= true
end

local function eligible(target)
	if target:IsA("Player") then
		if target == LocalPlayer or target.Parent ~= Players
			or target:GetAttribute("IsOnArena") ~= true then
			return false
		end
	elseif not target:IsA("Model") or target:GetAttribute("IsBot") ~= true
		or target:GetAttribute("IsOnArena") ~= true or not CollectionService:HasTag(target, "BotActor")
		or not target:IsDescendantOf(workspace) then
		return false
	end
	local character = if target:IsA("Player") then target.Character else target
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health > 0
end

local function getSubject(target)
	local character = if target and target:IsA("Player") then target.Character else target
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character and character:IsDescendantOf(workspace)
		and humanoid and humanoid.Health > 0 and root then
		return humanoid
	end
	return nil
end

local function getTargetLabel(target, index)
	if target:IsA("Player") then
		return string.format("%s (@%s) (%d/%d)", target.DisplayName, target.Name, index, #targets)
	end
	local name = target:GetAttribute("Username") or target.Name
	return string.format("%s (@%s) (%d/%d)", name, name, index, #targets)
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
		then getTargetLabel(selected, index)
		else "Loading target..."
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
	for _, bot in CollectionService:GetTagged("BotActor") do
		if eligible(bot) then return true end
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
		LocalPlayer:SetAttribute("ShiftLock", false)
		LocalPlayer:SetAttribute("IsSpectating", true)
		ui.Gui.Enabled = true
		refresh()
	else
		selected= nil 
		ui.Gui.Enabled = false
		LocalPlayer:SetAttribute("IsSpectating", false)
		restoreCamera()
		previousFOV = nil
		table.clear(skipped)
	end
	if not forceState then
		requestStreamingEvent:FireServer(nil)
	end
	changed:Fire()
end

selectTarget = function(target)
	if not isSpectating or not target then return end
	requestStreamingEvent:FireServer(target)
	selected = target
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
	for _, bot in CollectionService:GetTagged("BotActor") do
		if eligible(bot) and (not isSpectating or not skipped[bot]) then
			table.insert(targets, bot)
		end
	end
	table.sort(targets, function(a, b)
		local aName = if a:IsA("Player") then a.Name else a:GetAttribute("Username") or a.Name
		local bName = if b:IsA("Player") then b.Name else b:GetAttribute("Username") or b.Name
		return aName < bName
	end)
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
		table.insert(watch.player, player:GetAttributeChangedSignal(attribute):Connect(function()
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

local function watchBot(bot)
	if botWatches[bot] then return end
	skipped[bot] = nil
	local connections = {}
	botWatches[bot] = connections
	local watchedHumanoid
	local humanoidConnection
	local function bindHumanoid()
		local humanoid = bot:FindFirstChildOfClass("Humanoid")
		if humanoid ~= watchedHumanoid then
			if humanoidConnection then
				humanoidConnection:Disconnect()
			end
			watchedHumanoid = humanoid
			humanoidConnection = if humanoid then humanoid.HealthChanged:Connect(queueRefresh) else nil
			if humanoidConnection then
				table.insert(connections, humanoidConnection)
			end
		end
	end
	for _, attribute in {"IsOnArena", "IsBot", "Lives"} do
		table.insert(connections, bot:GetAttributeChangedSignal(attribute):Connect(queueRefresh))
	end
	bindHumanoid()
	table.insert(connections, bot.DescendantAdded:Connect(function(instance)
		if instance.Name == "HumanoidRootPart" then
			skipped[bot] = nil
		end
		bindHumanoid()
		queueRefresh()
	end))
	table.insert(connections, bot.DescendantRemoving:Connect(function(instance)
		if instance == watchedHumanoid then
			if humanoidConnection then
				humanoidConnection:Disconnect()
				humanoidConnection = nil
			end
			watchedHumanoid = nil
		end
		if instance.Name == "HumanoidRootPart" and selected == bot then
			skipped[bot] = true
		end
		queueRefresh()
	end))
	table.insert(connections, bot.AncestryChanged:Connect(queueRefresh))
	queueRefresh()
end

local function unwatchBot(bot)
	local connections = botWatches[bot]
	if not connections then return end
	for _, connection in connections do
		connection:Disconnect()
	end
	botWatches[bot] = nil
	skipped[bot] = true
	queueRefresh()
end

function SpectateController.Init()
	if initialized then return end
	initialized = true
	createUI()
	
	Players.PlayerAdded:Connect(function(player) watchPlayer(player); queueRefresh() end)
	Players.PlayerRemoving:Connect(function(player)
		local watch = watches[player]
		if watch then disconnect(watch.player); disconnect(watch.character); watches[player] = nil end
		skipped[player] = true
		if player == selected then selected = nil end
		queueRefresh()
	end)
	CollectionService:GetInstanceAddedSignal("BotActor"):Connect(watchBot)
	CollectionService:GetInstanceRemovedSignal("BotActor"):Connect(unwatchBot)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if isSpectating then applyCamera() else restoreCamera() end
	end)
	for _, player in Players:GetPlayers() do watchPlayer(player) end
	for _, bot in CollectionService:GetTagged("BotActor") do watchBot(bot) end
	refresh()
end

return SpectateController
