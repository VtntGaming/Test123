--!strict
-- Presents the Robux shop and routes purchases with immediate checkout feedback.
--[[
    Notes:
    Use this command to scale up the image for the background:
    ```lua
    for _, item in ipairs(game.StarterGui.MainGui.RobuxShopFrame:GetDescendants()) do
        if item:IsA("ImageLabel") and item.Name == "Background" then
            local absSize = item.AbsoluteSize
            local ratio = absSize.X / absSize.Y
            scaleY = item.TileSize.Y.Scale
            
            local scaleX = scaleY / ratio
            item.TileSize = UDim2.fromScale(scaleX, scaleY)
        end
    end
    ```

    Use this command to set all of the price to default
    ```lua
    for _, item in ipairs(game.StarterGui.MainGui.RobuxShopFrame:GetDescendants()) do
        if item:IsA("TextLabel") and item.Name == "Price" and item.Parent.Name == "BuyButton" then
            item.Text = `\u{e002} -`
        end
    end
    ```
]]

--// Services
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local CheckoutButton = require(script.CheckoutButton)
local CoinItem = require(script.Components.CoinItem)
local GamepassItem = require(script.Components.GamepassItem)
local GroupRewards = require(script.Components.GroupRewards)
local KaidoEventItem = require(script.Components.KaidoEventItem)
local LimitedEventItem = require(script.Components.LimitedEventItem)
local LuckyChestItem = require(script.Components.LuckyChestItem)
local Notification = require(ReplicatedStorage.Utils.NotificationUtil)
local RedeemCode = require(script.Components.RedeemCode)
local StarterPackItem = require(script.Components.StarterPackItem)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local UIInteractionController = require(script.Parent.UIInteractionController)
local GiftController = require(script.Parent.GiftController)
local WeaponItem = require(script.Components.WeaponItem)
local ShopEffectController = require(script.Parent.ShopEffectController)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local HUD = MainGui:WaitForChild("HUD")
local ShopButton = HUD.LeftButtons.ShopButton
local ShopFrame = MainGui:WaitForChild("RobuxShopFrame")
local Listing = ShopFrame.CanvasGroup.Listing
local Events = ReplicatedStorage.Events
local CheckoutRemote = Events.ShopCheckoutEvent
local WeaponPackRemote = Events.WeaponPackEvent
local WeaponPackFeedbackRemote = Events:WaitForChild("WeaponPackFeedbackEvent") :: RemoteEvent
local StarterPurchaseRemote = Events:WaitForChild("StarterPackPurchaseEvent") :: RemoteEvent
local StarterFeedbackRemote = Events:WaitForChild("StarterPackFeedbackEvent") :: RemoteEvent
local PassPurchaseRemote = Events:WaitForChild("PassPurchaseEvent") :: RemoteEvent
local PassFeedbackRemote = Events:WaitForChild("PassPurchaseFeedbackEvent") :: RemoteEvent
local ShopOpenSound = SoundService.SFX.ShopOpen

--// Constants
local ROBUX_SYMBOL = "\u{e002}"
local WEAPON_REFRESH_TIME_ATTRIBUTE = "WeaponPacksNextRefreshTime"
local MESSAGE_REASON = {
    ["Unavailable"] = "Something wrong happened!",
    ["AlreadyClaimed"] = "You already purchased this item!",
    ["AlreadyOwned"] = "You already own this pass.",
    ["DataNotLoaded"] = "Your data is still loading. Please try again shortly.",
    ["OwnershipUnavailable"] = "Pass ownership could not be checked. Please try again shortly.",
    ["Superseded"] = "Pass ownership is updating. Please try again shortly.",
    ["PromptFailed"] = "The purchase prompt could not open. Please try again.",
    ["RateLimited"] = "You are buying too fast!",
    ["TimedOut"] = "The purchase is timed out, try again later...",
    ["PurchasePending"] = "Finish your current checkout first.",
    ["OfferExpired"] = "This offer changed. Please select it again.",
    ["RecipientLimitReached"] = "This offer's allowance is already claimed or reserved.",
    ["SoldOut"] = "This offer's allowance is already claimed or reserved.",
}

