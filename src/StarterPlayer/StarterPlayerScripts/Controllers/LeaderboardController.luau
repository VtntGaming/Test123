local LeaderboardController = {}

-- ==========================================
-- SERVICES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateLeaderboardEvent = Events:WaitForChild("UpdateLeaderboardEvent")

local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)
local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)

local cachedData = {}

-- ==========================================
-- LOGIC
-- ==========================================
local function updateFrame(frame, rank, name, value)
	local valuesFolder = frame:FindFirstChild("Values")
	if not valuesFolder then return end

	local userLabel = valuesFolder:FindFirstChild("Username")
	local valueLabel = valuesFolder:FindFirstChild("Value")
	local numImage = valuesFolder:FindFirstChild("NumberImage")

	if userLabel then 
		userLabel.Text = name 
		userLabel.TextColor3 = (name == LocalPlayer.Name) and HIGHLIGHT_COLOR or DEFAULT_COLOR
	end

	if valueLabel then 
		valueLabel.Text = tostring(value) 
	end

	if numImage then
		local numLabel = numImage:FindFirstChild("Number")
		if numLabel then numLabel.Text = tostring(rank) end
	end
end

local function updateFilterVisuals(filtersFolder, currentFilter)
	for _, filterName in ipairs({"AllTime", "Day", "Week", "Month"}) do
		print("Checking filter:", filterName, "Current:", currentFilter)
		local btn = filtersFolder:FindFirstChild(filterName)
		if btn and btn:IsA("GuiButton") then
			print("Updating visual for:", filterName, "Current:", currentFilter)
			local transp = (filterName == currentFilter) and 0 or 0.85
			if btn:IsA("ImageButton") then
				btn.ImageTransparency = transp
			end
		end
	end
end

local function renderLeaderboard(lb)
	local track = lb:GetAttribute("Track")
	local currentFilter = lb:GetAttribute("CurrentFilter") or "AllTime"

	if not track or not cachedData[track] or not cachedData[track][currentFilter] then return end

	local data = cachedData[track][currentFilter]
	local primaryPart = lb.PrimaryPart
	if not primaryPart then return end

	local surfaceGui = primaryPart:FindFirstChild("SurfaceGui")
	if not surfaceGui then return end

	local contents = surfaceGui:FindFirstChild("Frame") and surfaceGui.Frame:FindFirstChild("Contents")
	if not contents then return end

	local items = contents:FindFirstChild("Items")
	local myRankFrame = contents:FindFirstChild("MyRankFrame")
	if not items or not myRankFrame then return end

	local topFrames = {
		items:FindFirstChild("Frame1"),
		items:FindFirstChild("Frame2"),
		items:FindFirstChild("Frame3")
	}
	local frame4 = items:FindFirstChild("Frame4")

	if not (topFrames[1] and topFrames[2] and topFrames[3] and frame4) then return end

	for _, child in ipairs(items:GetChildren()) do
		if child.Name == "CloneFrame" then child:Destroy() end
	end

	for _, frame in ipairs(topFrames) do frame.Visible = false end
	frame4.Visible = false

	local playerRankFound = nil

	for _, entry in ipairs(data) do
		if entry.Name == LocalPlayer.Name then
			playerRankFound = entry.Rank
		end

		if entry.Rank <= 3 then
			local targetFrame = topFrames[entry.Rank]
			targetFrame.Visible = true
			updateFrame(targetFrame, entry.Rank, entry.Name, entry.Value)
		else
			local clone = frame4:Clone()
			clone.Name = "CloneFrame"
			clone.Visible = true
			updateFrame(clone, entry.Rank, entry.Name, entry.Value)
			clone.Parent = items
		end
	end

	local myValue = LocalPlayer:GetAttribute(track .. "_" .. currentFilter) or LocalPlayer:GetAttribute(track) or 0
	local displayRank = playerRankFound or "100+"

	myRankFrame.Visible = true
	updateFrame(myRankFrame, displayRank, LocalPlayer.Name, myValue)
end

local function setupFilters(lb)
	task.spawn(function()
		local primaryPart = lb.PrimaryPart
		while not primaryPart do
			task.wait(0.1)
			primaryPart = lb.PrimaryPart
		end

		local surfaceGui = primaryPart:WaitForChild("SurfaceGui", 10)
		if not surfaceGui then return end

		local frame = surfaceGui:WaitForChild("Frame", 10)
		if not frame then return end

		local filters = frame:WaitForChild("Filters", 10)
		if not filters then return end

		lb:SetAttribute("CurrentFilter", "AllTime")
		updateFilterVisuals(filters, "AllTime")

		for _, filterName in ipairs({"AllTime", "Day", "Week", "Month"}) do
			local btn = filters:WaitForChild(filterName, 5)
			if btn and btn:IsA("GuiButton") then
				btn.Active = true 
				btn.Activated:Connect(function()
					if lb:GetAttribute("CurrentFilter") ~= filterName then
						lb:SetAttribute("CurrentFilter", filterName)
					end
				end)
			end
		end

		-- Quando il filtro cambia, aggiorna la UI
		-- English: Update the UI when the filter changes.
		lb:GetAttributeChangedSignal("CurrentFilter"):Connect(function()
			updateFilterVisuals(filters, lb:GetAttribute("CurrentFilter"))
			renderLeaderboard(lb)
		end)
	end)
end

-- ==========================================
-- INIT
-- ==========================================
function LeaderboardController.Init()
	for _, lb in ipairs(CollectionService:GetTagged("Leaderboard")) do
		setupFilters(lb)
	end

	CollectionService:GetInstanceAddedSignal("Leaderboard"):Connect(setupFilters)

	UpdateLeaderboardEvent.OnClientEvent:Connect(function(track, trackData)
		cachedData[track] = trackData
		for _, lb in ipairs(CollectionService:GetTagged("Leaderboard")) do
			if lb:GetAttribute("Track") == track then
				renderLeaderboard(lb)
			end
		end
	end)
end

return LeaderboardController