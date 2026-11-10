--!strict
--!native
--!optimize 2

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

--// Modules
local ForgeItem = require(script.ForgeItem)
local ForgeResult = require(script.ForgeResult)
local ForgeStates = require(script.ForgeStates)
local ThreeSlotsController = require(script.ThreeSlotsController)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local UIInteractionController = require(script.Parent.UIInteractionController)
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ForgeFrame = MainGui:WaitForChild("ForgeFrame")
local InventoryList = ForgeFrame.ScrollHolder.ScrollingFrame
local ItemTemplate = InventoryList.Template
local RatesContainer = ForgeFrame.RaritiesFrame.Rarities
local RateTemplate = RatesContainer.Template
local ForgeButton = ForgeFrame.ForgeButton
local CloseButton = ForgeFrame.ExitButton
local ForgeWeaponFunction = ReplicatedStorage.Events.ForgeWeaponFunction
local EmptyListText = InventoryList.EmptyListText
local ForgeBang = SoundService.SFX.ForgeBang
local ForgeChargingSound = SoundService.SFX.ForgeCharging

--// Constants
local RARITY_ORDER: { string } = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
local TRIGGER_DISTANCE: number = 6

--// Properties
local Items: {[string]: ForgeItem.ForgeItem} = {}

--// Types
type WeaponInfo = {
	BaseName: string,
	Variant: string,
	Rarity: string,
	RarityColor: Color3,
	Icon: string,
	DisplayName: string,
}

export type ForgeController = {
	Init: () -> (),
}

local function GetWeaponInfo(weaponName: string): WeaponInfo
	local weaponInfo = WeaponConfig.GetWeaponInfo(weaponName)
	assert(weaponInfo, `No weapon info exists for "{weaponName}"`)
	return weaponInfo
end

local function ApplyInventoryFilter()
	local baseFilter: string? = nil
	for index = 1, 3 do
		local weaponName: string? = ForgeStates.ActiveSlots[index]
		if weaponName then
			baseFilter = GetWeaponInfo(weaponName).BaseName
			break
		end
	end

	local isEmpty = true
	for weaponName, count in pairs(ForgeStates.InventoryCounts) do
		local inventoryButton: Instance? = InventoryList:FindFirstChild(weaponName)
		if inventoryButton and inventoryButton:IsA("GuiObject") then
			local isMatch: boolean = not baseFilter or GetWeaponInfo(weaponName).BaseName == baseFilter
			local isVisible: boolean = count > 0 and isMatch
			inventoryButton.Visible = isVisible
			if isVisible and isEmpty then
				isEmpty = false
			end
		end
	end

	EmptyListText.Visible = isEmpty
end

local function SetForgeButtonForgeStates(enabled: boolean)
	ForgeStates.CanForge = enabled
end

local function UpdateInventoryCount(weaponName: string, amount: number)
	ForgeStates.InventoryCounts[weaponName] = (ForgeStates.InventoryCounts[weaponName] or 0) + amount

	local inventoryButton: Instance? = InventoryList:FindFirstChild(weaponName)
	local quantityLabel: Instance? = if inventoryButton then inventoryButton:FindFirstChild("QuantityLabel") else nil
	if quantityLabel and quantityLabel:IsA("TextLabel") then
		quantityLabel.Text = "X" .. ForgeStates.InventoryCounts[weaponName]
	end

	ApplyInventoryFilter()
end

