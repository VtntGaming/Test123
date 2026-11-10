local GroupRewardController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))

local Events = ReplicatedStorage:WaitForChild("Events")
local ClaimGroupRewardEvent = Events:WaitForChild("ClaimGroupRewardEvent")

local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ui = {}
local Zone = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("Zone"))




local prompting = false
local retrying = false

local GroupService = game:GetService("GroupService")
local GROUP_ID = 601719141 

local function promptJoinThenRetry()
	if prompting then return end
	prompting = true
	local ok, err = pcall(function()
		return GroupService:PromptJoinAsync(GROUP_ID)
	end)
	prompting = false

	if not ok then
		warn("[GroupRewardController] PromptJoinAsync failed:", err)
		return
	end

	-- Give Roblox a moment to register the membership, then ask the server to re-check
	task.wait(1.5)
	retrying = true
	ClaimGroupRewardEvent:FireServer()
end

local function setupGroupRewardZone()
	local environment = workspace:WaitForChild("Lobby"):WaitForChild("Meshes"):WaitForChild("Environment")

	-- The zone part sits inside the GroupPlayerRewardChest folder, so search recursively
	local zonePart
	while not zonePart do
		zonePart = environment:FindFirstChild("GroupPlayerRewardZone", true)
		if not zonePart then task.wait(0.5) end
	end

	local zone = Zone.new(zonePart)

	zone.localPlayerEntered:Connect(function()
		GroupRewardController.Toggle(true)
	end)

	zone.localPlayerExited:Connect(function()
		GroupRewardController.Toggle(false)
	end)
end

function GroupRewardController.Toggle(forceState)
	local isOpening
	if forceState ~= nil then
		isOpening = forceState
	else
		isOpening = not ui.Frame.Visible
	end
	UIInteractionController.ToggleFrame(ui.Frame, isOpening)
end

function GroupRewardController.Init()
	ui.MainGui = PlayerGui:WaitForChild("MainGui")
	ui.Frame = ui.MainGui:WaitForChild("GroupPlayerRewardFrame")
	ui.titleClaim = ui.Frame.Claim.Title
	setupGroupRewardZone()	
	ui.Frame:WaitForChild("ExitButton").MouseButton1Click:Connect(function()
		GroupRewardController.Toggle(false)
	end)

	local claimBtn = ui.Frame:WaitForChild("Claim") :: GuiButton
	local claimText = claimBtn:WaitForChild("Title") :: TextLabel
	local claimHover = claimBtn:WaitForChild("Hover") :: Frame

	local function refresh()
		local claimed = LocalPlayer:GetAttribute("GroupRewardClaimed") == true
		claimHover.Visible = claimed
		claimBtn.Active = not claimed
		claimText.Text = if claimed then "CLAIMED" else "CLAIM"
	end
	refresh()
	LocalPlayer:GetAttributeChangedSignal("GroupRewardClaimed"):Connect(refresh)

	claimBtn.MouseButton1Click:Connect(function()
		if LocalPlayer:GetAttribute("GroupRewardClaimed") then return end
		ClaimGroupRewardEvent:FireServer()
	end)

	ClaimGroupRewardEvent.OnClientEvent:Connect(function(result: string)
		if result == "Claimed" then
			retrying = false
			GroupRewardController.Toggle(false)
		elseif result == "NotInGroup" then
			if retrying then
				-- Already prompted once and still not a member (cancelled or pending)
				retrying = false
				claimText.Text = "Join the group first!"
				task.delay(2, refresh)
			else
				promptJoinThenRetry()
			end
		end
	end)
end

return GroupRewardController