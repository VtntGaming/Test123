-- Owns leaderboard service behavior and accesses player state through the shared data API.
local LeaderboardService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local DataStoreService = game:GetService("DataStoreService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)

-- ==========================================
-- VARIABLES
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateLeaderboardEvent = Events:FindFirstChild("UpdateLeaderboardEvent") or Instance.new("RemoteEvent", Events)
UpdateLeaderboardEvent.Name = "UpdateLeaderboardEvent"

local nameCache = {}
local lastSavedStats = {} -- Cache per evitare salvataggi doppi inutili
local MAX_PLAYERS_TO_FETCH = 100
local REFRESH_INTERVAL = 60*3 -- 3 mins

-- ==========================================
-- INTERNAL LOGIC
-- ==========================================
local function getPlayerName(userIdString)
	local numericId = tonumber(userIdString)
	if numericId and numericId < 0 then return "Noob" .. math.abs(numericId) end 
	if nameCache[userIdString] then return nameCache[userIdString] end

	local success, name = pcall(function() return Players:GetNameFromUserIdAsync(numericId or userIdString) end)
	nameCache[userIdString] = success and name or "Unknown"
	return nameCache[userIdString]
end

-- Salva le statistiche del giocatore negli OrderedDataStore solo se sono cambiate
local function savePlayerLeaderboardData(player)
	if not lastSavedStats[player.UserId] then lastSavedStats[player.UserId] = {} end
	local pCache = lastSavedStats[player.UserId]

	local function updateStat(track, filterName, attrName, val)
		if type(val) ~= "number" or val <= 0 then return end
		if pCache[attrName] == val then return end -- SKIP: Il valore non è cambiato dall'ultimo salvataggio

		local suffix = (filterName == "AllTime") and "AllTime" or (filterName .. "_" .. os.date((filterName == "Day" and "!%Y_%j") or (filterName == "Week" and "!%Y_%W") or "!%Y_%m"))
		
		local success = pcall(function() 
			DataStoreService:GetOrderedDataStore("GlobalLeaderboard_" .. track .. "_" .. suffix):SetAsync(player.UserId, val) 
		end)

		if success then
			pCache[attrName] = val -- Aggiorna la cache solo se il salvataggio è andato a buon fine
		end
	end

	local tracks = {"Kills", "Wins", "Coins"}
	local filters = {"AllTime", "Day", "Week", "Month"}

	for _, track in ipairs(tracks) do
		for _, filter in ipairs(filters) do
			local attrName = (filter == "AllTime") and track or (track .. "_" .. filter)
			local val = PlayerData.Get(player, attrName)
			if val then
				updateStat(track, filter, attrName, val)
			end
		end
	end
end

-- ==========================================
-- CORE LOGIC
-- ==========================================
function LeaderboardService.RefreshLeaderboards()
	local tracks = {}
	for _, lb in ipairs(CollectionService:GetTagged("Leaderboard")) do
		local track = lb:GetAttribute("Track")
		if track then tracks[track] = true end
	end

	local timeSuffixes = {
		AllTime = "AllTime",
		Day = "Day_" .. os.date("!%Y_%j"),
		Week = "Week_" .. os.date("!%Y_%W"),
		Month = "Month_" .. os.date("!%Y_%m")
	}

	for track in pairs(tracks) do
		local trackData = { AllTime = {}, Day = {}, Week = {}, Month = {} }

		for filterName, suffix in pairs(timeSuffixes) do
			local ods = DataStoreService:GetOrderedDataStore("GlobalLeaderboard_" .. track .. "_" .. suffix)
			local success, pages = pcall(function() return ods:GetSortedAsync(false, MAX_PLAYERS_TO_FETCH) end)

			if success then
				local rankCounter = 1
				for _, entry in ipairs(pages:GetCurrentPage()) do
					table.insert(trackData[filterName], {
						Rank = rankCounter,
						Name = getPlayerName(entry.key),
						Value = entry.value
					})
					rankCounter += 1
				end
			end
		end
		UpdateLeaderboardEvent:FireAllClients(track, trackData)
	end
end

-- ==========================================
-- INIT
-- ==========================================
function LeaderboardService.Init()
	-- Quando un giocatore esce, salviamo un'ultima volta e puliamo la cache
	Players.PlayerRemoving:Connect(function(player)
		savePlayerLeaderboardData(player)
		lastSavedStats[player.UserId] = nil
	end)

	task.spawn(function()
		while true do
			-- 1. Prima di ricaricare le classifiche, salviamo i dati dei giocatori attualmente in partita
			for _, player in ipairs(Players:GetPlayers()) do
				task.spawn(savePlayerLeaderboardData, player)
			end
			
			task.wait(2) -- Piccola pausa per dare tempo ai salvataggi di completarsi
			
			-- 2. Dopodiché aggiorniamo le classifiche visuali
			LeaderboardService.RefreshLeaderboards()
			
			-- 3. Aspettiamo fino al prossimo ciclo
			task.wait(REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
