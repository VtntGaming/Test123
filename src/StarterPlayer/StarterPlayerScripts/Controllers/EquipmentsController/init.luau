--!strict
-- Displays equipment previews and purchases abilities using server-authoritative prices and ownership.
--// Services
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Debris = game:GetService("Debris")
local MarketplaceService = game:GetService("MarketplaceService")
local SoundService = game:GetService("SoundService")

--// Modules
local Dummy = require(script.Dummy)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local UIInteractionController = require(script.Parent.UIInteractionController)
local Notification = require(ReplicatedStorage.Utils.NotificationUtil)
local ShowcaseProperties = require(script.ShowcaseProperties)
local AbilityPreviewFolder = script.AbilityPreviews
local AbilityPreviewTypes = require(script.AbilityPreviewTypes)
local ShrinkAbilityPreview = require(AbilityPreviewFolder.Shrink)

--// References
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local HUD = MainGui:WaitForChild("HUD")
local InventoryToggleButton = HUD.LeftButtons.ButtonList.EquipmentsButton
local NotifyFrame = InventoryToggleButton.Notification
local EquipmentFrame = MainGui:WaitForChild("EquipmentsFrame")
local CloseButton = EquipmentFrame.ExitButton
local Camera = workspace.CurrentCamera :: Camera
local Assets = ReplicatedStorage.Assets
local WeaponsFolder = Assets.Weapons
local EquipmentShowcase = ShowcaseProperties.EquipmentShowcase
local CharPos = EquipmentShowcase:WaitForChild("Layout"):WaitForChild("CharPos")
local ItemListing = EquipmentFrame.ScrollHolder.Container.ScrollingFrame
local ItemTemplate = ItemListing.Template
local EquipWeaponEvent = ReplicatedStorage.Events.EquipWeaponEvent
local TabHolderFrame = EquipmentFrame.TabHolder
local EquipAbilityEvent = ReplicatedStorage.Events.EquipAbilityEvent
local BuyButton = EquipmentFrame.BuyButton
local PriceFrame = BuyButton.Price
local EquipmentOpenSound = SoundService.SFX.EquipmentOpen

--// Constants
local ROTATION_FACTOR = -2
local CAMERA_NOISE_SPEED = 0.15
local CAMERA_NOISE_FACTOR = math.rad(5)
local PARALLAX_VERTICAL = math.rad(5)
local PARALLAX_HORIZONTAL = math.rad(5)
local ZOOM_IN_TIME = 1
local ZOOM_DISTANCE = 10
local WEAPON_CAMERA_LEFT_OFFSET = 2.5
local EQUIP_CHECK_INTERVAL = 1
local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
local TAB_ACTIVE, TAB_INACTIVE = "rbxassetid://72940564227520", "rbxassetid://85490089980863"
-- local EQUIPPED_IMG = "rbxassetid://85490089980863"
local OWNED_WEAPONS_ATTRIBUTE = "OwnedWeapons"
local BASE_NAME_ATTRIBUTE = "BaseName"
local RARITY_ATTRIBUTE = "Rarity"
local EQUIPPED_WEAPON_ATTRIBUTE = "EquippedWeaponName"
local EQUIPPED_BASE_WEAPON_ATTRIBUTE = "EquippedBaseWeapon"
local DISPLAY_NAME_ATTRIBUTE = "DisplayName"
local OWNED_ATTRIBUTE = "Owned"
local ITEM_TYPE_ATTRIBUTE = "ItemType"
local OWNED_ABILITY_ATTRIBUTE = "OwnedAbilities"
local EQUIPPED_ABILITY_ATTRIBUTE = "EquippedAbility"
local ABILITY_ORDER_ATTRIBUTE = "AbilityOrder"
local ROBUX_SYMBOL = "\u{e002}"
local COINS_ATTRIBUTE = "Coins"

--// Properties
local IsEnabled = false
local EnabledTransitionThread: thread?
local CameraFocusThread: thread?
local SelectedAbility: string? = nil
local AbilityPurchasePending = false
local RobuxPrices: { [number]: number } = {}
local LoadingRobuxPrices: { [number]: boolean } = {}
local CurrentTab = "Weapons"
local CurrentCategory = "Slap"
local LastWeaponOriginScale = 1
local PendingAbilityEquip: string?
local PendingWeaponEquip: string?

--// Types
export type EquipmentsController = {
	Init: () -> (),
	LoadCurrentCharacter: () -> (),
	SetEnabled: (enabled: boolean, internal: boolean?) -> (),
	SetCameraFocus: (enabled: boolean) -> (),
	EquipWeapon: (weaponName: string) -> (),
	EquipAbility: (abilityName: string) -> (),
	LoadListing: () -> (),
	SetCategory: (category: string, skipSelect: boolean?) -> (),
	SwitchTab: (tabName: string) -> (),
	UpdateItemStates: () -> (),
	UpdateEquipState: () -> (),
	ShowcaseAbility: (ability: string?) -> (),
	UpdateAbilityPurchase: () -> (),
	PurchaseAbility: () -> (),
	UpdateCoins: () -> (),
}

type ItemFrameType = typeof(ItemTemplate)
type AbilityPreviewModule = typeof(AbilityPreviewTypes.AbilityPreviewModule)

--// Controller
local Controller = {} :: EquipmentsController
local ActiveAbilityPreview: AbilityPreviewModule? = nil

local function StopAbilityPreview()
	local abilityPreview = ActiveAbilityPreview
	ActiveAbilityPreview = nil
	if abilityPreview and abilityPreview.StopPreview then
		abilityPreview.StopPreview()
	end
	if ShowcaseProperties.AbilityShowcaseThread then
		task.cancel(ShowcaseProperties.AbilityShowcaseThread)
		ShowcaseProperties.AbilityShowcaseThread = nil
	end
	ShowcaseProperties.CharacterVectorOffset = Vector3.zero
	ShowcaseProperties.CharacterScale = 1
	ShowcaseProperties.CharacterTransparency = 0
	ShowcaseProperties.CameraFollowCharacter = false
	ShowcaseProperties.UseSmoothCameraAnimation = false
	ShowcaseProperties.CameraOffset = Vector3.zero
	ShowcaseProperties.CustomFollowPosition = nil
	if ShowcaseProperties.ExistingRunningTrack then
		ShowcaseProperties.ExistingRunningTrack:Play()
		ShowcaseProperties.ExistingRunningTrack:AdjustSpeed(1)
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end
	Dummy.DestroyAll()
