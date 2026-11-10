--[[
```lua
local RobuxShopController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local PlayerData = require(ReplicatedStorage.PlayerData)
local UIInteractionController = require(script.Parent:WaitForChild("UIInteractionController"))
local NotificationUtil = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("NotificationUtil"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("ShopConfig"))
local HUDUtil = require(ReplicatedStorage:WaitForChild("Utils"):WaitForChild("HUDUtil"))

-- ==========================================
-- CONFIG
-- ==========================================
local LocalPlayer = Players.LocalPlayer

local PROMPT_COOLDOWN = 0.5
local HOVER_SCALE, HOVER_TIME = 1.1, 0.25

-- Owned check helpers (return true => button is greyed out + disabled)
local function hasAttribute(attribute)
	return function() return PlayerData.Get(LocalPlayer, attribute) == true end
end
	
local function hasInList(attribute, itemName)
	return function()
		local list = PlayerData.Get(LocalPlayer, attribute)
		if type(list) ~= "string" then return false end
		for _, v in ipairs(string.split(list, ",")) do
			if v == itemName then return true end
		end
		return false
	end
end

-- Key = name of the product's frame/button inside ScrollingFrame.
--   Button = name of the button inside that frame (default "RobuxButton")
--   Group  = optional: search the key only inside this child of ScrollingFrame (e.g. "Weapons")
--   Owned  = optional function -> true when already bought (button disabled)
--   WatchAttribute = player attribute that should re-run the Owned check
-- To add a product later: add one entry here + one ProductId in ShopConfig.RobuxShop.DevProduct.
local PRODUCTS = {
	DoubleCoin = {
		ProductId = ShopConfig.RobuxShop.DevProduct.HasX2Coins,
		Owned = hasAttribute("Has2xCoins"),
		WatchAttribute = "Has2xCoins",
		SuccessMessage = "x2 Coins activated!",
	},

	TimeStop = {
		ProductId = ShopConfig.RobuxShop.DevProduct.TimeStop,
		Owned = hasInList("OwnedAbilities", "TimeStop"),
		WatchAttribute = "OwnedAbilities",
		SuccessMessage = "TimeStop ability unlocked!",
	},
	Buy1 = { Button = false, Group = "Weapons", ProductId = ShopConfig.RobuxShop.DevProduct.Gacha1, SuccessMessage = "Opening 1 gacha!" },
	Buy2 = { Button = false, Group = "Weapons", ProductId = ShopConfig.RobuxShop.DevProduct.Gacha2, SuccessMessage = "Opening 3 gachas!" },
	Buy3 = { Button = false, Group = "Weapons", ProductId = ShopConfig.RobuxShop.DevProduct.Gacha3, SuccessMessage = "Opening 10 gachas!" },
	Buy4 = { Button = false, Group = "Weapons", ProductId = ShopConfig.RobuxShop.DevProduct.Gacha4, SuccessMessage = "Opening 50 gachas!" },
}

local ui = {}
local state = { buttons = {}, promptCooldown = false }

-- ==========================================
-- PRODUCTS
-- ==========================================
local function setupBackButtons()
	
end
local function refreshOwned(name)
	local data, button = PRODUCTS[name], state.buttons[name]
	if not (data and button and data.Owned) then return end

	local owned = data.Owned()
	button.Interactable = not owned
	if button:IsA("ImageButton") then
		button.ImageTransparency = owned and 0.5 or 0
	end
end

local function findButton(name, data)
	local root = ui.ScrollingFrame
	if data.Group then
		root = ui.ScrollingFrame:FindFirstChild(data.Group, true)
	end
	if not root then return nil end

	local productFrame = root:FindFirstChild(name, true)
	if not productFrame then return nil end

	-- Button = false -> the frame itself is the button (gacha Buy1..Buy4)
	if data.Button == false then
		return productFrame:IsA("GuiButton") and productFrame or nil
	end
	return productFrame:FindFirstChild(data.Button or "RobuxButton", true)
end

local function setupProducts()
	for name, data in pairs(PRODUCTS) do
		local button = findButton(name, data)
		if not button then
			warn("[RobuxShopController] Missing button for " .. name)
			continue
		end
		if not data.ProductId then
			warn("[RobuxShopController] No ProductId set for " .. name .. " (add it in ShopConfig.RobuxShop.DevProduct)")
			continue
		end

		state.buttons[name] = button
		HUDUtil:HoverButton(button, HOVER_SCALE, HOVER_TIME)

		button.MouseButton1Click:Connect(function()
			if state.promptCooldown or not button.Interactable then return end
			state.promptCooldown = true
			MarketplaceService:PromptProductPurchase(LocalPlayer, data.ProductId)
			task.delay(PROMPT_COOLDOWN, function() state.promptCooldown = false end)
		end)

		if data.Owned then
			if data.WatchAttribute then
				PlayerData.Observe(LocalPlayer, data.WatchAttribute, function() refreshOwned(name) end)
			end
			refreshOwned(name)
		end
	end
end

-- ==========================================
-- TOGGLE
-- ==========================================
function RobuxShopController.Toggle(forceState)
	local isOpening = forceState
	if isOpening == nil then isOpening = not ui.RobuxShopFrame.Visible end
	if isOpening and PlayerData.Get(LocalPlayer, "IsOnArena") then return end
	UIInteractionController.ToggleFrame(ui.RobuxShopFrame, isOpening)
end

-- ==========================================
-- INIT
-- ==========================================
function RobuxShopController.Init()
	local MainGui = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MainGui")
	ui.RobuxShopFrame = MainGui:WaitForChild("RobuxShopFrame")
	ui.ScrollingFrame = ui.RobuxShopFrame:WaitForChild("CanvasGroup"):WaitForChild("ScrollingFrame")
	ui.RobuxShopFrame.Visible = false

	ui.ExitButton = ui.RobuxShopFrame:WaitForChild("ExitButton")
	ui.OpenButton = nil

	ui.ExitButton.MouseButton1Click:Connect(function()
		RobuxShopController.Toggle(false)
	end)

	if ui.OpenButton then
		ui.OpenButton.MouseButton1Click:Connect(function()
			RobuxShopController.Toggle()
		end)
	end

	setupProducts()

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		if userId ~= LocalPlayer.UserId or not isPurchased then return end
		for _, data in pairs(PRODUCTS) do
			if data.ProductId == productId then
				NotificationUtil.Show("Success", data.SuccessMessage or "Purchase successful!")
				break
			end
		end
	end)
end

return RobuxShopController
```
]]
