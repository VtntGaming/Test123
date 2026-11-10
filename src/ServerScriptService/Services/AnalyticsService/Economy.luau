--!strict
-- Captures resource transactions with bounded weapon-family SKUs and counts inventory without changing player state.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local ChestInventory = require(ReplicatedStorage.SharedModules.ChestInventory)
local ShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)

--// Types
export type Resource = "Coins" | "Chests" | "Weapons" | "Abilities"
export type TransactionType = "IAP" | "TimedReward" | "Shop" | "Gameplay"
export type Counts = { [string]: number }
export type Input = {
	Flow: Enum.AnalyticsEconomyFlowType,
	Resource: Resource,
	Amount: number,
	Balance: number,
	TransactionType: TransactionType,
	ItemSku: string,
	Activity: string,
	Context: string?,
}
export type Event = {
	kind: "Economy",
	flow: Enum.AnalyticsEconomyFlowType,
	resource: Resource,
	amount: number,
	balance: number,
	transactionType: string,
	itemSku: string,
	customFields: { [string]: string },
}
export type Economy = {
	ListCounts: (value: string) -> Counts,
	Total: (counts: Counts) -> number,
	ChestCounts: (player: Player) -> Counts,
	Build: (player: Player, input: Input) -> Event?,
	InventoryChanges: (
		resource: Resource,
		before: Counts,
		after: Counts,
		transactionType: TransactionType,
		activity: string
	) -> { Input },
}

--// Constants
local TransactionNames: { [TransactionType]: string } = {
	IAP = Enum.AnalyticsEconomyTransactionType.IAP.Name,
	TimedReward = Enum.AnalyticsEconomyTransactionType.TimedReward.Name,
	Shop = Enum.AnalyticsEconomyTransactionType.Shop.Name,
	Gameplay = Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
}

--// Module
local Economy = {} :: Economy

--// APIs
function Economy.ListCounts(value)
	local counts: Counts = {}
	for _, item in string.split(value, ",") do
		if item ~= "" then
			counts[item] = (counts[item] or 0) + 1
		end
	end
	return counts
end

function Economy.Total(counts)
	local total = 0
	for _, count in counts do
		total += count
	end
	return total
end

function Economy.ChestCounts(player)
	return ChestInventory.Decode(player:GetAttribute("OwnedChests"))
end

function Economy.Build(player, input)
	-- C1: bad telemetry is discarded without affecting the completed resource mutation.
	local amount, balance = input.Amount, input.Balance
	if
		amount ~= amount
		or amount <= 0
		or amount >= math.huge
		or balance ~= balance
		or balance < 0
		or balance >= math.huge
	then
		return nil
	end
	local itemSku = input.ItemSku
	local context = input.Context or "NotApplicable"
	if input.Resource == "Weapons" then
		-- C9: retired/unrecognized names remain one bounded reporting group.
		local info = WeaponConfig.GetWeaponInfo(input.ItemSku)
		itemSku = if info then "Weapon:" .. info.BaseName else "Weapon:Unknown"
		context = if info then "Variant:" .. info.Variant else "Variant:Unknown"
	end
	return {
		kind = "Economy",
		flow = input.Flow,
		resource = input.Resource,
		amount = amount,
		balance = balance,
		transactionType = TransactionNames[input.TransactionType],
		itemSku = itemSku,
		customFields = {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = input.Activity,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = if player:GetAttribute(
					ShopConfig.Passes.VIP.Attribute
				) == true
				then "VIPEnabled"
				else "VIPDisabled",
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = context,
		},
	}
end

-- Aggregate resource balance advances per item; no inventory value is written here.
function Economy.InventoryChanges(resource, before, after, transactionType, activity)
	local keys: { [string]: boolean } = {}
	for item in before do
		keys[item] = true
	end
	for item in after do
		keys[item] = true
	end
	local names: { string } = {}
	for item in keys do
		table.insert(names, item)
	end
	table.sort(names)
	local balance = Economy.Total(before)
	local events: { Input } = {}
	for _, source in { false, true } do
		for _, item in names do
			local delta = (after[item] or 0) - (before[item] or 0)
			if (source and delta > 0) or (not source and delta < 0) then
				balance += delta
				table.insert(events, {
					Flow = if source then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink,
					Resource = resource,
					Amount = math.abs(delta),
					Balance = balance,
					TransactionType = transactionType,
					ItemSku = item,
					Activity = activity,
				})
			end
		end
	end
	return events
end

return Economy
