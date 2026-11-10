-- Presents early player reward controller behavior using logical Player data access.
local EarlyPlayerRewardController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))

local Events = ReplicatedStorage:WaitForChild("Events")
local ClaimEarlyRewardEvent = Events:WaitForChild("ClaimEarlyReward")
-- ==========================================
-- CONSTANTS & VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ui = {}
local state = { selectedChest = nil }

local Zone = require(game.ReplicatedStorage.Utils.Zone)

local function setupEarlyPlayerRewardZone()
	local zonePart = workspace:WaitForChild("Lobby"):WaitForChild("Meshes"):WaitForChild("Environment"):WaitForChild("EarlyPlayerRewardChest"):WaitForChild("EarlyPlayerRewardZone")

	local zone = Zone.new(zonePart)

	zone.localPlayerEntered:Connect(function()
		EarlyPlayerRewardController.Toggle(true)
	end)

	zone.localPlayerExited:Connect(function()
		EarlyPlayerRewardController.Toggle(false)
	end)
end

function EarlyPlayerRewardController.Toggle(forceState)
	local isOpening
	if forceState ~= nil then
		isOpening = forceState
	else
		isOpening = not ui.EarlyPlayerRewardFrame.Visible
	end
	UIInteractionController.ToggleFrame(ui.EarlyPlayerRewardFrame, isOpening)
end

function EarlyPlayerRewardController.Init()
	ui.MainGui = PlayerGui:WaitForChild("MainGui")
	ui.EarlyPlayerRewardFrame = ui.MainGui:WaitForChild("EarlyPlayerRewardFrame")

	setupEarlyPlayerRewardZone()
	ui.EarlyPlayerRewardFrame:WaitForChild("ExitButton").MouseButton1Click:Connect(function() EarlyPlayerRewardController.Toggle(false) end)

	local claimBtn = ui.EarlyPlayerRewardFrame:WaitForChild("Claim") :: GuiButton
	local claimText = claimBtn:WaitForChild("Title") :: TextLabel
	do -- handle claim button and claim event
		claimBtn.MouseButton1Click:Connect(function()
			ClaimEarlyRewardEvent:FireServer()
		end)
		ClaimEarlyRewardEvent.OnClientEvent:Connect(function(enable: boolean)
			EarlyPlayerRewardController.Toggle(enable)
		end)
	end

	do -- format condition text label
		local claimHover = claimBtn:WaitForChild("Hover") :: Frame
		local conditionFrame = ui.EarlyPlayerRewardFrame:WaitForChild("Condition")
		local statLabel = conditionFrame:WaitForChild("StatsLabel") :: TextLabel

		local function onStatChanged()
			local wins = PlayerData.Get(LocalPlayer, "Wins")
			if not wins or typeof(wins) ~= "number" then
				return
			end
			local claimed = PlayerData.Get(LocalPlayer, "EarlyRewardClaimed")
			local canClaimed = wins >= 10 and not claimed
			claimHover.Visible = not canClaimed
			claimBtn.Active = canClaimed
			claimText.Text = if claimed then "CLAIMED" else "CLAIM"
			statLabel.Text = `{math.min(wins, 10)}/10`
		end
		onStatChanged()
		PlayerData.Observe(LocalPlayer, "Wins", onStatChanged)
		PlayerData.Observe(LocalPlayer, "EarlyRewardClaimed", onStatChanged)
	end


end

return EarlyPlayerRewardController