end

local function FormatNumber(n: number) -- 38699 → "38,699"
	local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,")
	s = s:reverse():gsub("^,", "")
	return s
end

local function ProcessCameraInputMovement(movement: number)
	local screenSize = Camera.ViewportSize.X

	local relatedMovement = movement / screenSize
	local rotationChange = relatedMovement * ROTATION_FACTOR
	local newRotation = ShowcaseProperties.TargetRotation - rotationChange
	ShowcaseProperties.TargetRotation = (newRotation) % 1

	if newRotation > ShowcaseProperties.TargetRotation then
		ShowcaseProperties.InstantRotationChange = -1
	elseif newRotation < ShowcaseProperties.TargetRotation then
		ShowcaseProperties.InstantRotationChange = 1
	end
end

local function GetOwnedWeapons(): {[string]: number}
	local ownedWeaponAttribute = LocalPlayer:GetAttribute(OWNED_WEAPONS_ATTRIBUTE)
	
	if ownedWeaponAttribute and type(ownedWeaponAttribute) == "string" then
		local ownedList = {}
		local ownedWeapons = string.split(ownedWeaponAttribute, ",")
		
		for _, weapon in ipairs(ownedWeapons) do
			if ownedList[weapon] then
				ownedList[weapon] += 1
			else
				ownedList[weapon] = 1
			end
		end

		return ownedList
	end
	
	return {}
end

-- Returns the name of current weapon and base weapon
local function GetEquippedWeapon(): (string, string)
	local equippedWeapon = tostring(LocalPlayer:GetAttribute(EQUIPPED_WEAPON_ATTRIBUTE))
	local equippedBaseWeapon = tostring(LocalPlayer:GetAttribute(EQUIPPED_BASE_WEAPON_ATTRIBUTE))
	
	return equippedWeapon, equippedBaseWeapon
end

local function GetEquippedAbility(): string
	local equippedAbility = tostring(LocalPlayer:GetAttribute(EQUIPPED_ABILITY_ATTRIBUTE))
	
	return equippedAbility
end

local function GetOwnedAbilites(): {string}
	local abilties = {}

	local value = LocalPlayer:GetAttribute(OWNED_ABILITY_ATTRIBUTE)
	
	if value and type(value) == "string" then
		pcall(function()
			pcall(function()
				abilties = string.split(value, ",")
			end)
		end)
	end

	return abilties
end

local function EaseOutQuart(x: number): number
	return 1 - math.pow(1 - x, 4)
end

local function _SortListing()-- listing by rarity type and equip-able state, currently not use
    local items: { GuiObject } = {}

    for _, item in ipairs(ItemListing:GetChildren()) do
        if item:IsA("GuiObject")
            and item ~= ItemTemplate
            and item:GetAttribute(ITEM_TYPE_ATTRIBUTE) ~= nil then
            table.insert(items, item)
        end
    end

    table.sort(items, function(item1: GuiObject, item2: GuiObject): boolean
        local item1Type = tostring(item1:GetAttribute(ITEM_TYPE_ATTRIBUTE))
        local item2Type = tostring(item2:GetAttribute(ITEM_TYPE_ATTRIBUTE))

        if item1Type ~= item2Type then
			-- Sort by type-name
            return item1Type < item2Type
        end

        if item1Type == "Weapons" then
            local owned1 = item1:GetAttribute(OWNED_ATTRIBUTE) == true
            local owned2 = item2:GetAttribute(OWNED_ATTRIBUTE) == true

            if owned1 ~= owned2 then
                return owned1
            end

            local rarity1 = tostring(item1:GetAttribute(RARITY_ATTRIBUTE))
            local rarity2 = tostring(item2:GetAttribute(RARITY_ATTRIBUTE))
            local rank1 = table.find(RARITY_ORDER, rarity1) or math.huge
            local rank2 = table.find(RARITY_ORDER, rarity2) or math.huge

            if rank1 ~= rank2 then
                return rank1 < rank2
            end
		elseif item1Type == "Abilities" then
			-- Starts at left
			-- Higher order to the right
			-- Non-order also to the right
			local order1 = tonumber(item1:GetAttribute(ABILITY_ORDER_ATTRIBUTE))
			local order2 = tonumber(item2:GetAttribute(ABILITY_ORDER_ATTRIBUTE))

			if order1 ~= order2 then
				if not order1 then
					return true
				elseif not order2 then
					return false
				end

				return order1 < order2
			end
        end

        return item1.Name < item2.Name
    end)

    for order, item in ipairs(items) do
        item.LayoutOrder = order
    end
end

function Controller.UpdateCoins()
	local coinAmount = tonumber(LocalPlayer:GetAttribute(COINS_ATTRIBUTE)) or 0
	local coinDisplay = EquipmentFrame.CurrencyHolder.Value

	coinDisplay.Text = FormatNumber(coinAmount)
end

