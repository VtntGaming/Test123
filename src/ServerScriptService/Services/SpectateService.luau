local Service = {}

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local requestStreamingEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("SpectateRequestStreaming")

local focusCache = {} :: {[Player]: BasePart}

local function getTargetRoot(target: Instance): BasePart?
	if target:IsA("Player") then
		if target.Parent ~= Players then return nil end
		local character = target.Character
		if not character or not character:IsDescendantOf(workspace) then return nil end
		local root = character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end

	if target:IsA("Model") and target:GetAttribute("IsBot") == true
		and target:GetAttribute("IsOnArena") == true and CollectionService:HasTag(target, "BotActor")
		and target:IsDescendantOf(workspace) then
		local root = target:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end
	return nil
end

function Service.Init()
	requestStreamingEvent.OnServerEvent:Connect(function(player: Player, target: Instance?)
		if focusCache[player] then
			player:RemoveReplicationFocus(focusCache[player])
			focusCache[player] = nil
		end
		if target and typeof(target) == "Instance" then
			local root = getTargetRoot(target)
			if root then
				player:AddReplicationFocus(root)
				focusCache[player] = root
			end
		end
	end)
end

return Service
