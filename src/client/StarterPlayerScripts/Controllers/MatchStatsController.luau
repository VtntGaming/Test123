-- Presents match stats controller behavior using logical Player data access.
local MatchStatsController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)

-- ==========================================
-- VARIABLES
-- ==========================================
local playingContainer = nil
local waitingContainer = nil
local playerIcons = {}

-- ==========================================
-- UI UPDATES
-- ==========================================
local function updatePlayerCounts()
	if not playingContainer or not waitingContainer then return end

	local playing, waiting = 0, 0
	for _, p in Players:GetPlayers() do
		if PlayerData.Get(p, "IsOnArena") then
			playing += 1 
		elseif not PlayerData.Get(p, "IsAFK") then
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

	if PlayerData.Get(player, "IsOnArena") then
		container.Parent = playingContainer.PlayersContainer
	elseif not PlayerData.Get(player, "IsAFK") then
		container.Parent = waitingContainer.PlayersContainer
	else
		container.Parent = nil
	end

	updatePlayerCounts()
end

-- ==========================================
-- ICONS MANAGEMENT
-- ==========================================
local function createPlayerIcon(player)
	local container = Instance.new("Frame")
	container.Name = player.Name
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

	task.spawn(function()
		local content, isReady = Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		if isReady then icon.Image = content end
	end)

	return container
end

local function handlePlayerAdded(player)
	playerIcons[player] = playerIcons[player] or createPlayerIcon(player)
	PlayerData.Observe(player, "IsOnArena", function()
		updatePlayerState(player)
	end)
	PlayerData.Observe(player, "IsAFK", function()
		updatePlayerState(player)
	end)
	updatePlayerState(player)
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
end

-- ==========================================
-- INIT
-- ==========================================
function MatchStatsController.Init()
	CollectionService:GetInstanceAddedSignal("MatchStats"):Connect(setupMatchStatsPanel)

	for _, mesh in CollectionService:GetTagged("MatchStats") do
		task.spawn(setupMatchStatsPanel, mesh)
	end

	for _, player in Players:GetPlayers() do
		handlePlayerAdded(player)
	end

	Players.PlayerAdded:Connect(handlePlayerAdded)
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
end

return MatchStatsController