function Controller.SetCameraFocus(enabled: boolean)
	Camera.CameraType = enabled and Enum.CameraType.Scriptable or Enum.CameraType.Custom
	
	if CameraFocusThread then
		task.cancel(CameraFocusThread)
	end
	
	if enabled then
		ShowcaseProperties.CurrentRotation = 0
		ShowcaseProperties.TargetRotation = 0
		CameraFocusThread = task.spawn(function()
			while true do
				local dt = task.wait()
				local t = time() * CAMERA_NOISE_SPEED
				local showcaseCharacter = EquipmentShowcase:FindFirstChild("Character")
				
				ShowcaseProperties.CurrentRotation = math.lerp(ShowcaseProperties.CurrentRotation + ShowcaseProperties.InstantRotationChange, ShowcaseProperties.TargetRotation, dt / 0.1)
				ShowcaseProperties.InstantRotationChange = 0
				
				if not showcaseCharacter then
					return
				end
				
				local rndX = math.noise(t, 0, 0) * CAMERA_NOISE_FACTOR
				local rndY = math.noise(0, t, 0) * CAMERA_NOISE_FACTOR
				local rndZ = math.noise(0, 0, t) * CAMERA_NOISE_FACTOR
				
				local angleNoise = CFrame.Angles(rndX, rndY, rndZ)
				
				local screenSize = Camera.ViewportSize
				local mouseLocation = UserInputService:GetMouseLocation()
				
				local screenRatio = screenSize.X / screenSize.Y
				local relatedLocation = mouseLocation / screenSize - Vector2.new(0.5, 0.5)
				
				local parallaxX = relatedLocation.X * PARALLAX_HORIZONTAL
				local parallaxY = relatedLocation.Y / screenRatio * PARALLAX_VERTICAL
				
				local targetParallax = Vector2.new(parallaxX, parallaxY)
				ShowcaseProperties.CurrentParallax = ShowcaseProperties.CurrentParallax:Lerp(targetParallax, dt / 0.25)
				local parallaxCFrame = CFrame.Angles(-ShowcaseProperties.CurrentParallax.Y, -ShowcaseProperties.CurrentParallax.X, 0)
				
				local elapsedSinceLastEnable = time() - ShowcaseProperties.LastEnabled
				local zoomProgress = 1 - EaseOutQuart(math.min(elapsedSinceLastEnable / ZOOM_IN_TIME, 1))
				local zoomDistance = ZOOM_DISTANCE * zoomProgress
				
				local charFixedCFrame = CharPos.CFrame
				-- Rotate character model without affecting the camera
				showcaseCharacter:PivotTo(charFixedCFrame * CFrame.Angles(0, math.rad(ShowcaseProperties.CurrentRotation * 360), 0) * CFrame.new(ShowcaseProperties.CharacterVectorOffset.X, ShowcaseProperties.CharacterVectorOffset.Y, ShowcaseProperties.CharacterVectorOffset.Z))
				
				if ShowcaseProperties.CurrentCharScale ~= ShowcaseProperties.CharacterScale then
					local applyCharacterScale = ShrinkAbilityPreview.ApplyCharacterScale
					if applyCharacterScale then
						applyCharacterScale(showcaseCharacter, ShowcaseProperties.CharacterScale)
					end
				end
				
				if ShowcaseProperties.CurrentCharTrans ~= ShowcaseProperties.CharacterTransparency then
					for _, item in ipairs(showcaseCharacter:GetDescendants()) do
						if item:IsA("BasePart") then
							item.LocalTransparencyModifier = ShowcaseProperties.CharacterTransparency
						end
					end
					
					ShowcaseProperties.CurrentCharTrans = ShowcaseProperties.CharacterTransparency
				end
				local targetLeftOffset = WEAPON_CAMERA_LEFT_OFFSET
				
				if CurrentTab == "Abilities" then
					targetLeftOffset = 0
				end
				
				ShowcaseProperties.CurrentLeftOffset = math.lerp(ShowcaseProperties.CurrentLeftOffset, targetLeftOffset, dt / 0.25)
				
				local targetCFrame = charFixedCFrame * angleNoise * CFrame.Angles(math.rad(15), 0, 0) * parallaxCFrame * CFrame.new(ShowcaseProperties.CurrentLeftOffset, 0, -8 - zoomDistance) * CFrame.Angles(0, math.rad(180), 0) * CFrame.new(ShowcaseProperties.CameraOffset.X, ShowcaseProperties.CameraOffset.Y, ShowcaseProperties.CameraOffset.Z)

				if ShowcaseProperties.CustomFollowPosition then					
					local currentPosition = targetCFrame.Position
					
					targetCFrame = CFrame.new(currentPosition, ShowcaseProperties.CustomFollowPosition or Vector3.zero)
				elseif ShowcaseProperties.CameraFollowCharacter then
					local currentPosition = targetCFrame.Position
					local charPosition = showcaseCharacter:GetPivot().Position

					targetCFrame = CFrame.new(currentPosition, charPosition)
				end

				if ShowcaseProperties.UseSmoothCameraAnimation then
					targetCFrame = Camera.CFrame:Lerp(targetCFrame, dt / 0.25)
				end

				Camera.CFrame = targetCFrame
			end
		end)
	end
end

local function SpawnDashHologram(character: Model, _progress: number?)
	local progress = _progress or 0
	if not character or not character.Parent then return end
	local folder = Instance.new("Folder")
	folder.Name, folder.Parent = "CombatDashEffect", workspace.Terrain
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "HumanoidRootPart" then
			local clone = part:Clone()
			for _, child in clone:GetChildren() do if not child:IsA("SpecialMesh") then child:Destroy() end end
			clone.Anchored, clone.CanCollide, clone.CanTouch, clone.CanQuery, clone.Massless = true, false, false, false, true
			clone.Material, clone.Transparency, clone.CFrame, clone.Parent = Enum.Material.Neon, 0.4 + progress * 0.6, part.CFrame, folder
			TweenService:Create(clone, TweenInfo.new(0.35), { Transparency = 1 }):Play()
		end
	end
	Debris:AddItem(folder, 0.4)
end