--// Types
type PurchaseContext = {
	RotationKey: string?,
	ClientRequestId: string?,
}

type VisibleObject = {
	Start: (self: any) -> (),
	Category: string,
	Frame: Instance,
	SetVisible: (self: any, visible: boolean, awaitTime: number?) -> (),
}

type WeaponPackSnapshot = {
	Offers: { [number]: { ProductId: number }? }?,
	RotationKey: string?,
}

export type RobuxShopController = {
    -- Properties
    IsInit: boolean?,
    IsEnabled: boolean,
    VisibleObjects: {VisibleObject},
    GamepassItems: {GamepassItem.GamepassItem},
    LuckyChestItems: {LuckyChestItem.LuckyChestItem},
    WeaponItems: {WeaponItem.WeaponItem},
    CoinItems: {CoinItem.CoinItem},
    BottomObjects: {VisibleObject},
    LastAnimateObjs: {[VisibleObject]: number},
    Init: () -> (),
    Setup: (self: RobuxShopController) -> (),
    Start: (self: RobuxShopController) -> (),
    ToggleEnabled: (self: RobuxShopController, enabled: boolean?) -> (),
    CheckScrolling: (self: RobuxShopController) -> (),
    CheckWeaponRestock: (self: RobuxShopController) -> (),
}

--// Controller
local Controller = {} :: RobuxShopController

--// APIs
local function SelectedPurchase(item: VisibleObject, gifting: boolean): (number?, PurchaseContext?)
	if item == LimitedEventItem or item == KaidoEventItem then -- KAIDO SPECIAL
		local ID = ReplicatedValues.GetNumber(ReplicatedStorage, "LimitedItemProductId")
		for _, entry in ipairs(RobuxShopConfig.LimitedItem.List) do
			if entry.ID == ID then
				local rotationKey = ReplicatedValues.GetString(ReplicatedStorage, "LimitedItemRotationKey")
				return entry.ID, {
					RotationKey = if type(rotationKey) == "string" then rotationKey else nil,
				}
			end
		end
	elseif item.Category == "Weapons" then
		local weaponItem = item :: WeaponItem.WeaponItem
		local encoded = ReplicatedValues.GetString(ReplicatedStorage, "WeaponPacks")
		if type(encoded) ~= "string" then
			return nil, nil
		end

		local success, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
		if not success or type(decoded) ~= "table" then
			return nil, nil
		end

		local snapshot = decoded :: WeaponPackSnapshot
		local slotIndex = weaponItem.SlotIndex
		local offer = snapshot.Offers and slotIndex and snapshot.Offers[slotIndex]
		if offer then
			return offer.ProductId, { RotationKey = snapshot.RotationKey }
		end
	elseif item.Category == "LuckyChests" then
		local chestItem = item :: LuckyChestItem.LuckyChestItem
		local pack = RobuxShopConfig.LuckyChestPacks[chestItem.ChestName]
		if pack then
			return pack.ID, {}
		end
	elseif item.Category == "Coins" then
		local coinItem = item :: CoinItem.CoinItem
		local pack = RobuxShopConfig.CoinPacks[coinItem.PackName]
		if pack then
			return pack.ID, {}
		end
	elseif item.Category == "Passes" then
		local gamepassItem = item :: GamepassItem.GamepassItem
		local pass = RobuxShopConfig.Passes[gamepassItem.GamepassName]
		if pass then
			return (if gifting then pass.GiftID or 0 else pass.ID), {}
		end
	end
	return nil, nil
end

