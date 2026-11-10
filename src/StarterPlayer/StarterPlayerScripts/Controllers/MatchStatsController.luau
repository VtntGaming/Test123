local MatchStatsController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

-- ==========================================
-- VARIABLES
-- ==========================================
local playingContainer = nil
local waitingContainer = nil
local playerIcons = {}
local botIcons = {}
local npcConnections = {}

-- ==========================================
-- UI UPDATES
-- ==========================================
local function updatePlayerCounts()
	if not playingContainer or not waitingContainer then return end

	local playing, waiting = 0, 0
	local players = Players:GetPlayers()
	local allPlayersAFK = #players > 0
	for _, player in players do
		if not player:GetAttribute("IsAFK") then
			allPlayersAFK = false
			break
		end
	end

	for _, p in Players:GetPlayers() do
		if p:GetAttribute("IsOnArena") then 
			playing += 1 
		elseif not p:GetAttribute("IsAFK") then
			waiting += 1
		end
	end

	for npc, container in botIcons do
		local isPlaying = npc.Parent ~= nil and npc:GetAttribute("IsOnArena") == true
		local isAFK = not isPlaying and npc:GetAttribute("IsAFK") == true -- set by LobbyNPCService
		if npc:GetAttribute("IsAFK") ~= isAFK then
			npc:SetAttribute("IsAFK", isAFK)
		end

		if isPlaying then
			container.Parent = playingContainer.PlayersContainer
			playing += 1
		elseif isAFK then
			container.Parent = nil
		else
			container.Parent = waitingContainer.PlayersContainer
			waiting += 1
		end
	end

	local tPlaying = playingContainer:FindFirstChild("Title")
	if tPlaying and tPlaying:FindFirstChild("Value") then tPlaying.Value.Text = tostring(playing) end

	local tWaiting = waitingContainer:FindFirstChild("Title")
	if tWaiting and tWaiting:FindFirstChild("Value") then tWaiting.Value.Text = tostring(waiting) end
end

local function updatePlayerState(player)
	local container = playerIcons[player]
	if not container or not playingContainer or not waitingContainer then return end

	if player:GetAttribute("IsOnArena") then
		container.Parent = playingContainer.PlayersContainer
	elseif not player:GetAttribute("IsAFK") then
		container.Parent = waitingContainer.PlayersContainer
	else
		container.Parent = nil
	end

	updatePlayerCounts()
end

-- ==========================================
-- ICONS MANAGEMENT
-- ==========================================
local function createPlayerIcon(name: string, userId: number?)
	local container = Instance.new("Frame")
	container.Name = name
	container.Size = UDim2.new(0, 75, 0, 75)
	container.BackgroundColor3 = Color3.fromRGB(255, 255, 255)

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(1, 0)
	containerCorner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 2
	stroke.Parent = container

	local icon = Instance.new("ImageLabel")
	icon.Name = "Thumbnail"
	icon.Size = UDim2.new(1, 0, 1, 0)
	icon.BackgroundTransparency = 1
	icon.Parent = container

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	if userId and userId > 0 then
		icon.Image = `rbxthumb://type=AvatarHeadShot&id={userId}&w=150&h=150`
	else
		local initials = Instance.new("TextLabel")
		initials.Name = "Initials"
		initials.Size = UDim2.fromScale(1, 1)
		initials.BackgroundTransparency = 1
		initials.Text = string.sub(name, 1, 1)
		initials.TextColor3 = Color3.fromRGB(40, 40, 40)
		initials.TextScaled = true
		initials.Font = Enum.Font.GothamBold
		initials.Parent = container
	end

	return container
end

local function handlePlayerAdded(player)
	playerIcons[player] = playerIcons[player] or createPlayerIcon(player.Name, player.UserId)
	player:GetAttributeChangedSignal("IsOnArena"):Connect(function() updatePlayerState(player) end)
	player:GetAttributeChangedSignal("IsAFK"):Connect(function() updatePlayerState(player) end)
	updatePlayerState(player)
end

local function updateNpcState(npc)
	local container = botIcons[npc]
	if not container then return end

	if npc:GetAttribute("IsOnArena") then
		container.Parent = if playingContainer then playingContainer.PlayersContainer else nil
	else
		updatePlayerCounts()
		return
	end
	updatePlayerCounts()
end

local function handleNpcAdded(instance)
	if not instance:IsA("Model") or botIcons[instance] then return end
	local username = instance:GetAttribute("Username")
	local userId = instance:GetAttribute("UserId")
	botIcons[instance] = createPlayerIcon(if type(username) == "string" then username else instance.Name,
		if type(userId) == "number" then userId else nil)
	local connections = {
		instance:GetAttributeChangedSignal("IsOnArena"):Connect(function() updateNpcState(instance) end),
		instance.AncestryChanged:Connect(function() updatePlayerCounts() end),
	}
	npcConnections[instance] = connections
	updateNpcState(instance)
end

local function handleNpcRemoving(instance)
	local container = botIcons[instance]
	if container then
		container:Destroy()
		botIcons[instance] = nil
	end
	for _, connection in npcConnections[instance] or {} do
		connection:Disconnect()
	end
	npcConnections[instance] = nil
	updatePlayerCounts()
end

local function handlePlayerRemoving(player)
	if playerIcons[player] then
		playerIcons[player]:Destroy()
		playerIcons[player] = nil
		updatePlayerCounts()
	end
end

-- ==========================================
-- PANEL SETUP
-- ==========================================
local function setupMatchStatsPanel(statsMesh)
	local surfaceGui = statsMesh:WaitForChild("SurfaceGui", 10)
	if not surfaceGui then return end

	local matchStatsContainer = surfaceGui:WaitForChild("MatchStatsContainer", 5)
	if not matchStatsContainer then return end

	playingContainer = matchStatsContainer:WaitForChild("PlayingContainer")
	waitingContainer = matchStatsContainer:WaitForChild("WaitingContainer")

	for _, container in ipairs({playingContainer, waitingContainer}) do
		local pContainer = container:FindFirstChild("PlayersContainer")
		if pContainer then
			pContainer.AutomaticSize = Enum.AutomaticSize.Y
			if pContainer:IsA("ScrollingFrame") then
				pContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
			end
		end
	end

	for player in pairs(playerIcons) do
		updatePlayerState(player)
	end
	for npc in pairs(botIcons) do
		updateNpcState(npc)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function MatchStatsController.Init()
	CollectionService:GetInstanceAddedSignal("MatchStats"):Connect(setupMatchStatsPanel)
	CollectionService:GetInstanceAddedSignal("BotActor"):Connect(handleNpcAdded)
	CollectionService:GetInstanceRemovedSignal("BotActor"):Connect(handleNpcRemoving)
	CollectionService:GetInstanceAddedSignal("LobbyNPC"):Connect(handleNpcAdded)
	CollectionService:GetInstanceRemovedSignal("LobbyNPC"):Connect(handleNpcRemoving)

	for _, mesh in CollectionService:GetTagged("MatchStats") do
		task.spawn(setupMatchStatsPanel, mesh)
	end

	for _, player in Players:GetPlayers() do
		handlePlayerAdded(player)
	end

	for _, npc in CollectionService:GetTagged("BotActor") do
		handleNpcAdded(npc)
	end
	for _, npc in CollectionService:GetTagged("LobbyNPC") do
		handleNpcAdded(npc)
	end

	Players.PlayerAdded:Connect(handlePlayerAdded)
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
end

return MatchStatsController