function Controller.EquipWeapon(weaponName: string)
	StopAbilityPreview()
	local data = WeaponConfig.GetWeaponInfo(weaponName)
	
	local character = EquipmentShowcase:FindFirstChild("Character")
	
	local existingWeapon = character and character:FindFirstChild("EquippedWeapon")
	
	if existingWeapon then
		existingWeapon:Destroy()
	end
	
	if not character then
		return
	end
	
	if not data then
		return
	end
		
	local root = character:WaitForChild("HumanoidRootPart") :: Part
	root.Anchored = true

	local animator = character:WaitForChild("Humanoid"):WaitForChild("Animator") :: Animator
	local animation = Instance.new("Animation")
	animation.AnimationId = data.Idle
	
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Stop()
	end

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play()	
	
	ShowcaseProperties.ExistingWeaponTrack = track
	
	if ShowcaseProperties.ExistingRunningTrack then
		ShowcaseProperties.ExistingRunningTrack:Stop()
	end
	
	local runAnim = EquipmentShowcase:FindFirstChild("DefaultRunAnim", true)
	if runAnim then
		local runTrack = animator:LoadAnimation(runAnim)
		runTrack.Priority = Enum.AnimationPriority.Movement		
		runTrack:Play()
		
		ShowcaseProperties.ExistingRunningTrack = runTrack
	end

	local attackAnimation = Instance.new("Animation")
	attackAnimation.AnimationId = data.Attack.AnimationId

	local attackTrack = animator:LoadAnimation(attackAnimation)
	attackTrack.Priority = Enum.AnimationPriority.Action2
	attackTrack.Looped = false
	ShowcaseProperties.ExistingAttackTrack = attackTrack

	local hand = character:FindFirstChild("RightHand")
	local weaponTemplate = WeaponsFolder:FindFirstChild(weaponName)
	
	if not hand or not weaponTemplate then
		return
	end
	
	local weapon = weaponTemplate:Clone() :: Model
	local weaponMainPart = weapon:FindFirstChild("Main", true) :: BasePart
	weapon.Name = "EquippedWeapon"
	weapon.Parent = character
	
	weapon:PivotTo(hand.CFrame)
	
	if not weaponMainPart then
		return
	end
	
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = weaponMainPart
	weld.Parent = weaponMainPart

	LastWeaponOriginScale = weapon:GetScale()
	
	ShowcaseProperties.TargetRotation = 0.9
	if ShowcaseProperties.CurrentRotation < 0.5 then
		ShowcaseProperties.InstantRotationChange = 1
	end
end

function Controller.EquipAbility(abilityName: string)
	Controller.ShowcaseAbility(abilityName)
	if table.find(GetOwnedAbilites(), abilityName) then
		PendingAbilityEquip = abilityName
	end
end

function Controller.ShowcaseAbility(abilityName: string?)
	StopAbilityPreview()
	SelectedAbility = abilityName
	Controller.UpdateAbilityPurchase()
	Dummy.DestroyAll()

	ShowcaseProperties.CharacterVectorOffset = Vector3.zero
	ShowcaseProperties.CharacterScale = 1
	ShowcaseProperties.CharacterTransparency = 0
	ShowcaseProperties.CameraFollowCharacter = false
	ShowcaseProperties.UseSmoothCameraAnimation = false
	ShowcaseProperties.CameraOffset = Vector3.zero
	ShowcaseProperties.CustomFollowPosition = nil
	if ShowcaseProperties.ExistingRunningTrack then
		ShowcaseProperties.ExistingRunningTrack:Play()
		ShowcaseProperties.ExistingRunningTrack:AdjustSpeed(1)
	end
	if ShowcaseProperties.ExistingWeaponTrack then
		ShowcaseProperties.ExistingWeaponTrack:Play()
	end

	local currentCharacter = EquipmentShowcase:FindFirstChild("Character")
	local currentModel = if currentCharacter and currentCharacter:IsA("Model") then currentCharacter else nil
	local rootInstance = currentModel and currentModel:FindFirstChild("HumanoidRootPart")
	local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else nil
	local humanoid = currentModel and currentModel:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local weaponInstance = currentModel and currentModel:FindFirstChild("EquippedWeapon")
	local weapon = if weaponInstance and weaponInstance:IsA("Model") then weaponInstance else nil

	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			if track ~= ShowcaseProperties.ExistingRunningTrack and track ~= ShowcaseProperties.ExistingWeaponTrack then
				track:Stop()
			end
		end
	end
	if weapon then
		weapon:ScaleTo(LastWeaponOriginScale)
	end

	local abilityShowcaseThread = coroutine.create(function()
		local abilityModuleInstance = if abilityName then AbilityPreviewFolder:FindFirstChild(abilityName) else nil
		if abilityModuleInstance and abilityModuleInstance:IsA("ModuleScript") then
			local abilityPreview = require(abilityModuleInstance) :: AbilityPreviewModule
			if type(abilityPreview) == "table" and type(abilityPreview.ShowcaseAbility) == "function" then
				ActiveAbilityPreview = abilityPreview
				abilityPreview.ShowcaseAbility({
					Character = currentModel,
					Root = root,
					Weapon = weapon,
					Animator = animator,
					LastWeaponOriginScale = LastWeaponOriginScale,
					SpawnDashHologram = SpawnDashHologram,
				})
				if ActiveAbilityPreview == abilityPreview then
					ActiveAbilityPreview = nil
				end
			end
		end

		ShowcaseProperties.CharacterVectorOffset = Vector3.zero
		ShowcaseProperties.CharacterScale = 1
		ShowcaseProperties.CharacterTransparency = 0
		ShowcaseProperties.CameraFollowCharacter = false
		ShowcaseProperties.UseSmoothCameraAnimation = false
		ShowcaseProperties.CameraOffset = Vector3.zero
		ShowcaseProperties.CustomFollowPosition = nil
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				if track ~= ShowcaseProperties.ExistingRunningTrack and track ~= ShowcaseProperties.ExistingWeaponTrack then
					track:Stop()
				end
			end
		end
		if ShowcaseProperties.ExistingWeaponTrack then
			ShowcaseProperties.ExistingWeaponTrack:Play()
		end
		if ShowcaseProperties.ExistingRunningTrack then
			ShowcaseProperties.ExistingRunningTrack:AdjustSpeed(1)
			ShowcaseProperties.ExistingRunningTrack:Play()
		end
		if weapon then
			weapon:ScaleTo(LastWeaponOriginScale)
		end
		Dummy.DestroyAll()
		if ShowcaseProperties.AbilityShowcaseThread == coroutine.running() then
			ShowcaseProperties.AbilityShowcaseThread = nil
		end
	end)
	ShowcaseProperties.AbilityShowcaseThread = abilityShowcaseThread
	task.spawn(abilityShowcaseThread)