-- Mirrors the server's lifetime entitlements and current-rotation claim allowances.
local function ClaimState(item: VisibleObject): (boolean, boolean)
	local ready = PlayerData.Get(LocalPlayer, "DataLoaded") == true
	if item.Category == "Passes" then
		local passItem = item :: GamepassItem.GamepassItem
		local pass = RobuxShopConfig.Passes[passItem.GamepassName]
		return ready and PlayerData.Get(LocalPlayer, "GamepassesLoaded") == true,
			PlayerData.Get(LocalPlayer, pass.Attribute or "Has" .. passItem.GamepassName) == true
	elseif item == StarterPackItem or item == LimitedEventItem or item == KaidoEventItem then
		local claims = PlayerData.Get(LocalPlayer, "OneTimePacks")
		local key = if item == StarterPackItem then "StarterLegendaryPack"
			else ReplicatedValues.GetString(ReplicatedStorage, "LimitedItemRotationKey")
		if type(claims) ~= "string" or type(key) ~= "string" or key == "" then
			return false, false
		end
		return ready, table.find(string.split(claims, ","), key) ~= nil
	elseif item.Category == "Weapons" then
		local encoded = PlayerData.Get(LocalPlayer, "WeaponPacks")
		local _, context = SelectedPurchase(item, false)
		if type(encoded) ~= "string" or not context then
			return false, false
		end
		local ok, state = pcall(HttpService.JSONDecode, HttpService, encoded)
		if not ok or type(state) ~= "table" or state.RotationKey ~= context.RotationKey
			or type(state.Offers) ~= "table" then
			return false, false
		end
		local weaponItem = item :: WeaponItem.WeaponItem
		for _, offer in state.Offers do
			if type(offer) == "table" and offer.Index == weaponItem.SlotIndex and type(offer.Remaining) == "number" then
				return ready, offer.Remaining <= 0
			end
		end
		return false, false
	end
	return ready, false
end

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

local function FormatTime(t: number): string
	local seconds = t % 60
	local minutes = math.floor(t / 60) % 60
	local hours = math.floor(t / 3600) % 24

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, seconds)
	else
		return string.format("%d:%02d", minutes, seconds)
	end
end

function Controller:Setup()
    LimitedEventItem:Setup()
    KaidoEventItem:Setup()
    StarterPackItem:Setup()
    GroupRewards:Setup()
    RedeemCode:Setup()

    local gamepassFrame = Listing.Passes
    self.GamepassItems = {
        GamepassItem.new(gamepassFrame.VIP, "VIP"),
		GamepassItem.new(gamepassFrame.SubItems.InstantChest, "InstantChest"),
		GamepassItem.new(gamepassFrame.SubItems.x2Coins, "x2Coins")
    }

    local luckyChestFrame = Listing.LuckyChests
    self.LuckyChestItems = {
        LuckyChestItem.new(luckyChestFrame.List1.Chest1, 1, "Fire"),
        LuckyChestItem.new(luckyChestFrame.List1.Chest2, 2, "Lightning"),
        LuckyChestItem.new(luckyChestFrame.List2.Chest3, 3, "Ice"),
        LuckyChestItem.new(luckyChestFrame.List2.Chest4, 4, "Rainbow"),
    }

    local weaponFrame = Listing.Weapons

    self.WeaponItems = {
        WeaponItem.new(weaponFrame.Items.SubItems.Item1, 1),
        WeaponItem.new(weaponFrame.Items.SubItems.Item2, 2),
        WeaponItem.new(weaponFrame.Items.SubItems.Item3, 3),
        WeaponItem.new(weaponFrame.Items.SubItems.Item4, 4),
        WeaponItem.new(weaponFrame.Items.SpecialItem, 5),
    }

    do -- I'm lazy
        local coinFrame = Listing.Coins
        local coinList = {} :: {string}
        for name,data in pairs(RobuxShopConfig.CoinPacks) do
            coinList[data.Order] = name
        end
        self.CoinItems = {}
        for i,name in ipairs(coinList) do
            local item
            if i < #coinList then
                item = CoinItem.new(coinFrame.Items.SubItems:FindFirstChild("Item"..i), i, name)
            else
                item = CoinItem.new(coinFrame.Items.SpecialItem, i, name)
            end
            table.insert(self.CoinItems,item)
        end

        -- self.CoinItems = {
        --     CoinItem.new(coinFrame.Items.SubItems.Item1, 1, "100"),
        --     CoinItem.new(coinFrame.Items.SubItems.Item2, 2, "1_000"),
        --     CoinItem.new(coinFrame.Items.SubItems.Item3, 3, "10_000"),
        --     CoinItem.new(coinFrame.Items.SubItems.Item4, 4, "100_000"),
        --     CoinItem.new(coinFrame.Items.SubItems.Item5, 5, "250_000"),
        --     CoinItem.new(coinFrame.Items.SubItems.Item6, 6, "500_000"),
        --     CoinItem.new(coinFrame.Items.SpecialItem, 7, "1_000_000"),
        -- }
    end

    self.VisibleObjects = {
        KaidoEventItem,
        LimitedEventItem,
        StarterPackItem,
    }

    for _, item in ipairs(self.GamepassItems) do
        table.insert(self.VisibleObjects, item)
    end
    
    for _, item in ipairs(self.LuckyChestItems) do
        table.insert(self.VisibleObjects, item)
    end

    for _, item in ipairs(self.WeaponItems) do
        table.insert(self.VisibleObjects, item)
    end

    for _, item in ipairs(self.CoinItems) do
        table.insert(self.VisibleObjects, item)
    end

    table.insert(self.VisibleObjects, GroupRewards)
    table.insert(self.VisibleObjects, RedeemCode)

    self.IsEnabled = false
    self.BottomObjects = {}
    self.LastAnimateObjs = {}
