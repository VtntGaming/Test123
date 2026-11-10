--!native
-- Owns x2 coin buff service behavior and accesses player state through the shared data API.
--// Services
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
--// Constants
--// Variables
local compensationFinished = {} :: {[Player]: boolean}
local module = {}
function module.Init()
    task.spawn(function()
        while true do
            task.wait(1)
            local time_ = os.time()
            for _,player in ipairs(Players:GetPlayers()) do
                if not compensationFinished[player] then
                    continue
                end
				local expiredOn = PlayerData.Get(player, "x2CoinBuffExpiredOn")
				local hasBuff = PlayerData.Get(player, "Has2xCoinsBuff")
                if expiredOn and typeof(expiredOn) == "number" then
                    if expiredOn > time_ then
                        if not hasBuff then
							PlayerData.Set(player, "Has2xCoinsBuff", true)
                        end
                    else
                        if hasBuff then
							PlayerData.Set(player, "Has2xCoinsBuff", false)
                        end
                    end
                end
            end
        end
    end)

    local function CompensateForOffline(player: Player)
        while player.Parent == Players and PlayerData.Get(player, "DataLoaded") ~= true do
			PlayerData.WaitForChange(player, "DataLoaded")
		end
		local offlineWhen = PlayerData.Get(player, "x2CoinBuffOfflineTimestamp")
        if not offlineWhen or typeof(offlineWhen) ~= "number" then
            compensationFinished[player] = true
            return
        end
        if offlineWhen < 0 then
            compensationFinished[player] = true
            return
        end
		local expiredOn = PlayerData.Get(player, "x2CoinBuffExpiredOn")
        if expiredOn and typeof(expiredOn) == "number" then
            local remaining = math.max(0, expiredOn - offlineWhen)
            local newExpiry = os.time() + remaining

			--warn(`Remaining {remaining}`)

			PlayerData.Set(player, "x2CoinBuffExpiredOn", newExpiry)
			PlayerData.Set(player, "x2CoinBuffOfflineTimestamp", -1)
        end
        compensationFinished[player] = true
    end
    Players.PlayerAdded:Connect(CompensateForOffline)
    for _,player in ipairs(Players:GetPlayers()) do
        task.spawn(function()
            CompensateForOffline(player)
        end)
    end

    PlayerDataService.AddPreLeaveHook(function(player: Player)
		PlayerData.Set(player, "x2CoinBuffOfflineTimestamp", os.time())
        compensationFinished[player] = nil
       -- warn(`set`)
    end)
    -- game:BindToClose(function(...)
    --     for _,player in ipairs(Players:GetPlayers()) do
    --         player:SetAttribute("x2CoinBuffOfflineTimestamp", os.time())
    --         warn(`set`)
    --         task.wait(0.1)
    --     end
    -- end)
end

return module