end
function Controller.UpdateAbilityPurchase()
	local abilityName = SelectedAbility
	local abilities = AbilityConfig.Abilities :: {[string]: AbilityConfig.AbilityConfig}
	local config = if abilityName then abilities[abilityName] else nil
	local price = config and config.Price
	local owned = abilityName ~= nil and table.find(GetOwnedAbilites(), abilityName) ~= nil
	local ready = LocalPlayer:GetAttribute("DataLoaded") == true
	local pending = AbilityPurchasePending or LocalPlayer:GetAttribute("SimpleCheckoutPending") == true
		or ((not price or price.IsRobux ~= true or RobuxShopConfig.CheckoutMode ~= "Simple")
			and LocalPlayer:GetAttribute("ManagedCheckoutPending") == true)
	local canBuy = false
	PriceFrame.Visible = not owned
	PriceFrame.Icon.Visible = price ~= nil and price.IsRobux ~= true
	PriceFrame.Price.Text = "OFF-SALE"


	if price and (not config or not config.Unlisted) then
		local value = price.Price
		local valid = value >= 0 and value < math.huge and value % 1 == 0
		if price.IsRobux == true then
			valid = valid and value > 0
			PriceFrame.Price.Text = `{ROBUX_SYMBOL} -`
			local cachedPrice = RobuxPrices[value]
			if cachedPrice then
				PriceFrame.Price.Text = `{ROBUX_SYMBOL} {FormatNumber(cachedPrice)}`
			elseif valid and not LoadingRobuxPrices[value] then
				LoadingRobuxPrices[value] = true
				task.spawn(function()
					local success, info = pcall(function()
						return MarketplaceService:GetProductInfoAsync(value, Enum.InfoType.Product)
					end)
					LoadingRobuxPrices[value] = nil
					local robuxPrice = if success then tonumber(info.PriceInRobux) else nil
					if robuxPrice then
						RobuxPrices[value] = robuxPrice
						if SelectedAbility == abilityName then
							PriceFrame.Price.Text = `{ROBUX_SYMBOL} {FormatNumber(robuxPrice)}`
						end
					end
				end)
			end
			canBuy = valid
		else
			PriceFrame.Price.Text = FormatNumber(value)
			local coins = tonumber(LocalPlayer:GetAttribute(COINS_ATTRIBUTE)) or 0
			canBuy = valid and coins >= value
		end
	end

	canBuy = canBuy and ready and not pending and not owned
	BuyButton.Title.Text = if owned
		then "OWNED"
		elseif not ready then "LOADING"
		elseif pending then "PROCESSING"
		else "BUY"
	BuyButton.Active = canBuy
	BuyButton.Interactable = canBuy
	BuyButton.Image = if canBuy then TAB_ACTIVE else TAB_INACTIVE
end

function Controller.PurchaseAbility()
	Controller.UpdateAbilityPurchase()
	local abilityName = SelectedAbility
	if not abilityName or not BuyButton.Interactable then
		return
	end
	AbilityPurchasePending = true
	Controller.UpdateAbilityPurchase()
	task.spawn(function()
		-- The server creates this dynamic endpoint during AbilityService setup.
		local remote = ReplicatedStorage.Events:WaitForChild("PurchaseAbilityFunction", 10)
		local success, purchased, reason = pcall(function()
			if not remote or not remote:IsA("RemoteFunction") then
				return false, "Unavailable"
			end
			return remote:InvokeServer(abilityName)
		end)
		AbilityPurchasePending = false
		Controller.UpdateAbilityPurchase()
		if not success or not purchased then
			Notification.Show(
				"Warning",
				"Ability purchase unavailable: " .. tostring(if success then reason else "RetryLater")
			)
		elseif reason == "Purchased" then
			Notification.Show("Success", "Ability unlocked!")
		end
	end)
end

function Controller.SetEnabled(enabled: boolean, internal)
	if not enabled then
		StopAbilityPreview()
	else
		NotifyFrame.Visible = false
	end
	EquipmentShowcase.Parent = (enabled and workspace or nil) :: Instance
	IsEnabled = enabled
	LocalPlayer:SetAttribute("OpenedEquipment", enabled)
	if enabled then
		SoundService:PlayLocalSound(EquipmentOpenSound)
		ShowcaseProperties.LastEnabled = time()
	end
	
	GuiService.TouchControlsEnabled = not enabled
	Controller.SetCameraFocus(enabled)
	
	if EnabledTransitionThread then
		task.cancel(EnabledTransitionThread)
	end
	
	if internal then
		UIInteractionController.ToggleFrame(EquipmentFrame :: any, enabled, false)		
	end
	
	EnabledTransitionThread = task.spawn(function()
		if IsEnabled then			
			local item, category = GetEquippedWeapon()
			
			if item and category then
				Controller.SetCategory(category, true)
				Controller.EquipWeapon(item)
			end
			
			TweenUtils.PlayTweenSequence({
				TweenService:Create(EquipmentFrame.ButtonHolder, TweenInfo.new(0), {Position = UDim2.new(-1.5, 0, 0.22, 40)}),
				TweenService:Create(EquipmentFrame.Header, TweenInfo.new(0), {Position = UDim2.new(-1.5, 0, 0, 40)}),
				TweenService:Create(EquipmentFrame.ExitButton, TweenInfo.new(0), {Position = UDim2.new(1.5, 0, 0.12, 30)}),
				TweenService:Create(EquipmentFrame.TabHolder, TweenInfo.new(0), {Position = UDim2.new(1.5, 0, 0.1, 30)}),
				true,
				TweenService:Create(EquipmentFrame.Header, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.fromOffset(0, 40)}),
				0.05,
				true,
				TweenService:Create(EquipmentFrame.ButtonHolder, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.new(0, 0, 0.22, 40)}),
				0.05,
				true,
				TweenService:Create(EquipmentFrame.TabHolder, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.new(0.9, 0, 0.1, 30)}),
				0.05,
				TweenService:Create(EquipmentFrame.ExitButton, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.new(1, 0, 0.12, 30)}),
			})
		end
	end)	
end

function Controller.LoadCurrentCharacter()
	task.spawn(function()
		if LocalPlayer.UserId <= 0 then
			return
		end
		
		local existingChar = EquipmentShowcase:FindFirstChild("Character")

		if existingChar then
			existingChar:Destroy()
		end
		
		local user = LocalPlayer.User
		local newChar = Players:CreateHumanoidModelFromUserIdAsync(user)
		newChar.Name = "Character"
		newChar.Parent = EquipmentShowcase
		newChar:PivotTo(CharPos.CFrame)
		local root = newChar:WaitForChild("HumanoidRootPart") :: Part
		root.Anchored = true
	end)
end