end

function Controller:Start()
	local refreshDirectButtons: { () -> () } = {}
	local function directFeedback(status: string, requestId: string?)
		if requestId then
			CheckoutButton.Finish(requestId)
		end
		for _, refresh in ipairs(refreshDirectButtons) do
			refresh()
		end
		if status == "Purchased" then
			ShopEffectController:ShowEffect()
		elseif status == "Cancelled" then
			Notification.Show("Info", "Purchase cancelled.")
		elseif status == "SavePending" then
			Notification.Show("Info", "Your purchase is being saved. Please wait.")
		elseif status ~= "PromptOpen" and status ~= "Owned" and status ~= "NotOwned" then
			Notification.Show("Warning", MESSAGE_REASON[status] or ("Purchase unavailable: " .. status))
		end
	end
	
	StarterFeedbackRemote.OnClientEvent:Connect(directFeedback)
	PassFeedbackRemote.OnClientEvent:Connect(function(status: string, passName: string, requestId: string?)
		directFeedback(status, requestId)
	end)
	WeaponPackFeedbackRemote.OnClientEvent:Connect(function(status: string)
		if status == "Claimed" then
			ShopEffectController:ShowEffect("Claim successful!", "Your free weapon pack has been added to your inventory.")
		elseif status == "SavePending" then
			Notification.Show("Info", "Your weapon pack claim is being saved. Please wait.")
		elseif status == "Busy" then
			Notification.Show("Info", "Your weapon pack claim is still processing. Please wait.")
		elseif status ~= "PromptOpen" then
			Notification.Show("Warning", MESSAGE_REASON[status] or "This weapon pack could not be claimed. Please try again.")
		end
	end)
	local resumeButton = Instance.new("TextButton")
	resumeButton.Name = "ResumeCheckoutButton"
	resumeButton.AnchorPoint = Vector2.new(0.5, 1)
	resumeButton.Position = UDim2.fromScale(0.5, 0.98)
	resumeButton.Size = UDim2.new(0.9, 0, 0, 52)
	resumeButton.BackgroundColor3 = Color3.fromRGB(32, 58, 78)
	resumeButton.TextColor3 = Color3.new(1, 1, 1)
	resumeButton.Font = Enum.Font.GothamBold
	resumeButton.TextSize = 14
	resumeButton.TextWrapped = true
	resumeButton.ZIndex = 100
	resumeButton.Parent = ShopFrame
	local function refreshRecovery()
		resumeButton.Visible = PlayerData.Get(LocalPlayer, "CheckoutResumeAvailable") == true
		local description = tostring(PlayerData.Get(LocalPlayer, "PendingCheckoutDescription") or "purchase")
		local recipientId = PlayerData.Get(LocalPlayer, "PendingCheckoutRecipientId")
		local recipient = if type(recipientId) == "number" then Players:GetPlayerByUserId(recipientId) else nil
		local target = if recipientId == LocalPlayer.UserId then "yourself" elseif recipient then recipient.DisplayName else tostring(recipientId)
		resumeButton.Text = `Resume unfinished checkout: {description} for {target}\nOnly retry if you have not paid; cancel inside the Roblox prompt to close it`
	end
	for _, attribute in ipairs({ "CheckoutResumeAvailable", "PendingCheckoutDescription", "PendingCheckoutRecipientId" }) do
		PlayerData.Observe(LocalPlayer, attribute, refreshRecovery)
	end
	resumeButton.Activated:Connect(function()
		if resumeButton.Visible then CheckoutRemote:FireServer("ResumePending") end
	end)
	refreshRecovery()
	local checkoutStatuses = {}
    CheckoutRemote.OnClientEvent:Connect(function(result)
        if type(result) ~= "table" then return end
		if type(result.ClientRequestId) == "string" then
			CheckoutButton.Finish(result.ClientRequestId)
		end
		local token = result.RequestId or result.ClientRequestId
		if token and checkoutStatuses[token] == result.Status then return end
		if token then checkoutStatuses[token] = result.Status end
        if result.Status == "Purchased" then
            -- Notification.Show("Success", "Purchase delivered!")
            ShopEffectController:ShowEffect()
		elseif result.Status == "ReplacementDelivered" then
			local details = result.Details
			local text = if type(details) == "table" and details.Kind == "CheckoutCompensation"
				then "Purchase recovery added " .. tostring(details.Amount) .. " coins to your account."
				else "Your original purchase selection could not be recovered. Its current product was delivered to you instead."
			Notification.Show("Info", text)
		elseif result.Status == "SavePending" then
			Notification.Show("Info", "Your purchase is pending recovery. Please wait; do not buy it again.")
		elseif result.Status == "Cancelled" then Notification.Show("Info", "Purchase cancelled.")
		elseif result.Status ~= "PromptOpen" and result.Status ~= "CheckoutReleased" then
            local text = MESSAGE_REASON[result.Status] or ("Purchase unavailable: " .. tostring(result.Status))
            Notification.Show("Warning", text)
        end
    end)

    ShopButton.Activated:Connect(function()
        self:ToggleEnabled()
    end)

    local exitButton = ShopFrame.ExitButton

    exitButton.Activated:Connect(function()
        self:ToggleEnabled(false)
    end)

	for _, button in ipairs(ShopFrame.Tabs:GetChildren()) do
		if button:IsA("GuiButton") then
			local tabName = button.Name
			local refObj = Listing:FindFirstChild(tabName)

			if not refObj or not refObj:IsA("GuiObject") then
				warn(`Not found referenced frame for tab {tabName}`)
				continue
			end

			button.Activated:Connect(function()
				local listingAbsPos = Listing.AbsolutePosition
				local objPos = refObj.AbsolutePosition
				local offset = objPos - listingAbsPos
				local canvasPos = Listing.CanvasPosition + Vector2.new(0, offset.Y)

				TweenService:Create(
					Listing,
					TweenInfo.new(0.5, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
					{ CanvasPosition = canvasPos }
				):Play()
			end)
		end
	end

    for _, item in ipairs(self.VisibleObjects) do
        xpcall(function(...) 
            item:Start() 
        end,function(err) 
            warn(err)
        end)    

        if item.Category ~= "SocialRewards" then
            local frame = item.Frame
            
            local buyButton = frame:FindFirstChild("BuyButton", true) :: GuiButton?
            local giftButton = frame:FindFirstChild("GiftButton", true) :: GuiButton?
			if giftButton then giftButton.Visible = false end
            local priceLabel = buyButton and buyButton:FindFirstChild("Price", true) :: TextLabel?
            local previousPriceLabel = buyButton and buyButton:FindFirstChild("PreviousPrice", true) :: TextLabel?

            if not buyButton or not priceLabel then
                continue
            end

            local claimLimited = item == StarterPackItem or item == LimitedEventItem or item == KaidoEventItem
                or item.Category == "Passes" or item.Category == "Weapons"
            local function refreshClaimButton()
                if claimLimited then
                    local ready, claimed = ClaimState(item)
                    CheckoutButton.SetState(buyButton, ready and not claimed, claimed, item.Category)
                end
            end
            if claimLimited then
                table.insert(refreshDirectButtons, refreshClaimButton)
                for _, attribute in { "DataLoaded", "OneTimePacks", "GamepassesLoaded", "WeaponPacks" } do
					PlayerData.Observe(LocalPlayer, attribute, refreshClaimButton)
                end
                for _, attribute in { "WeaponPacks", "LimitedItemRotationKey" } do
					ReplicatedValues.GetChangedSignal(ReplicatedStorage, attribute):Connect(refreshClaimButton)
                end
                if item.Category == "Passes" then
                    local passItem = item :: GamepassItem.GamepassItem
                    local pass = RobuxShopConfig.Passes[passItem.GamepassName]
					PlayerData.Observe(
						LocalPlayer,
						pass.Attribute or "Has" .. passItem.GamepassName,
						refreshClaimButton
					)
                end
                refreshClaimButton()
            end

            local productId = 0
            local giftProductId = 0
            local infoType = Enum.InfoType.Product

            if item.Category == "Exclusive" then
                if item == LimitedEventItem then
					local itemName = ReplicatedValues.GetString(ReplicatedStorage, "LimitedItemName")

                    if type(itemName) ~= "string" then
                        continue
                    end

                    local data

                    for _, itemInfo in RobuxShopConfig.LimitedItem.List do
                        if itemInfo.Item == itemName then
                            data = itemInfo
                            break
                        end
                    end

                    if not data then
                        continue
                    end
                    
					local eventItem = LimitedEventItem :: LimitedEventItem.LimitedEventItem
					eventItem:SetItem(data.Item)
                    productId = data.ID
                    giftProductId = data.ID
                elseif item == KaidoEventItem then
                    local id = RobuxShopConfig.LimitedItem.List[1].ID
                    productId = id
                    giftProductId = id
                elseif item == StarterPackItem then
                    productId = RobuxShopConfig.StarterLegendaryPack.ID
                end
            elseif item.Category == "Passes" then
                infoType = Enum.InfoType.GamePass
				local gamepassItem = item :: GamepassItem.GamepassItem
				local data = RobuxShopConfig.Passes[gamepassItem.GamepassName]

                if data then
                    productId = data.ID or 0
                    giftProductId = data.GiftID or 0
                end
            elseif item.Category == "LuckyChests" then
				local chestItem = item :: LuckyChestItem.LuckyChestItem
				local data = RobuxShopConfig.LuckyChestPacks[chestItem.ChestName]

                if data then
                    productId = data.ID or 0
                end
            elseif item.Category == "Weapons" then
				local weaponItem = item :: WeaponItem.WeaponItem
				local data = RobuxShopConfig.WeaponPacks.List[weaponItem.SlotIndex]

                if data then
                    productId = data.ID or 0
                end
            elseif item.Category == "Coins" then
				local coinItem = item :: CoinItem.CoinItem
				local data = RobuxShopConfig.CoinPacks[coinItem.PackName]

                if data then
                    productId = data.ID or 0
                end
            end

            if not productId or productId == 0 then
                continue
            elseif productId == -1 then
                priceLabel.Text = "FREE"
                if giftButton then giftButton.Visible = false end
                if item.Category == "Weapons" then
                    buyButton.Activated:Connect(function()
                        refreshClaimButton()
                        if not buyButton.Interactable then return end
                        local selectedId, context = SelectedPurchase(item, false)
						local weaponItem = item :: WeaponItem.WeaponItem
						local slotIndex = weaponItem.SlotIndex
                        if selectedId == -1 and context and slotIndex then
                            WeaponPackRemote:FireServer(slotIndex, context.RotationKey)
                        end
                    end)
                end
                continue
            end

            local managed = item == LimitedEventItem or item == KaidoEventItem or item.Category == "LuckyChests"
                or item.Category == "Weapons" or item.Category == "Coins"
			local direct = item == StarterPackItem or item.Category == "Passes"
			local displayedPrice = priceLabel.Text
			local function refreshDirectButton()
				if not direct then
					return
				end
				local owned = false
				local ready = PlayerData.Get(LocalPlayer, "DataLoaded") == true
				if item == StarterPackItem then
					local claims = PlayerData.Get(LocalPlayer, "OneTimePacks")
					ready = ready and type(claims) == "string"
					owned = type(claims) == "string"
						and table.find(string.split(claims, ","), "StarterLegendaryPack") ~= nil
				else
					local passItem = item :: GamepassItem.GamepassItem
					local pass = RobuxShopConfig.Passes[passItem.GamepassName]
					owned = PlayerData.Get(LocalPlayer, pass.Attribute or "Has" .. passItem.GamepassName) == true
					ready = ready and PlayerData.Get(LocalPlayer, "GamepassesLoaded") == true
				end
				CheckoutButton.SetState(buyButton, ready and not owned, owned, item.Category)
				CheckoutButton.SetPrice(priceLabel, if owned then "OWNED" elseif not ready then "LOADING..." else displayedPrice)
			end
			if direct then
				table.insert(refreshDirectButtons, refreshDirectButton)
				for _, attribute in ipairs({ "DataLoaded", "OneTimePacks", "GamepassesLoaded" }) do
					PlayerData.Observe(LocalPlayer, attribute, refreshDirectButton)
				end
				if item.Category == "Passes" then
					local passItem = item :: GamepassItem.GamepassItem
					local pass = RobuxShopConfig.Passes[passItem.GamepassName]
					PlayerData.Observe(
						LocalPlayer,
						pass.Attribute or "Has" .. passItem.GamepassName,
						refreshDirectButton
					)
				end
				refreshDirectButton()
			end
            buyButton.Activated:Connect(function()
                refreshClaimButton()
                if claimLimited and not buyButton.Interactable then return end
				if direct then
					refreshDirectButton()
					if not buyButton.Interactable then return end
					if (PlayerData.Get(LocalPlayer, "SimpleCheckoutPending") == true or (RobuxShopConfig.CheckoutMode ~= "Simple" and PlayerData.Get(LocalPlayer, "ManagedCheckoutPending") == true)) then
						Notification.Show("Warning", MESSAGE_REASON.PurchasePending)
						return
					end
					local requestId = HttpService:GenerateGUID(false)
					if not CheckoutButton.Begin(buyButton, priceLabel, requestId, function()
						refreshDirectButton()
						Notification.Show("Warning", "The server has not responded yet. Please wait before trying again.")
					end) then return end
					if item == StarterPackItem then
						StarterPurchaseRemote:FireServer(requestId)
					else
						local passItem = item :: GamepassItem.GamepassItem
						PassPurchaseRemote:FireServer(passItem.GamepassName, requestId)
					end
                elseif managed then
                    local selectedId, context = SelectedPurchase(item, false)
                    if selectedId and selectedId > 0 and context then
						if (PlayerData.Get(LocalPlayer, "SimpleCheckoutPending") == true or (RobuxShopConfig.CheckoutMode ~= "Simple" and PlayerData.Get(LocalPlayer, "ManagedCheckoutPending") == true)) then
							Notification.Show("Warning", "Finish your current checkout first.")
							return
						end
						local requestId = HttpService:GenerateGUID(false)
                        context.ClientRequestId = requestId
						if not CheckoutButton.Begin(buyButton, priceLabel, requestId, function()
							Notification.Show("Info", "Checkout is taking longer than expected. Check for an unfinished checkout before trying again.")
						end) then
							return
						end
                        CheckoutRemote:FireServer(selectedId, context)
                    else Notification.Show("Warning", "This offer changed or is unavailable.") end
                end
            end)

            if giftButton then
                giftButton.Visible = managed or (item.Category == "Passes" and giftProductId > 0)
                if giftButton.Visible then
                    giftButton.Activated:Connect(function()
                        local selectedId, context = SelectedPurchase(item, true)
                        if selectedId and selectedId > 0 and context then GiftController:Open(selectedId, context)
                        else Notification.Show("Warning", "Gifting is unavailable for this offer.") end
                    end)
                end
            end

            task.spawn(function()
                local info = MarketplaceService:GetProductInfoAsync(productId, infoType)
                local priceInRobux = tonumber(info and info.PriceInRobux)
    
                if not priceInRobux then
                    return
                end
    
				displayedPrice = `{ROBUX_SYMBOL} {FormatNumber(priceInRobux)}`
                CheckoutButton.SetPrice(priceLabel, displayedPrice)
				refreshDirectButton()

                if previousPriceLabel then
                    local previousPrice = math.ceil(priceInRobux * 1.25)
                    local remainder = previousPrice % 100

                    if remainder <= 49 then
                        previousPrice += 49 - remainder
                    else
                        previousPrice += 99 - remainder
                    end

                    previousPriceLabel.Text = `{ROBUX_SYMBOL} {FormatNumber(previousPrice)}`
                end
            end)
        end
    end

    Listing:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        self:CheckScrolling()
    end)
    
    Listing:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
        self:CheckScrolling()
    end)

    task.spawn(function()
        while task.wait(1) do
            self:CheckWeaponRestock()
        end
    end)

    self:CheckScrolling()
