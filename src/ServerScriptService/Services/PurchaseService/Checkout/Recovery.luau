--!strict
-- Resolves orphaned managed payments through product capabilities and durable coin compensation.

--// Services
local Players = game:GetService("Players")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local AnalyticsService = require(Services.AnalyticsService)
local Types = require(Services.PurchaseService.Types)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Receipts = require(Services.PurchaseService.Receipts)

--// Constants
local COINS_PER_ROBUX = 25

--// Properties
local Initialized = false

--// Types
export type Recovery = {
	Resolve: (receipt: Types.Receipt) -> Types.Intent?,
	Setup: () -> (),
}

--// Module
local Recovery = {} :: Recovery

--// APIs
function Recovery.Setup()
	if Initialized then
		return
	end
	Initialized = true
	Receipts.Register("CheckoutCompensation", {
		Apply = function(player: Player, reward: Types.Reward)
			local coins = player:GetAttribute("Coins")
			local amount = reward.Amount
			assert(
				type(coins) == "number" and coins == coins and math.abs(coins) < math.huge,
				"Invalid compensation balance"
			)
			assert(
				type(amount) == "number"
					and amount > 0
					and amount % 1 == 0
					and amount < math.huge
					and coins + amount < math.huge,
				"Invalid compensation amount"
			)
			player:SetAttribute("Coins", coins + amount)
			AnalyticsService.RecordEconomy(player, {
				Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Coins",
				Amount = amount, Balance = coins + amount, TransactionType = "IAP",
				ItemSku = "CheckoutCompensation", Activity = "CheckoutCompensation",
			})
		end,
	})
end

function Recovery.Resolve(receipt)
	local definition = Registry.Get(receipt.ProductId)
	local buyer = Players:GetPlayerByUserId(receipt.PlayerId)
	if not definition or not buyer or buyer:GetAttribute("DataLoaded") ~= true then
		return nil
	end
	local reward: Types.Reward? = nil
	local reason: string? = nil
	if definition.RecoveryReward then
		reward, reason = definition.RecoveryReward(buyer)
	end
	-- Unknown readiness is not proof that a replacement cannot be delivered.
	if reason == "PolicyUnavailable" or reason == "OwnershipUnavailable" or reason == "DataNotLoaded" then
		return nil
	end
	if reward then
		reward.Kind = definition.Kind
	else
		local spent = receipt.CurrencySpent
		if
			type(spent) ~= "number"
			or spent ~= spent
			or spent <= 0
			or spent >= math.huge
			or receipt.CurrencyType ~= Enum.CurrencyType.Robux
		then
			return nil
		end
		local amount = math.round(spent * COINS_PER_ROBUX)
		if amount <= 0 or amount >= math.huge then
			return nil
		end
		reward = { Kind = "CheckoutCompensation", Amount = amount }
	end
	return {
		RequestId = "Replacement:" .. receipt.PurchaseId,
		BuyerId = receipt.PlayerId,
		RecipientId = receipt.PlayerId,
		ProductId = receipt.ProductId,
		Mode = "Self",
		Strategy = "Fast",
		Replacement = true,
		Reward = assert(reward),
		CreatedAt = os.time(),
		Prompted = true,
		PaymentReported = true,
		PurchaseId = receipt.PurchaseId,
	}
end

return Recovery