function Controller.LoadListing()
	-- Load the list of weapons
	local allItems: {string} = {}
	
	local rarities = WeaponConfig.RarityVariants :: {[string]: {string}}
	local baseWeapons = WeaponConfig.BaseWeapons :: {[string]: any}
	
	local rarityVariants: {string} = {}
	local weaponVariants: {string} = {}
	
	for weaponName, _ in pairs(baseWeapons) do
		table.insert(weaponVariants, weaponName)
	end
	
	for _, rarity in pairs(rarities) do
		for _, variant in ipairs(rarity) do
			table.insert(rarityVariants, variant)
		end
	end
	
	table.insert(rarityVariants, "") -- Also adds the default item
	
	-- Combine it all to be a fully items
	for _, rarityVariant in ipairs(rarityVariants) do
		for _, weaponName in ipairs(weaponVariants) do
			table.insert(allItems, `{weaponName}{rarityVariant}`)
		end
	end
	
	do -- KAIDO SPECIAL
		table.insert(allItems, "HammerKaido")
	end

	-- Add every items and it's variants into a full list
	for _, item in ipairs(allItems) do	
		local itemData = WeaponConfig.GetWeaponInfo(item)
		
		if itemData then
			local itemFrame = ItemTemplate:Clone()
			itemFrame.Name = itemData.FullName
			itemFrame.Icon.Image = itemData.Icon
			itemFrame.Title.Text = itemData.DisplayName
			
			itemFrame.ImageColor3 = itemData.RarityColor
			
			local itemBaseName = itemData.BaseName
			itemFrame:SetAttribute(BASE_NAME_ATTRIBUTE, itemBaseName)
			itemFrame:SetAttribute(RARITY_ATTRIBUTE, itemData.Rarity)
			itemFrame:SetAttribute(OWNED_ATTRIBUTE, false)
			itemFrame:SetAttribute(DISPLAY_NAME_ATTRIBUTE, itemData.DisplayName)
			itemFrame:SetAttribute(ITEM_TYPE_ATTRIBUTE, "Weapons")
			
			itemFrame.Parent = ItemListing
			itemFrame.Visible = itemBaseName == CurrentCategory
			
			itemFrame.Activated:Connect(function()
				Controller.EquipWeapon(item)
				
				local isOwned = itemFrame:GetAttribute(OWNED_ATTRIBUTE)
				if isOwned then
					PendingWeaponEquip = item
				end
			end)
		end
	end
	
	-- Load the list of abilities
	for ability, data in pairs(AbilityConfig.Abilities :: {[string]: AbilityConfig.AbilityConfig}) do
		if data and data.Unlisted then
			continue
		end

		local itemFrame = ItemTemplate:Clone()
		itemFrame.Name = ability
		itemFrame.Icon.Image = data and data.Icon or ""

		local hoverIcon = (itemFrame.Icon :: ImageLabel):Clone()
		hoverIcon.ImageColor3 = Color3.fromRGB(0,0,0)
		hoverIcon.Name = "Hover"
		hoverIcon.Parent = itemFrame

		itemFrame.Title.Text = ability
		local rarity = if data and data.Rarity then data.Rarity else "Common"
		itemFrame.ImageColor3 = WeaponConfig.Rarities[rarity] or WeaponConfig.Rarities.Common
		itemFrame.Parent = ItemListing
		itemFrame.Count.Count.Visible = false
		itemFrame:SetAttribute(ABILITY_ORDER_ATTRIBUTE, data and data.Order)
		itemFrame:SetAttribute(ITEM_TYPE_ATTRIBUTE, "Abilities")
		
		itemFrame.Activated:Connect(function()
			Controller.EquipAbility(ability)
		end)
	end

	do -- old code
		local items = ItemListing:GetChildren()
	
		table.remove(items, table.find(items, ItemListing.Template))
		table.remove(items, table.find(items, ItemListing.UIListLayout))
		
		table.sort(items, function(item1_, item2_)
			local item1 = item1_ :: ItemFrameType
			local item2 = item2_ :: ItemFrameType

			local item1Type = item1:GetAttribute(ITEM_TYPE_ATTRIBUTE)
			local item2Type = item2:GetAttribute(ITEM_TYPE_ATTRIBUTE)
			
			if item1Type ~= item2Type then
				return item1Type == "Weapons"
			end
			
			if item1Type == "Weapons" then
				do -- KAIDO SPECIAL
					-- Keep the default Hammer first and Kaido immediately after it.
					local priority1 = if item1.Name == "Hammer" then 0
						elseif item1.Name == "HammerKaido" then 1
						else 2

					local priority2 = if item2.Name == "Hammer" then 0
						elseif item2.Name == "HammerKaido" then 1
						else 2

					if priority1 ~= priority2 then
						return priority1 < priority2
					end
				end
				local item1Rarity = tostring(item1:GetAttribute(RARITY_ATTRIBUTE))
				local item2Rarity = tostring(item2:GetAttribute(RARITY_ATTRIBUTE))

				local rarityOrder1 = table.find(RARITY_ORDER, item1Rarity)
				local rarityOrder2 = table.find(RARITY_ORDER, item2Rarity)
				
				-- Sort by owned first, then rarity, and last is name
				if not rarityOrder1 then
					return false
				elseif not rarityOrder2 then
					return true
				elseif rarityOrder1 ~= rarityOrder2 then
					return rarityOrder1 < rarityOrder2
				end
			elseif item1Type == "Abilities" then
				-- Starts at left
				-- Higher order to the right
				-- Non-order also to the right
				local order1 = tonumber(item1:GetAttribute(ABILITY_ORDER_ATTRIBUTE))
				local order2 = tonumber(item2:GetAttribute(ABILITY_ORDER_ATTRIBUTE))

				if order1 ~= order2 then
					if not order1 then
						return true
					elseif not order2 then
						return false
					end

					return order1 < order2
				end
			end		
			
			-- Sort by name instead if all rarity all the same
			return item1.Name < item2.Name
		end)
		
		for order, item in ipairs(items) do
			if item:IsA("GuiObject") then
				item.LayoutOrder = order			
			end
		end
	end
end