end

function Controller:CheckWeaponRestock()
	local weaponRestockTime = tonumber(ReplicatedValues.GetNumber(ReplicatedStorage, WEAPON_REFRESH_TIME_ATTRIBUTE))
		or 0

    local timeLeft = math.max(weaponRestockTime - os.time(), 0)
    local restockLabel = Listing.Weapons.Title.Restock
    local timeDisplay = `NEXT RESTOCK - {FormatTime(timeLeft)}`

    restockLabel.Text = timeDisplay
    restockLabel.Title.Text = timeDisplay
end

function Controller:CheckScrolling()
    local absPos = Listing.AbsolutePosition
    local windowSize = Listing.AbsoluteWindowSize

    local minPos = absPos.Y
    local invisiblePos = minPos + windowSize.Y
    local maxPos = minPos + windowSize.Y * 1.0

    local visibleObjs = self.VisibleObjects
    local bottomObjs = self.BottomObjects

    for order, item in ipairs(visibleObjs) do
        if item == LimitedEventItem or item == StarterPackItem then
            continue    -- These two are already animated
        end

		local frame = item.Frame :: GuiObject
        local objPos = frame.AbsolutePosition.Y
        
        if objPos > invisiblePos then
            if not table.find(bottomObjs, item) then
                table.insert(bottomObjs, item)
            end
            item:SetVisible(false)
            local scale = frame:FindFirstChild("UIScale") :: UIScale?
            if scale then
                scale.Scale = 0
            end
        elseif objPos < maxPos then
            local index = table.find(bottomObjs, item)
            if index then
                table.remove(bottomObjs, index)
                local itemLastAnimate = self.LastAnimateObjs[item] or 0
    
                if objPos > minPos and time() - itemLastAnimate > 0 then
                    self.LastAnimateObjs[item] = time()
                    item:SetVisible(true)
                end
            end
        end
    end
