--!strict
-- Dispatches developer-product receipts and initializes its checkout, gifting and receipt-recovery submodules.

--// Services
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

--// Modules
local PurchaseTypes = require(game:GetService("ServerScriptService").Services.PurchaseService.Types)
local GiftService = require(game.ServerScriptService.Services.PurchaseService.Gifting)
local Checkout = require(game.ServerScriptService.Services.PurchaseService.Checkout)
local Receipts = require(game.ServerScriptService.Services.PurchaseService.Receipts)

--// Properties
local Initialized = false
local Dispatcher: ((PurchaseTypes.Receipt) -> PurchaseTypes.Decision)? = nil
local Handlers: { [number]: (Player, PurchaseTypes.Receipt) -> boolean } = {}
local DirectReceipts: { [number]: boolean } = {}

--// Types
export type PurchaseService = {
	Register: (productId: number, handler: (Player, PurchaseTypes.Receipt) -> boolean, directReceipt: boolean?) -> (),
	Setup: (self: PurchaseService) -> (),
	Start: (self: PurchaseService) -> (),
	Init: () -> (),
}

--// Service
local PurchaseService = {} :: PurchaseService

--// APIs
function PurchaseService.Register(productId, handler, directReceipt)
	if Handlers[productId] then
		assert(Handlers[productId] == handler, "Duplicate developer product ID: " .. productId)
		return
	end
	Handlers[productId] = handler
	DirectReceipts[productId] = directReceipt == true
end

-- No inputs/return. Installs ProcessReceipt; initialize once during server startup.
-- Callback input: Roblox receipt with PlayerId (buyer), ProductId, PurchaseId, etc.
-- Callback output: PurchaseGranted or NotProcessedYet; managed receipts settle through Checkout.
function PurchaseService:Setup()
	Dispatcher = function(receiptInfo)
		-- Direct products use their registered handler in every checkout mode.
		if not DirectReceipts[receiptInfo.ProductId] then
			-- Saved self/gift intent decides the recipient of every managed receipt.
			local checkoutOk, checkoutResult = pcall(Checkout.TryProcess, receiptInfo)
			if not checkoutOk then
				warn("[PurchaseService] Checkout receipt failed: " .. tostring(checkoutResult))
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			if checkoutResult then
				return checkoutResult
			end
		end

		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player or not player:GetAttribute("DataLoaded") then
			return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox retries later
		end

		local handler = Handlers[receiptInfo.ProductId]
		if not handler then
			warn("[ProductService] No handler for product " .. receiptInfo.ProductId)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local ok, result = pcall(handler, player, receiptInfo)
		if not ok then
			warn("[ProductService] Handler error: " .. tostring(result))
		end

		if ok and result ~= false then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

function PurchaseService:Start()
	Receipts.Init()
	Checkout.Init()
	GiftService.Init()
	MarketplaceService.ProcessReceipt = assert(Dispatcher)
end

function PurchaseService.Init()
	if Initialized then
		return
	end
	PurchaseService:Setup()
	PurchaseService:Start()
	Initialized = true
end

return PurchaseService