function Controller.UpdateItemStates()
	local ownedItems = GetOwnedWeapons()
	local ownedAbilities = GetOwnedAbilites()
	
	for _, item in ipairs(ItemListing:GetChildren()) do
		if item ~= ItemListing.UIListLayout and item ~= ItemListing.Template then
			local itemType = item:GetAttribute(ITEM_TYPE_ATTRIBUTE)
			if itemType == "Weapons" then
				local itemName = item.Name
				local ownedCount = ownedItems[itemName]
				local isOwned = ownedCount and ownedCount > 0
				
				local equipmentItem = item :: ItemFrameType
				local itemDisplayName = tostring(equipmentItem:GetAttribute(DISPLAY_NAME_ATTRIBUTE))
				
				equipmentItem.Title.Text = isOwned and itemDisplayName or "???"
				equipmentItem.Count.Count.Visible = isOwned
				if isOwned then
					equipmentItem.Count.Count.Text = `x<font size="20">{ownedCount}</font>`
				end
				
				equipmentItem:SetAttribute(OWNED_ATTRIBUTE, isOwned)
				
				equipmentItem.Icon.ImageColor3 = isOwned and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(0, 0, 0)
			elseif itemType == "Abilities" then
				local isOwned = table.find(ownedAbilities, item.Name) ~= nil
				
				local equipmentItem= item :: Frame
				local hover = equipmentItem:FindFirstChild("Hover") :: Frame
				local title = equipmentItem:FindFirstChild("Title") :: TextLabel
				if hover and title then
					hover.Visible = not isOwned
					title.Text = if isOwned then equipmentItem.Name else "???"
				end
			end
			
		end
	end

	--SortListing() -- listing by rarity type and equip-able state, currently not use
end

function Controller.UpdateEquipState()
	local item, _ = GetEquippedWeapon()
	local ability = GetEquippedAbility()

	for _, currentItem : ItemFrameType in ipairs(ItemListing:GetChildren() :: any) do
		if not currentItem:IsA("GuiObject") or currentItem == ItemListing.Template then
			continue
		end

		local itemType = currentItem:GetAttribute("ItemType")
		-- Equip state for weapons
		if itemType == "Weapons" and currentItem.Name == item then
			currentItem.Equipped.Visible = true
			continue
		end
		
		-- Equip state for abilities
		if itemType == "Abilities" and currentItem.Name == ability then
			currentItem.Equipped.Visible = true
			continue
		end

		currentItem.Equipped.Visible = false
	end
end

function Controller.SwitchTab(tabName)
	if tabName ~= "Abilities" then
		StopAbilityPreview()
	end
	CurrentTab = tabName

	local isWeapon = tabName == "Weapons"
	local isAbility = tabName == "Abilities"
	
	EquipmentFrame.ButtonHolder.Visible = isWeapon
	EquipmentFrame.CurrencyHolder.Visible = isAbility
	
	for _, item in ipairs(TabHolderFrame:GetChildren()) do
		if item:IsA("ImageButton") then
			item.Image = item.Name == tabName and TAB_ACTIVE or TAB_INACTIVE
		end
	end
	
	for _, item in ipairs(ItemListing:GetChildren()) do
		if item ~= ItemListing.UIListLayout and item ~= ItemListing.Template and item:IsA("GuiObject") then
			local itemType = item:GetAttribute(ITEM_TYPE_ATTRIBUTE)
			
			item.Visible = itemType == tabName			
		end
	end
	
	if tabName == "Weapons" then
		Controller.SetCategory(CurrentCategory, true)
	end

	BuyButton.Visible = tabName == "Abilities"
end

function Controller.SetCategory(category, skipSelect)
	CurrentCategory = category
	
	if CurrentTab ~= "Weapons" then
		return
	end
	
	local firstItemName: string?
	local firstOwnedItemName: string?
	
	for _, item in ipairs(ItemListing:GetChildren()) do
		if item ~= ItemListing.Template and item ~= ItemListing.UIListLayout then
			local guiItem = item :: ItemFrameType
			local itemType = item:GetAttribute(ITEM_TYPE_ATTRIBUTE)
			guiItem.Visible = itemType == "Weapons" and item:GetAttribute(BASE_NAME_ATTRIBUTE) == category
			
			if guiItem.Visible and not firstOwnedItemName then
				if not firstItemName then
					firstItemName = guiItem.Name					
				end
				
				local isOwned = guiItem:GetAttribute(OWNED_ATTRIBUTE)
				
				if isOwned and not firstOwnedItemName then
					firstOwnedItemName = guiItem.Name
				end
			end
		end
	end
	
	for _, item in ipairs(EquipmentFrame.ButtonHolder:GetChildren()) do
		if item:IsA("ImageButton") then
			item.ImageColor3 = item.Name == category and Color3.new(1, 1, 1) or  Color3.new(0.784314, 0.784314, 0.784314)
		end
	end
	
	if not skipSelect then
		if firstOwnedItemName then
			Controller.EquipWeapon(firstOwnedItemName)
		elseif firstItemName then
			Controller.EquipWeapon(firstItemName)
		end		
	end
end