end

function Controller:ToggleEnabled(enabled: boolean?)
    if type(enabled) == "boolean" then
        self.IsEnabled = enabled
    else
        self.IsEnabled = not self.IsEnabled
    end

    if self.IsEnabled then
        SoundService:PlayLocalSound(ShopOpenSound)
        if ShopFrame and ShopFrame.Header then
            TweenUtils.PlayTweenSequence({
                TweenService:Create(ShopFrame.Header, TweenInfo.new(0), {
                    Position = UDim2.fromScale(-0.25, -0.107)
                }),
                true,
                TweenService:Create(ShopFrame.Header, TweenInfo.new(1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
                    Position = UDim2.fromScale(-0.049, -0.107)
                }),
            })
        end
    end

    local baseAwait = self.IsEnabled and 0 or 0
    local awaitTime = self.IsEnabled and 0.05 or 0

    UIInteractionController.ToggleFrame(ShopFrame, self.IsEnabled)

    task.spawn(function()
        task.wait(baseAwait)
        for i, item in ipairs(self.VisibleObjects) do
            item:SetVisible(self.IsEnabled, (i - 1) * awaitTime)
        end
    end)
end

function Controller.Init()
    if Controller.IsInit then
        return
    end
    Controller.IsInit = true

    Controller:Setup()
    Controller:Start()
end

return Controller