local function UpdateForgeRates()
	for rarityName, rateLabel in pairs(ForgeStates.RateLabels) do
		rateLabel.Text = "0% " .. string.upper(rarityName)
		rateLabel.TextTransparency = 0.6
	end
	SetForgeButtonForgeStates(false)

	local validCount: number = 0
	local raritySum: number = 0
	for index = 1, 3 do
		local weaponName: string? = ForgeStates.ActiveSlots[index]
		if weaponName then
			validCount += 1
			local rarityIndex: number? = table.find(RARITY_ORDER, GetWeaponInfo(weaponName).Rarity)
			assert(rarityIndex, `Unknown rarity for "{weaponName}"`)
			raritySum += rarityIndex
		end
	end

	if validCount < 3 then
		return
	end

	local averageRarity: number = raritySum / 3
	local baseRarityIndex: number = math.min(math.floor(averageRarity) + 1, 5)
	local upgradeChance: number = math.floor((averageRarity % 1) * 100)
	--"Common", "Rare", "Epic", "Legendary", "Mythic" 
	local probabilities: {[string]: number} = {
		Common = 0,
		Rare = 0,
		Epic = 0,
		Legendary = 0,
		Mythic = 0
	}

	if baseRarityIndex == 5 then
		probabilities.Mythic = 100
	else
		local baseRarity: string = RARITY_ORDER[baseRarityIndex]
		local upgradedRarity: string = RARITY_ORDER[baseRarityIndex + 1]

		probabilities[baseRarity] = 100 - upgradeChance
		probabilities[upgradedRarity] = upgradeChance
	end

	for rarity, chance in probabilities do		
		local label = ForgeStates.RateLabels[rarity]
		if chance > 0 then
			label.TextTransparency = 0
		else
			label.TextTransparency = 0.6
		end
		
		label.Text = `{tonumber(chance)}% {string.upper(rarity)}`
	end

	SetForgeButtonForgeStates(true)
end

local function PopulateInventory()
	ForgeStates.InventoryCounts = {}

	local ownedWeaponsAttribute: unknown = LocalPlayer:GetAttribute("OwnedWeapons")
	local ownedWeapons: string = if typeof(ownedWeaponsAttribute) == "string"
		then ownedWeaponsAttribute
		else ""
	local rawWeapons: { string } = string.split(ownedWeapons, ",")
	for _, weaponName in ipairs(rawWeapons) do
		if weaponName ~= "" then
			local weaponInfo: WeaponInfo? = WeaponConfig.GetWeaponInfo(weaponName)
			if weaponInfo and weaponInfo.Variant ~= "None" then
				ForgeStates.InventoryCounts[weaponName] = (ForgeStates.InventoryCounts[weaponName] or 0) + 1
			end
		end
	end

	for index = 1, 3 do
		local weaponName: string? = ForgeStates.ActiveSlots[index]
		if weaponName then
			local existing = ForgeStates.InventoryCounts[weaponName]
			if existing then
				ForgeStates.InventoryCounts[weaponName] -= 1
			end
		end
	end

	for weaponName, count in pairs(ForgeStates.InventoryCounts) do
		local item = Items[weaponName] or ForgeItem.new(weaponName)

		item:SetQuantity(count)
		if not Items[weaponName] then
			Items[weaponName] = item
		end
	end

	for itemName, item in pairs(Items) do
		local count = ForgeStates.InventoryCounts[itemName]

		if not count or count <= 0 then
			item:Destroy()
			Items[itemName] = nil
		end
	end

	local arrayItems: {ForgeItem.ForgeItem} = {}

	for _, item in pairs(Items) do
		table.insert(arrayItems, item)
	end

	table.sort(arrayItems, function(item1: ForgeItem.ForgeItem, item2: ForgeItem.ForgeItem)
		local info1 = item1.WeaponInfo
		local info2 = item2.WeaponInfo

		local rarity1 = table.find(RARITY_ORDER, info1.Rarity) or 0
		local rarity2 = table.find(RARITY_ORDER, info2.Rarity) or 0

		if rarity1 ~= rarity2 then
			return rarity1 > rarity2
		end

		local base1 = info1.BaseName
		local base2 = info2.BaseName
		
		if base1 ~= base2 then
			return base1 < base2
		end

		return info1.FullName < info2.FullName
	end)

	for order, item in ipairs(arrayItems) do
		item.Frame.LayoutOrder = order
	end		

	ApplyInventoryFilter()
end

