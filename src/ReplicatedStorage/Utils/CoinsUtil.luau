--!strict
-- Grants multiplied coins and returns the actual delta, balance and rounded VIP contribution.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)

--// Constants
local PassesConfig = RobuxShopConfig.Passes

--// Types
export type CoinsUtil = {
	GiveCoins: (self: CoinsUtil, player: Player, amount: number, rewardType: string?) -> (number, number, number),
}

--// Module
local CoinsUtil = {} :: CoinsUtil

--// APIs
function CoinsUtil:GiveCoins(player, amount, rewardType)
	if player:GetAttribute("Has2xCoins") and rewardType == "MatchReward" then
		amount *= 2
	end
	if player:GetAttribute("Has2xCoinsBuff") and rewardType == "MatchReward" then
		amount *= 2
	end
	local withoutVip = amount
	if player:GetAttribute(PassesConfig.VIP.Attribute) then
		amount *= PassesConfig.VIP.Benefits.CoinMultiplier
	end
	local storedCoins = player:GetAttribute("Coins")
	local coins = if type(storedCoins) == "number" then storedCoins else 0
	local balance = math.round(coins + amount)
	local vipBonus = balance - math.round(coins + withoutVip)
	player:SetAttribute("Coins", balance)
	return balance - coins, balance, vipBonus
end

return CoinsUtil
