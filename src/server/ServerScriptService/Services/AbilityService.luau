--!strict
-- Equips owned abilities and validates coin purchases; Robux unlocks use managed checkout receipts.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Services = game:GetService("ServerScriptService").Services

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local AnalyticsService = require(Services.AnalyticsService)
local Economy = require(Services.AnalyticsService.Economy)
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local PurchaseService = require(Services.PurchaseService)
local PurchaseTypes = require(Services.PurchaseService.Types)
local Receipts = require(Services.PurchaseService.Receipts)
local Checkout = require(Services.PurchaseService.Checkout)
local Registry = require(Services.PurchaseService.ProductRegistry)
local Runtime = require(Services.Helper.ShopRuntime)

--// References
local Events = ReplicatedStorage.Events
local EquipAbilityEvent = Events.EquipAbilityEvent

--// Constants
local OWNED_ABILITY_ATTRIBUTE = "OwnedAbilities"
local EQUIPPED_ABILITY_ATTRIBUTE = "EquippedAbility"

--// Properties
local Initialized = false
local PurchaseRemote: RemoteFunction? = nil
local NextRequest: { [Player]: number } = {}

--// Types
export type AbilityService = {
	RequestPurchase: (player: Player, abilityName: unknown) -> (boolean, string?),
	Setup: (self: AbilityService) -> (),
	Start: (self: AbilityService) -> (),
	Init: () -> (),
}

--// Service
local Service = {} :: AbilityService

--// APIs
local function OwnsAbility(player: Player, abilityName: string): boolean
	local owned = PlayerData.Get(player, OWNED_ABILITY_ATTRIBUTE)
	return type(owned) == "string" and table.find(string.split(owned, ","), abilityName) ~= nil
end

local function ApplyAbility(player: Player, reward: PurchaseTypes.Reward, coinPurchase: boolean)
	local abilityName = reward.Ability
	local owned = PlayerData.Get(player, OWNED_ABILITY_ATTRIBUTE)
	assert(type(abilityName) == "string" and type(owned) == "string", "Invalid ability reward/profile")
	if not OwnsAbility(player, abilityName) then
		PlayerData.Set(
			player,
			OWNED_ABILITY_ATTRIBUTE,
			if owned == "" then abilityName else owned .. "," .. abilityName
		)
		AnalyticsService.RecordEconomy(player, {
			Flow = Enum.AnalyticsEconomyFlowType.Source, Resource = "Abilities",
			Amount = 1, Balance = Economy.Total(Economy.ListCounts(owned)) + 1, TransactionType = if coinPurchase then "Shop" else "IAP",
			ItemSku = abilityName, Activity = "AbilityPurchase",
		})
	end
end

local function GrantAbility(player: Player, reward: PurchaseTypes.Reward)
	ApplyAbility(player, reward, false)
end

function Service.RequestPurchase(player, abilityName)
	if not Runtime.Ready(player) then
		return false, "DataNotLoaded"
	end
	if type(abilityName) ~= "string" then
		return false, "InvalidRequest"
	end
	local config = AbilityConfig.Abilities[abilityName]
	local price = config and config.Price
	if not config or config.Unlisted or not price then
		return false, "Unavailable"
	end
	local value = price.Price
	if type(value) ~= "number" or value < 0 or value >= math.huge or value % 1 ~= 0 then
		return false, "Unavailable"
	end
	local owned = PlayerData.Get(player, OWNED_ABILITY_ATTRIBUTE)
	if type(owned) ~= "string" then
		return false, "DataNotLoaded"
	end
	if OwnsAbility(player, abilityName) then
		return false, "AlreadyOwned"
	end
	if ((price.IsRobux ~= true or RobuxShopConfig.CheckoutMode ~= "Simple") and PlayerData.Get(player, "ManagedCheckoutPending") == true)
		or (price.IsRobux == true and PlayerData.Get(player, "SimpleCheckoutPending") == true) then
		return false, "PurchasePending"
	end
	if os.clock() < (NextRequest[player] or 0) then
		return false, "RateLimited"
	end
	NextRequest[player] = os.clock() + 0.5
	if price.IsRobux == true then
		if value <= 0 then
			return false, "Unavailable"
		end
		local success, reason = Checkout.RequestSelf(player, value)
		return success, if success then "PromptOpen" else reason
	end

	local coins = PlayerData.Get(player, "Coins")
	if type(coins) ~= "number" or coins ~= coins or math.abs(coins) >= math.huge then
		return false, "DataNotLoaded"
	end
	if coins < value then
		return false, "NotEnoughCoins"
	end
	-- No yields between eligibility checks, deduction and grant. Both attributes save in the same profile.
	PlayerData.Set(player, "Coins", coins - value)
	ApplyAbility(player, { Ability = abilityName }, true)
	AnalyticsService.RecordEconomy(player, {
		Flow = Enum.AnalyticsEconomyFlowType.Sink, Resource = "Coins",
		Amount = value, Balance = coins - value, TransactionType = "Shop",
		ItemSku = abilityName, Activity = "AbilityPurchase",
	})
	Receipts.Dirty(player)
	return true, "Purchased"