function Controller.Init()
	BuyButton.Activated:Connect(function()
		Controller.PurchaseAbility()
	end)
	for _, attribute in ipairs({ COINS_ATTRIBUTE, "DataLoaded", "ManagedCheckoutPending", "SimpleCheckoutPending" }) do
		LocalPlayer:GetAttributeChangedSignal(attribute):Connect(Controller.UpdateAbilityPurchase)
	end
	Controller.UpdateAbilityPurchase()
	InventoryToggleButton.Activated:Connect(function()
		Controller.SetEnabled(not IsEnabled, true)
	end)
	
	CloseButton.Activated:Connect(function()
		Controller.SetEnabled(false, true)
	end)
	
	local previousPosition: Vector3?
	
	UserInputService.InputChanged:Connect(function(input)
		if not EquipmentFrame.Visible then
			return
		end

		if input.UserInputType == Enum.UserInputType.Touch or (
			input.UserInputType == Enum.UserInputType.MouseMovement 
				and (UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or 
					UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
				)) then
			local movement = 0
			local currentPos = input.Position :: Vector3
			local inputDelta = input.Delta :: Vector3
			
			if previousPosition then
				movement = currentPos.X - previousPosition.X
			end					
			
			movement += inputDelta.X * 0.5

			if movement ~= 0 then
				ProcessCameraInputMovement(movement)				
			end
			
			previousPosition = currentPos
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if not EquipmentFrame.Visible then
			return
		end
		
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Focus then
			previousPosition = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)
	
	UserInputService.InputBegan:Connect(function(input)
		if not EquipmentFrame.Visible then
			return
		end

		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			previousPosition = input.Position
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)
	
	LocalPlayer:GetAttributeChangedSignal(OWNED_WEAPONS_ATTRIBUTE):Connect(function()
		Controller.UpdateItemStates()
	end)
	
	LocalPlayer:GetAttributeChangedSignal(EQUIPPED_WEAPON_ATTRIBUTE):Connect(function()
		Controller.UpdateEquipState()
	end)
	
	LocalPlayer:GetAttributeChangedSignal(OWNED_ABILITY_ATTRIBUTE):Connect(function()
		Controller.UpdateItemStates()
		Controller.UpdateAbilityPurchase()
	end)
	
	LocalPlayer:GetAttributeChangedSignal(EQUIPPED_ABILITY_ATTRIBUTE):Connect(function()
		Controller.UpdateEquipState()
	end)

	LocalPlayer:GetAttributeChangedSignal(COINS_ATTRIBUTE):Connect(function()
		Controller.UpdateCoins()
	end)
	
	for _, item in ipairs(EquipmentFrame.ButtonHolder:GetChildren()) do
		if item:IsA("GuiButton") then
			local itemCategory = item.Name
			item.Activated:Connect(function()
				Controller.SetCategory(itemCategory)
			end)
		end
	end
	
	for _, item in ipairs(TabHolderFrame:GetChildren()) do
		if item:IsA("ImageButton") then
			local tabName = item.Name
			item.Activated:Connect(function()
				Controller.SwitchTab(tabName)
			end)
			
			item.MouseEnter:Connect(function()
				
			end)
		end
	end
	
	Controller.SetCategory("Slap")
	
	EquipmentFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		Controller.SetEnabled(EquipmentFrame.Visible)
	end)

	TweenService:Create(NotifyFrame.UIScale, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Scale = 0.85
	}):Play()

	task.delay(5, function()
		LocalPlayer:GetAttributeChangedSignal(OWNED_ABILITY_ATTRIBUTE):Connect(function()
			NotifyFrame.Visible = true
		end)

		LocalPlayer:GetAttributeChangedSignal(OWNED_ABILITY_ATTRIBUTE):Connect(function()
			NotifyFrame.Visible = true			
		end)
	end)

	task.spawn(function()
		while task.wait(EQUIP_CHECK_INTERVAL) do
			if PendingAbilityEquip then
				EquipAbilityEvent:FireServer(PendingAbilityEquip)
				PendingAbilityEquip = nil
			end

			if PendingWeaponEquip then			
				EquipWeaponEvent:FireServer(PendingWeaponEquip)
				PendingWeaponEquip = nil
			end
		end
	end)
	
	--// Default setup
	ShowcaseProperties.CharacterCFrame = CharPos.CFrame
	Controller.SetEnabled(false, true)
	Controller.LoadCurrentCharacter()
	Controller.LoadListing()
	Controller.UpdateItemStates()
	Controller.UpdateEquipState()
	Controller.SwitchTab("Weapons")
	Controller.UpdateCoins()
end

do -- KAIDO SPECIAL
	-- Adds an unowned Kaido shortcut using the existing equipment Buy button.
	-- Remove this entire block to restore the original controller behavior.
	local selectedWeapon: string? = nil
	local equipWeapon = Controller.EquipWeapon
	local switchTab = Controller.SwitchTab
	local updateItemStates = Controller.UpdateItemStates
	local updateAbilityPurchase = Controller.UpdateAbilityPurchase
	local purchaseAbility = Controller.PurchaseAbility

	local function updateKaidoButton()
		if CurrentTab ~= "Weapons" then
			return
		end

		local ownedCount = GetOwnedWeapons().HammerKaido or 0
		local show = selectedWeapon == "HammerKaido" and ownedCount == 0
		local ready = LocalPlayer:GetAttribute("DataLoaded") == true
		BuyButton.Visible = show
		if not show then
			return
		end

		PriceFrame.Visible = false
		BuyButton.Title.Text = if ready then "GET" else "LOADING"
		BuyButton.Active = ready
		BuyButton.Interactable = ready
		BuyButton.Image = if ready then TAB_ACTIVE else TAB_INACTIVE
	end

	Controller.EquipWeapon = function(weaponName: string)
		selectedWeapon = weaponName
		equipWeapon(weaponName)
		updateKaidoButton()
	end

	Controller.UpdateAbilityPurchase = function()
		PriceFrame.Visible = true
		updateAbilityPurchase()
		updateKaidoButton()
	end

	Controller.SwitchTab = function(tabName: string)
		switchTab(tabName)
		if tabName == "Abilities" then
			Controller.UpdateAbilityPurchase()
		else
			updateKaidoButton()
		end
	end

	Controller.UpdateItemStates = function()
		updateItemStates()
		updateKaidoButton()
	end

	Controller.PurchaseAbility = function()
		if CurrentTab ~= "Weapons" then
			purchaseAbility()
			return
		end

		updateKaidoButton()
		if selectedWeapon ~= "HammerKaido" or not BuyButton.Visible or not BuyButton.Interactable then
			return
		end

		local shopController = require(script.Parent.RobuxShopController)
		local shopFrame = MainGui.RobuxShopFrame
		local listing = shopFrame.CanvasGroup.Listing
		local limitedItem = listing.Exclusive.LimitedItem

		Controller.SetEnabled(false, true)
		shopController:ToggleEnabled(true)
		-- Wait for the shop's 0.35s opening scale tween before measuring positions.
		task.delay(0.4, function()
			if not shopFrame.Visible or not shopController.IsEnabled then
				return
			end
			local offset = limitedItem.AbsolutePosition.Y - listing.AbsolutePosition.Y - 1000	
			local maxScroll = math.max(0, listing.AbsoluteCanvasSize.Y - listing.AbsoluteWindowSize.Y)
			listing.CanvasPosition = Vector2.new(
				listing.CanvasPosition.X,
				math.clamp(listing.CanvasPosition.Y + offset, 0, maxScroll)
			)
		end)
	end
end

return Controller
