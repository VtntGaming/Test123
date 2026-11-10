--!strict
-- Publishes map choices, vote totals and voting deadlines for the current match.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local GameConfig = require(ReplicatedStorage.SharedModules.GameConfig)

--// References
local ArenasFolder = ReplicatedStorage.Assets.Arenas
local VotingEvent = ReplicatedStorage.Events.VotingEvent :: RemoteEvent

--// Attributes
local VOTING_END_TIME_ATTRIBUTE = "VotingEndTime"

--// Constants
local MAXIMUM_MAP_VOTE = 4

--// Properties
local PlayerVotes: { [Player]: string } = {}
local MapPool: { string } = {}
local VoteCounts: { [string]: number } = {}
local HighestVoteCandidates: { string } = {}
local HighestVoteIndex = 0
local IsStarted = false

--// Types
export type VotingService = {
    SettedUp: boolean?,
	Setup: (self: VotingService) -> (),
	Start: (self: VotingService) -> (),
	Init: () -> (),
	Reset: (self: VotingService) -> (),
	GetResult: (self: VotingService) -> string,
	SetVotingEnabled: (self: VotingService, enabled: boolean, duration: number?) -> (),
}

local VotingService = {} :: VotingService

--// Local functions
local function GetAvailableMaps(): { string }
	local availableMaps = {}
	for _, arena in ipairs(ArenasFolder:GetChildren()) do
		if arena:IsA("Model") then
			table.insert(availableMaps, arena.Name)
		end
	end

	local mapPool = {}
	while #availableMaps > 0 and #mapPool < MAXIMUM_MAP_VOTE do
		local mapIndex = math.random(1, #availableMaps)

        local result = table.remove(availableMaps, mapIndex)

        if result then
            table.insert(mapPool, result)
        end
	end
	table.sort(mapPool)
	return mapPool
end

local function PublishMapPool()
	-- Roblox attributes cannot store arrays or dictionaries, so structured data is JSON encoded.
	ReplicatedValues.Set(ReplicatedStorage, "VotingMapPool", HttpService:JSONEncode(MapPool))
end

local function PublishVotingProgress()
	local progress: { [string]: { string } } = {}
	for _, mapName in ipairs(MapPool) do
		progress[mapName] = {}
	end
    
	for player, mapName in pairs(PlayerVotes) do
		local voters = progress[mapName]
		if voters then
			table.insert(voters, player.Name)
		end
	end

	for _, voters in pairs(progress) do
		table.sort(voters)
	end

	ReplicatedValues.Set(ReplicatedStorage, "VotingProgress", HttpService:JSONEncode(progress))
end

local function GetLeadingMaps(): { string }
	local highestVoteCount = -1
	local leadingMaps = {}
	for _, mapName in ipairs(MapPool) do
		local voteCount = VoteCounts[mapName] or 0
		if voteCount > highestVoteCount then
			highestVoteCount = voteCount
			table.clear(leadingMaps)
			table.insert(leadingMaps, mapName)
		elseif voteCount == highestVoteCount then
			table.insert(leadingMaps, mapName)
		end
	end
	return leadingMaps
end

local function AreSameMaps(first: { string }, second: { string }): boolean
	if #first ~= #second then
		return false
	end
	for index, mapName in ipairs(first) do
		if mapName ~= second[index] then
			return false
		end
	end
	return true
end

local function UpdateHighestVoteMap()
	if ReplicatedValues.GetBoolean(ReplicatedStorage, "VotingEnabled") ~= true then
		table.clear(HighestVoteCandidates)
		HighestVoteIndex = 0
		ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", nil)
		return
	end

	local leadingMaps = GetLeadingMaps()
	if #leadingMaps == 0 then
		table.clear(HighestVoteCandidates)
		HighestVoteIndex = 0
		ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", nil)
		return
	end

	if not AreSameMaps(HighestVoteCandidates, leadingMaps) then
		HighestVoteCandidates = leadingMaps
		HighestVoteIndex = 1
	elseif #leadingMaps > 1 then
		HighestVoteIndex = (HighestVoteIndex % #leadingMaps) + 1
	else
		HighestVoteIndex = 1
	end

	ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", HighestVoteCandidates[HighestVoteIndex])
end

local function ResolveTie(candidates: { string }): string?
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(1, #candidates)]
end

local function HandleVote(player: Player, mapIndex: unknown)
	if ReplicatedValues.GetBoolean(ReplicatedStorage, "VotingEnabled") ~= true then
		return
	end
	if typeof(mapIndex) ~= "number" or mapIndex % 1 ~= 0 then
		return
	end

	local mapName = MapPool[mapIndex]
	if not mapName or player.Parent ~= Players then
		return
	end

	local previousMap = PlayerVotes[player]
	if previousMap == mapName then
		return
	end
	if previousMap then
		VoteCounts[previousMap] = math.max(0, (VoteCounts[previousMap] or 0) - 1)
	end

	PlayerVotes[player] = mapName
	VoteCounts[mapName] = (VoteCounts[mapName] or 0) + 1
	PublishVotingProgress()
end

function VotingService:Setup()
	if self.SettedUp then
		return
	end
	self.SettedUp = true

	MapPool = GetAvailableMaps()
	for _, mapName in ipairs(MapPool) do
		VoteCounts[mapName] = 0
	end
	PublishMapPool()
	ReplicatedValues.Set(ReplicatedStorage, "VotingResult", nil)
	ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", nil)
	ReplicatedValues.Set(ReplicatedStorage, VOTING_END_TIME_ATTRIBUTE, nil)
	ReplicatedValues.Set(ReplicatedStorage, "VotingEnabled", false)
	PublishVotingProgress()
end

function VotingService:Start()
	if IsStarted then
		return
	end
	self:Setup()
	IsStarted = true

	task.spawn(function()
		while IsStarted do
			UpdateHighestVoteMap()
			task.wait(1)
		end
	end)

	VotingEvent.OnServerEvent:Connect(HandleVote)
	Players.PlayerRemoving:Connect(function(player)
		local mapName = PlayerVotes[player]
		if mapName then
			PlayerVotes[player] = nil
			VoteCounts[mapName] = math.max(0, (VoteCounts[mapName] or 0) - 1)
			PublishVotingProgress()
		end
	end)
end

function VotingService:Reset()
	self:Setup()
	table.clear(PlayerVotes)
	table.clear(VoteCounts)
	MapPool = GetAvailableMaps()
	for _, mapName in ipairs(MapPool) do
		VoteCounts[mapName] = 0
	end
	table.clear(HighestVoteCandidates)
	HighestVoteIndex = 0

	ReplicatedValues.Set(ReplicatedStorage, "VotingEnabled", false)
	ReplicatedValues.Set(ReplicatedStorage, VOTING_END_TIME_ATTRIBUTE, nil)
	ReplicatedValues.Set(ReplicatedStorage, "VotingResult", nil)
	ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", nil)
	PublishMapPool()
	PublishVotingProgress()
end

function VotingService:GetResult(): string
	self:Setup()

	local leadingMaps = GetLeadingMaps()
	local result = ResolveTie(leadingMaps) or "DefaultArena"
	ReplicatedValues.Set(ReplicatedStorage, "VotingResult", result)
	return result
end

function VotingService:SetVotingEnabled(enabled: boolean, duration: number?)
	self:Setup()
	if enabled then
		ReplicatedValues.Set(ReplicatedStorage,
			VOTING_END_TIME_ATTRIBUTE,
			Workspace:GetServerTimeNow() + (duration or GameConfig.VoteTime)
		)
	else
		ReplicatedValues.Set(ReplicatedStorage, VOTING_END_TIME_ATTRIBUTE, nil)
	end
	ReplicatedValues.Set(ReplicatedStorage, "VotingEnabled", enabled)
	if not enabled then
		table.clear(HighestVoteCandidates)
		HighestVoteIndex = 0
		ReplicatedValues.Set(ReplicatedStorage, "VotingHighestVoteMap", nil)
	end
end

function VotingService.Init()
	VotingService:Setup()
	VotingService:Start()
end

return VotingService