end

function Service:Setup()
	Receipts.Register("Ability", { Apply = GrantAbility })
	Registry.RegisterReward("Ability", GrantAbility)
	local products: { [number]: string } = {}
	for abilityName, config in pairs(AbilityConfig.Abilities) do
		local price = config.Price
		if price and price.IsRobux == true and price.Price > 0 then
			assert(not products[price.Price], "Duplicate ability product ID")
			products[price.Price] = abilityName
		end
	end
	Receipts.Products("Ability", products, PurchaseService.Register, function(productId: number, abilityName: string)
		Registry.Register(productId, {
			Kind = "Ability",
			Identity = abilityName,
			GiftAllowed = false,
			Grant = GrantAbility,
			RecoveryReward = function(player: Player)
				local current = AbilityConfig.Abilities[abilityName]
				if not current or current.Unlisted or not current.Price or not current.Price.IsRobux
					or current.Price.Price ~= productId then return nil, "Unavailable" end
			if type(PlayerData.Get(player, OWNED_ABILITY_ATTRIBUTE)) ~= "string" then
				return nil, "DataNotLoaded"
			end
				if OwnsAbility(player, abilityName) then return nil, "AlreadyOwned" end
				return { Ability = abilityName }, nil
			end,
			Snapshot = function(buyer: Player, recipient: Player): (PurchaseTypes.Reward?, string?)
				local config = AbilityConfig.Abilities[abilityName]
				local price = config and config.Price
				if not config or config.Unlisted or not price or price.IsRobux ~= true or price.Price ~= productId then
					return nil, "Unavailable"
				end
				if
					not Runtime.Ready(recipient)
					or type(PlayerData.Get(recipient, OWNED_ABILITY_ATTRIBUTE)) ~= "string"
				then
					return nil, "DataNotLoaded"
				end
				if OwnsAbility(recipient, abilityName) then
					return nil, "AlreadyOwned"
				end
				return { Ability = abilityName }, nil
			end,
			Reservation = function(recipient: Player)
				return {
					Key = "Ability:" .. abilityName,
					Limit = 1,
					Used = if OwnsAbility(recipient, abilityName) then 1 else 0,
				}
			end,
		})
		return function(player: Player, receipt: PurchaseTypes.Receipt): boolean
			return Checkout.TryProcess(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted
		end
	end)

	local remote = Events:FindFirstChild("PurchaseAbilityFunction")
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = "PurchaseAbilityFunction"
		remote.Parent = Events
	end
	assert(remote:IsA("RemoteFunction"), "PurchaseAbilityFunction must be a RemoteFunction")
	PurchaseRemote = remote
end

function Service:Start()
	local remote = assert(PurchaseRemote)
	remote.OnServerInvoke = Service.RequestPurchase
	EquipAbilityEvent.OnServerEvent:Connect(function(player: Player, abilityName: unknown)
		if
			Runtime.Ready(player)
			and type(abilityName) == "string"
			and AbilityConfig.Abilities[abilityName]
			and OwnsAbility(player, abilityName)
		then
			PlayerData.Set(player, EQUIPPED_ABILITY_ATTRIBUTE, abilityName)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		NextRequest[player] = nil
	end)
end

function Service.Init()
	if Initialized then
		return
	end
	Service:Setup()
	Service:Start()
	Initialized = true
end

return Service
