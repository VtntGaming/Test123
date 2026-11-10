--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

--// Modules
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)
local UIInteractionController = require(script.Parent.UIInteractionController)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local VotingEvent = ReplicatedStorage.Events.VotingEvent :: RemoteEvent
local MapContainer = ReplicatedStorage.Assets.Arenas

--// Constants
local VOTING_DEBOUNCE = 0.25

--// Types
export type VoteCard = {
	Button: ImageButton,
	Title: TextLabel,
	Votes: TextLabel,
	Icon: ImageLabel,
}

export type VotingController = {
	Items: { VoteCard },
	VotingFrame: ImageLabel,
	ExitButton: ImageButton,
	TimerLabel: TextLabel,
	LastVote: number,
	Prompt: ProximityPrompt,
	Init: () -> (),
	Setup: (self: VotingController) -> (),
	Start: (self: VotingController) -> (),
}

local Controller = {} :: VotingController

--// Local functions
local function GetMapPool(): { string }
	local encodedMapPool = ReplicatedStorage:GetAttribute("VotingMapPool")
	if typeof(encodedMapPool) ~= "string" then
		return {}
	end

	local success, decodedMapPool = pcall(function()
		return HttpService:JSONDecode(encodedMapPool)
	end)
	if not success then
		warn("[VotingController] Failed to decode VotingMapPool:", decodedMapPool)
		return {}
	end
	if typeof(decodedMapPool) ~= "table" then
		warn("[VotingController] VotingMapPool must decode to an array.")
		return {}
	end

	local mapPool = {}
	for _, mapName in ipairs(decodedMapPool :: { unknown }) do
		if typeof(mapName) == "string" then
			table.insert(mapPool, mapName)
		end
	end
	return mapPool
end

local function GetVoteCounts(): { [string]: number }
	local encodedProgress = ReplicatedStorage:GetAttribute("VotingProgress")
	if typeof(encodedProgress) ~= "string" then
		return {}
	end

	local success, decodedProgress = pcall(function()
		return HttpService:JSONDecode(encodedProgress)
	end)
	if not success then
		warn("[VotingController] Failed to decode VotingProgress:", decodedProgress)
		return {}
	end
	if typeof(decodedProgress) ~= "table" then
		warn("[VotingController] VotingProgress must decode to a dictionary.")
		return {}
	end

	local voteCounts: { [string]: number } = {}
	for mapName, voters in pairs(decodedProgress :: { [string]: unknown }) do
		if typeof(mapName) == "string" and typeof(voters) == "table" then
			voteCounts[mapName] = #(voters :: { unknown })
		end
	end
	return voteCounts
end

local function IsVotingEnabled(): boolean
	return ReplicatedStorage:GetAttribute("VotingEnabled") == true
end

local function UpdateTimer()
	local endTime = ReplicatedStorage:GetAttribute("VotingEndTime")
	if not IsVotingEnabled() or typeof(endTime) ~= "number" then
		Controller.TimerLabel.Text = ""
		return
	end

	local totalSeconds = math.ceil(math.max(0, endTime - Workspace:GetServerTimeNow()))
	Controller.TimerLabel.Text = tostring(totalSeconds // 1)
end

local function CloseVotingFrame()
	if IsVotingEnabled() then
		return
	end
	UIInteractionController.ToggleFrame(Controller.VotingFrame, false)
end

local function UpdateCards()
	local mapPool = GetMapPool()
	local voteCounts = GetVoteCounts()

	for index, item in ipairs(Controller.Items) do
		local mapName = mapPool[index]
		item.Button.Visible = mapName ~= nil
		item.Button.Active = mapName ~= nil
		item.Title.Text = mapName or ""
		item.Votes.Text = tostring(mapName and voteCounts[mapName] or 0)

		local mapRef = MapContainer:FindFirstChild(mapName)
		local iconId = mapRef and mapRef:GetAttribute("ThumbnailId") :: string

		if iconId then
			item.Icon.Image = iconId
		end
	end
end

function Controller:Setup()
	local playerGui = LocalPlayer.PlayerGui
	local mainGui = playerGui:WaitForChild("MainGui")
	local votingFrame = mainGui:WaitForChild("ArenaVoteFrame")
	local timerFrame = votingFrame:WaitForChild("Timer")
	self.TimerLabel = timerFrame
	self.VotingFrame = votingFrame
	self.ExitButton = self.VotingFrame:WaitForChild("ExitButton") :: ImageButton
	self.LastVote = 0
	self.Items = {}

	for index = 1, 4 do
		local button = self.VotingFrame:WaitForChild("Arena" .. index) :: ImageButton
		table.insert(self.Items, {
			Button = button,
			Title = button:WaitForChild("Title") :: TextLabel,
			Votes = button:WaitForChild("Votes") :: TextLabel,
			Icon = button:WaitForChild("Icon") :: ImageLabel
		})
	end

	local lobby = Workspace:WaitForChild("Lobby")
	local meshes = lobby:WaitForChild("Meshes")
	local props = meshes:WaitForChild("Props")
	local arenaVote = props:WaitForChild("ArenaVote")
	local part = arenaVote:WaitForChild("Part")
	self.Prompt = part:WaitForChild("ProximityPrompt") :: ProximityPrompt

	UpdateCards()
end

function Controller:Start()
	self.Prompt.Triggered:Connect(function()
		if IsVotingEnabled() then
			UIInteractionController.ToggleFrame(self.VotingFrame, true)
			UpdateCards()
		else
			NotificationUtil.Show("Warning", "You cannot vote right now!")
		end
	end)

	self.ExitButton.Activated:Connect(function()
		UIInteractionController.ToggleFrame(self.VotingFrame, false)
	end)

	for index, item in ipairs(self.Items) do
		item.Button.Activated:Connect(function()
			if IsVotingEnabled() and item.Button.Visible then
				if time() - self.LastVote < VOTING_DEBOUNCE then
					NotificationUtil.Show("Warning", "You are voting too fast!")
					return
				end

				self.LastVote = time()
				VotingEvent:FireServer(index)
			end
		end)
	end

	ReplicatedStorage:GetAttributeChangedSignal("VotingEnabled"):Connect(CloseVotingFrame)
	ReplicatedStorage:GetAttributeChangedSignal("VotingEnabled"):Connect(UpdateTimer)
	ReplicatedStorage:GetAttributeChangedSignal("VotingEndTime"):Connect(UpdateTimer)
	ReplicatedStorage:GetAttributeChangedSignal("VotingMapPool"):Connect(UpdateCards)
	ReplicatedStorage:GetAttributeChangedSignal("VotingProgress"):Connect(UpdateCards)

	CloseVotingFrame()
	UpdateCards()
	UpdateTimer()
	task.spawn(function()
		while true do
			task.wait(0.1)
			UpdateTimer()
		end
	end)
end

function Controller.Init()
	Controller:Setup()
	Controller:Start()
end

return Controller