local function ToggleEnabled(forceForgeStates: boolean?)
	local isOpening: boolean = if forceForgeStates == nil then not ForgeFrame.Visible else forceForgeStates

	UIInteractionController.ToggleFrame(ForgeFrame, isOpening)
	GuiService.TouchControlsEnabled = not isOpening
	if isOpening then
		task.spawn(function()
			SoundService:PlayLocalSound(ForgeBang)
			task.wait(0.65)
			SoundService:PlayLocalSound(ForgeBang)
		end)
		PopulateInventory()
	else
		local ghostItem = ForgeStates.GhostItem
		if ghostItem then
			ghostItem:Destroy()
			ForgeStates.DragSource = nil
		end
		ThreeSlotsController:Reset()
		UpdateForgeRates()
	end
end

UserInputService.InputChanged:Connect(function(input: InputObject)
	local ghostItem = ForgeStates.GhostItem
	if not ghostItem
		or (input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch)
	then
		return
	end

	local inputPosition = input.Position

	ghostItem:Move(Vector2.new(inputPosition.X, inputPosition.Y))
end)

--// Controller
local ForgeController = {} :: ForgeController

--// APIs
function ForgeController.Init()
	ItemTemplate.Visible = false

	ForgeItem.UpdateInventoryCount:Connect(UpdateInventoryCount)
	ForgeItem.QuickAssign:Connect(function(weaponName: string)
		ThreeSlotsController:DropIntoAnySlot(weaponName)
	end)
	ThreeSlotsController:Setup()
	ThreeSlotsController:Start()

	ThreeSlotsController.SlotChanged:Connect(function()		
		UpdateForgeRates()
		ApplyInventoryFilter()
		PopulateInventory()
	end)
	
	RateTemplate.Visible = false

	for _, rarityName in ipairs(RARITY_ORDER) do
		local rateLabelInstance: Instance? = RatesContainer:FindFirstChild(rarityName)
		local rateLabel: TextLabel
		if rateLabelInstance then
			assert(rateLabelInstance:IsA("TextLabel"), `Forge rate "{rarityName}" must be a TextLabel`)
			rateLabel = rateLabelInstance
		else
			rateLabel = RateTemplate:Clone()
		end
		rateLabel.Name = rarityName
		rateLabel.Visible = true
		rateLabel.Parent = RatesContainer
		rateLabel.Text = "0% " .. rarityName
		rateLabel.TextColor3 = WeaponConfig.Rarities[rarityName]
		rateLabel.Font = Enum.Font.LuckiestGuy
		ForgeStates.RateLabels[rarityName] = rateLabel
	end

	SetForgeButtonForgeStates(false)

	CloseButton.MouseButton1Click:Connect(function()
		ToggleEnabled(false)
	end)

	ForgeButton.MouseButton1Click:Connect(function()
		if ForgeStates.ThreeSlotStatus.IsAnimating then
			return
		end

		local filledSlotsCount: number = 0
		local requiredBaseType: string? = nil
		for index = 1, 3 do
			local weaponName: string? = ForgeStates.ActiveSlots[index]
			if weaponName then
				filledSlotsCount += 1
				if not requiredBaseType then
					requiredBaseType = GetWeaponInfo(weaponName).BaseName
				end
			end
		end

		if filledSlotsCount == 0 then
			NotificationUtil.Show("Warning", "You are missing 3 weapons to forge!")
			return
		elseif filledSlotsCount < 3 then
			local missingCount: number = 3 - filledSlotsCount
			local pluralSuffix: string = if missingCount > 1 then "s" else ""
			NotificationUtil.Show(
				"Warning",
				"You are missing " .. missingCount .. " " .. (requiredBaseType or "") .. pluralSuffix .. " to forge!"
			)
			return
		end

		local firstWeapon: string? = ForgeStates.ActiveSlots[1]
		local secondWeapon: string? = ForgeStates.ActiveSlots[2]
		local thirdWeapon: string? = ForgeStates.ActiveSlots[3]
		assert(firstWeapon and secondWeapon and thirdWeapon, "All forge slots must be filled")

		local success: boolean, result: string? =
			ForgeWeaponFunction:InvokeServer(firstWeapon, secondWeapon, thirdWeapon)
		if success then
			assert(result, "Forge succeeded without returning the resulting weapon")
			if ForgeStates.ForgeAnimThread then
				task.cancel(ForgeStates.ForgeAnimThread)
			end

			if ForgeStates.ForgeResultThread then
				task.cancel(ForgeStates.ForgeResultThread)
			end

			ForgeStates.ForgeAnimThread = task.spawn(function()
				local increaseTime = 5
				local restoreTime = 1
				local targetScaleSpeed = 100
				local targetRotationSpeed = 1000
				local threeSlotStatus = ForgeStates.ThreeSlotStatus
				ForgeStates.ThreeSlotStatus.IsAnimating = true
				ForgeButton.Visible = false

				local start = time()

				SoundService:PlayLocalSound(ForgeChargingSound)
				while time() - start < increaseTime do
					task.wait()
					local value = (time() - start) / increaseTime
					threeSlotStatus.ScaleSpeed = math.lerp(1, targetScaleSpeed, value)
					threeSlotStatus.RotationSpeed = math.lerp(1, targetRotationSpeed, value)
					threeSlotStatus.ScaleMultiplier = 1 - TweenService:GetValue(value, Enum.EasingStyle.Back, Enum.EasingDirection.In)
				end
				
				ForgeStates.ForgeResultThread = task.spawn(ForgeResult.ShowResult, result)

				threeSlotStatus.ScaleMultiplier = 0

				start = time()
				ThreeSlotsController:Reset()
				PopulateInventory()
				UpdateForgeRates()

				while time() - start < restoreTime do
					task.wait()
					local value = (time() - start) / restoreTime
					threeSlotStatus.ScaleSpeed = math.lerp(targetScaleSpeed, 1, value)
					threeSlotStatus.RotationSpeed = math.lerp(targetRotationSpeed, 1, value)
					threeSlotStatus.ScaleMultiplier = TweenService:GetValue(value, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
				end

				threeSlotStatus.ScaleSpeed = 1
				threeSlotStatus.RotationSpeed = 1
				threeSlotStatus.ScaleMultiplier = 1
				ForgeStates.ThreeSlotStatus.IsAnimating = false
				ForgeButton.Visible = true
			end)
				
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("OwnedWeapons"):Connect(function()
		if ForgeFrame.Visible then
			PopulateInventory()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		ThreeSlotsController:EndDrag(input)
	end)
	UserInputService.TouchEnded:Connect(function(input: InputObject)
		ThreeSlotsController:EndDrag(input)
	end)

	task.spawn(function()
		local triggerPart: BasePart? = nil
		while not triggerPart do
			task.wait(0.5)
			local taggedInstances: { Instance } = CollectionService:GetTagged("ForgeTrigger")
			local firstTaggedInstance: Instance? = taggedInstances[1]
			if firstTaggedInstance and firstTaggedInstance:IsA("BasePart") then
				triggerPart = firstTaggedInstance
			end
		end

		local forgeTrigger: BasePart = assert(triggerPart, "ForgeTrigger must be a BasePart")
		RunService.Heartbeat:Connect(function()
			local character: Model? = LocalPlayer.Character
			local rootPartInstance: Instance? = if character then character:FindFirstChild("HumanoidRootPart") else nil
			local rootPart: BasePart? =
				if rootPartInstance and rootPartInstance:IsA("BasePart") then rootPartInstance else nil

			if rootPart and forgeTrigger.Parent then
				if (rootPart.Position - forgeTrigger.Position).Magnitude <= TRIGGER_DISTANCE then
					if not ForgeStates.IsInZone then
						ForgeStates.IsInZone = true
						if not LocalPlayer:GetAttribute("IsOnArena") then
							ToggleEnabled(true)
						end
					end
				elseif ForgeStates.IsInZone then
					ForgeStates.IsInZone = false
					ToggleEnabled(false)
				end
			elseif ForgeStates.IsInZone then
				ForgeStates.IsInZone = false
				ToggleEnabled(false)
			end
		end)
	end)

end

return ForgeController
