local Service = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local requestStreamingEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("SpectateRequestStreaming")

local focusCache = {} :: {[Player]: BasePart}
function Service.Init()
	requestStreamingEvent.OnServerEvent:Connect(function(player: Player, targetPlayer: Player?)
		if focusCache[player] then
			player:RemoveReplicationFocus(focusCache[player])
			focusCache[player] = nil
		end
		if targetPlayer and targetPlayer.Character then
			local root = targetPlayer.Character.PrimaryPart
			if root then
				player:AddReplicationFocus(root)
				focusCache[player] = root
			end
			
		end
	end)
end

return Service
