--!strict
-- Displays the leading arena preview during intermission and voting.
local Controller = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)

local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")

local IntermissionAssets = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Intermission")
local IntermissionArena = IntermissionAssets:WaitForChild("IntermissionArena")
local IntermissionArenaBackup = IntermissionArena:Clone()
local RefPart = workspace:WaitForChild("Lobby"):WaitForChild("Meshes"):WaitForChild("Props"):WaitForChild("ArenaVote"):WaitForChild("Part")
local ArenaContainer = ReplicatedStorage.Assets.ArenaPreviews

local PREVIEW_CFRAME = CFrame.new(RefPart.Position) * CFrame.new(0, 2, 0)
local NEXT_ARENA_ATTRIBUTE = "NextArena"
local HIGHEST_VOTE_MAP_ATTRIBUTE = "VotingHighestVoteMap"
local ROTATION_TIME = 60
local FLOATING_TIME = 6
local FLOATING_RATE = 2

local function setPreviewVisible(isVisible)
	if not IntermissionArena.Parent then
		IntermissionArena = IntermissionArenaBackup:Clone()
	end

	local targetParent = if isVisible then workspace else IntermissionAssets
	if IntermissionArena.Parent ~= targetParent then
		IntermissionArena.Parent = targetParent
	end
end

local MapPreviewModel: Model?
local CurrentPreview: string?

local function GetMapPreviewModel(mapName: string): Model?
	local map = ArenaContainer:FindFirstChild(mapName)
	if not map then
		return
	end

	local preview = map:Clone() :: Model
	for _, item in ipairs(preview:GetDescendants()) do
		if not item:IsA("Model") and not item:IsA("BasePart") and not item:IsA("Folder") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
		end
	end

	preview:ScaleTo(0.05)
	preview:PivotTo(PREVIEW_CFRAME)

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromHex("#6cfdff")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromHex("#ffffff")
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded

	highlight.Parent = preview
	return preview
end

local function UpdatePreviewModel()
	local currentMap = ReplicatedValues.GetString(ReplicatedStorage, HIGHEST_VOTE_MAP_ATTRIBUTE)
		or ReplicatedValues.GetString(ReplicatedStorage, NEXT_ARENA_ATTRIBUTE)
		or "Island"
	if currentMap == CurrentPreview then
		return
	end

	if MapPreviewModel then
		MapPreviewModel:Destroy()
		MapPreviewModel = nil
	end

	CurrentPreview = currentMap
	MapPreviewModel = GetMapPreviewModel(currentMap)
	if MapPreviewModel then
		MapPreviewModel.Parent = workspace
	end
end

function Controller.Init()
	UpdateGameStateEvent.OnClientEvent:Connect(function(state)
		setPreviewVisible(state ~= "Preparing" and state ~= "Starting" and state ~= "Playing")
	end)

	ReplicatedValues.GetChangedSignal(ReplicatedStorage, HIGHEST_VOTE_MAP_ATTRIBUTE):Connect(UpdatePreviewModel)
	ReplicatedValues.GetChangedSignal(ReplicatedStorage, NEXT_ARENA_ATTRIBUTE):Connect(UpdatePreviewModel)
	UpdatePreviewModel()

	task.spawn(function()
		while task.wait() do
			if not MapPreviewModel then
				continue
			end

			local t = time()
			local rotationProgress = (t % ROTATION_TIME) / ROTATION_TIME
			local floatingProgress = (t % FLOATING_TIME) / FLOATING_TIME

			if floatingProgress < 0.5 then
				floatingProgress = floatingProgress / 0.5
			else
				floatingProgress = 1 - (floatingProgress - 0.5) / 0.5
			end

			local floatingValue = TweenService:GetValue(floatingProgress, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			local cFrame = PREVIEW_CFRAME * CFrame.new(0, floatingValue * FLOATING_RATE, 0) * CFrame.Angles(0, math.rad(rotationProgress * 360), 0)
			MapPreviewModel:PivotTo(cFrame)
		end
	end)
end

return Controller
