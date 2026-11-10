--!strict
-- Registers product capabilities and synchronous grants independently of checkout and delivery workflows.

--// Modules
local PurchaseTypes = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)

--// Properties
local Products: { [number]: PurchaseTypes.Product } = {}
local Rewards: { [string]: PurchaseTypes.Grant } = {}

--// Types
export type ProductRegistry = {
	RegisterReward: (kind: string, grant: PurchaseTypes.Grant) -> (),
	Register: (productId: number, definition: PurchaseTypes.Product) -> (),
	Get: (productId: number) -> PurchaseTypes.Product?,
	GetGrant: (kind: string) -> PurchaseTypes.Grant?,
}

--// Module
local Registry = {} :: ProductRegistry

--// APIs
function Registry.RegisterReward(kind, grant)
	assert(type(kind) == "string" and type(grant) == "function", "Invalid reward handler")
	assert(not Rewards[kind] or Rewards[kind] == grant, "Conflicting reward kind")
	Rewards[kind] = grant
end

function Registry.Register(productId, definition)
	assert(productId > 0 and productId < math.huge and productId % 1 == 0, "Invalid managed product ID")
	local existing = Products[productId]
	assert(
		not existing
			or existing == definition
			or (
				existing.Kind == definition.Kind
				and existing.Grant == definition.Grant
				and existing.Identity == definition.Identity
				and existing.SelfAllowed == definition.SelfAllowed
				and existing.GiftAllowed == definition.GiftAllowed
			),
		"Conflicting managed product: " .. productId
	)
	assert(
		type(definition.Kind) == "string"
			and type(definition.Snapshot) == "function"
			and type(definition.Grant) == "function",
		"Incomplete managed product"
	)
	Registry.RegisterReward(definition.Kind, definition.Grant)
	Products[productId] = definition
end

function Registry.Get(productId)
	return Products[productId]
end

function Registry.GetGrant(kind)
	return Rewards[kind]
end

return Registry
