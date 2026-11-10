--!strict
-- Defines the saved checkout records and product capabilities shared by PurchaseService submodules.
-- Reward payload fields remain extensible at the persistence boundary; sections validate their own rewards.

--// Types
export type Receipt = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	CurrencySpent: number?,
	CurrencyType: Enum.CurrencyType?,
}
export type Context = { ClientRequestId: string?, RotationKey: string? }
export type Mode = "Self" | "Gift"
export type Reward = { [string]: any }
export type Grant = (Player, Reward) -> ()
export type Reservation = { Key: string, Limit: number, Used: number, Amount: number? }
export type Intent = {
	RequestId: string,
	BuyerId: number,
	RecipientId: number,
	ProductId: number,
	Mode: Mode,
	Reward: Reward,
	Reservation: Reservation?,
	ClientRequestId: string?,
	CreatedAt: number,
	Prompted: boolean,
	PaymentReported: boolean?,
	PurchaseId: string?,
	Complete: boolean?,
	Delivered: boolean?,
	Finalized: boolean?,
	Strategy: ("Fast" | "Simple")?,
	Replacement: boolean?,
	-- Original selections superseded by this receipt's persisted replacement decision.
	Reconciled: { [string]: Intent }?,
}
export type Notification = {
	BuyerId: number,
	Reward: Reward?,
	Strategy: ("Fast" | "Simple")?,
	Mode: Mode,
	RecipientId: number?,
	ProductId: number?,
	ClientRequestId: string?,
	RequestId: string?,
}
export type BuyerRecord = {
	Active: Intent?,
	Receipts: { [string]: Intent }?,
	Cancelled: { [string]: Intent }?,
	Unmatched: { [string]: boolean }?,
	FastPending: { [string]: Intent }?,
	-- Paid selections still route receipts, but do not block another checkout.
	RecoveryPending: { [string]: Intent }?,
	UnmatchedRequests: { [string]: { [string]: Intent } }?,
	-- Terminal request IDs fence delayed background saves from recreating selections.
	FastClosed: { [string]: string }?,
}
export type Inbox = { [string]: Intent }
export type Product = {
	Kind: string,
	SimpleOnly: boolean?,
	Identity: string?,
	SelfAllowed: boolean?,
	GiftAllowed: boolean?,
	Snapshot: (Player, Player, Context, Mode) -> (Reward?, string?),
	Grant: Grant,
	Reservation: ((Player, Reward) -> Reservation)?,
	-- Resolve a paid replacement for the buyer. Must not depend on current purchase allowance.
	RecoveryReward: ((Player) -> (Reward?, string?))?,
	-- Simple capabilities must not schedule saves. Grants must not yield.
	SimpleSnapshot: ((Player, Player, Context, Mode) -> (Reward?, string?))?,
	SimpleGrant: Grant?,
	SimpleRecovery: ((Player) -> (Reward?, string?))?,
	SimplePolicy: ((Player) -> (boolean, string?))?,
}
export type RegisterPurchase = (number, (Player, Receipt) -> boolean) -> ()
export type Decision = Enum.ProductPurchaseDecision
export type Types = {}

--// Module
local Types = {} :: Types
return Types
