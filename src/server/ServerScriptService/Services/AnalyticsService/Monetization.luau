--!strict
-- Constructs custom acquisition, VIP bonus and paid-restock metrics without changing gameplay.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)

--// Types
export type Event = { kind: "Custom", name: string, value: number, customFields: { [string]: string }? }
export type Monetization = {
	PassAcquired: (passName: string, route: "Direct" | "Gift") -> Event,
	VipBonus: (player: Player, bonus: number, activity: string, context: string) -> Event?,
	Restock: (player: Player, productId: number, stockUnits: number) -> Event,
}

--// Module
local Monetization = {} :: Monetization

--// APIs
function Monetization.PassAcquired(passName, route)
	return {
		kind = "Custom",
		name = "GamePassAcquired",
		value = 1,
		customFields = {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = passName,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = route,
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "NotApplicable",
		},
	}
end

function Monetization.VipBonus(player, bonus, activity, context)
	-- C3: zero-bonus grants are not bonus-income observations.
	if bonus <= 0 then
		return nil
	end
	return {
		kind = "Custom",
		name = "VIPBonusCoins",
		value = bonus,
		customFields = {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = activity,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = if PlayerData.Get(player,
					ShopConfig.Passes.VIP.Attribute
				) == true
				then "VIPEnabled"
				else "VIPDisabled",
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = context,
		},
	}
end

function Monetization.Restock(player, productId, stockUnits)
	return {
		kind = "Custom",
		name = "PaidRestockApplied",
		value = stockUnits,
		customFields = {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = tostring(productId),
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = if PlayerData.Get(player,
					ShopConfig.Passes.VIP.Attribute
				) == true
				then "VIPEnabled"
				else "VIPDisabled",
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "Paid",
		},
	}
end

return Monetization
