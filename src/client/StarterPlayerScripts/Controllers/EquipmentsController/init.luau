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
local StarterPlayer = game:GetService("StarterPlayer")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local ChargeEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.Charge.ChargeEffect)
local PullEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.Pull.PullEffect)
local PushEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.Push.PushEffect)
local SmashEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.Smash.SmashEffect)
local ThrowEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.Throw.ThrowEffect)
local TimeStopEffect = require(StarterPlayer.StarterPlayerScripts.Controllers.CombatController.TimeStop.TimeStopEffect)
local Dummy = require(script.Dummy)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local AbilityConfig = require(ReplicatedStorage.SharedModules.AbilityConfig)
local ShrinkScale = require(ReplicatedStorage.SharedModules.ShrinkScale)
local RobuxShopConfig = require(ReplicatedStorage.SharedModules.RobuxShopConfig)
local TweenUtils = require(ReplicatedStorage.Utils.TweenUtils)
local UIInteractionController = require(script.Parent.UIInteractionController)
local GameplayController = require(script.Parent.GameplayController)
local Notification = require(ReplicatedStorage.Utils.NotificationUtil)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local HUD = MainGui:WaitForChild("HUD")
local InventoryToggleButton = HUD.LeftButtons.ButtonList.EquipmentsButton
local NotifyFrame = InventoryToggleButton.Notification
local EquipmentFrame = MainGui:WaitForChild("EquipmentsFrame")
local CloseButton = EquipmentFrame.ExitButton
local Camera = workspace.CurrentCamera :: Camera
local EquipmentShowcase = ReplicatedStorage.Assets.EquipmentShowcase
local Assets = ReplicatedStorage.Assets
local WeaponsFolder = Assets.Weapons
local CharPos = EquipmentShowcase:WaitForChild("Layout"):WaitForChild("CharPos")
local ItemListing = EquipmentFrame.ScrollHolder.Container.ScrollingFrame
local ItemTemplate = ItemListing.Template
local EquipWeaponEvent = ReplicatedStorage.Events.EquipWeaponEvent
local TabHolderFrame = EquipmentFrame.TabHolder
local SFXFolder = SoundService.SFX
local EquipAbilityEvent = ReplicatedStorage.Events.EquipAbilityEvent
local BuyButton = EquipmentFrame.BuyButton
local PriceFrame = BuyButton.Price

--// Constants
local ROTATION_FACTOR = -2
local CAMERA_NOISE_SPEED = 0.15
local CAMERA_NOISE_FACTOR = math.rad(5)
local PARALLAX_VERTICAL = math.rad(5)
local PARALLAX_HORIZONTAL = math.rad(5)
local ZOOM_IN_TIME = 1
local ZOOM_DISTANCE = 10
local WEAPON_CAMERA_LEFT_OFFSET = 2.5
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
local AbilityShowcaseThread: thread?
local BigWeaponPreview: { Weapon: Model, BaseScale: number }? = nil
local TimeStopPreviewActive = false
local ShrinkPreviewCharacter: Model? = nil
local SelectedAbility: string? = nil
local AbilityPurchasePending = false
local RobuxPrices: { [number]: number } = {}
local LoadingRobuxPrices: { [number]: boolean } = {}
local TargetRotation = 0
local CurrentRotation = 0
local InstantRotationChange = 0
local LastEnabled = 0
local CameraFollowCharacter = false
local UseSmoothCameraAnimation = false
local CameraOffset = Vector3.zero
local CustomFollowPosition: Vector3?
local CharacterVectorOffset = Vector3.zero
local CurrentParallax = Vector2.zero
local CharacterScale = 1
local CharacterTransparency = 0
local CurrentCharScale = 1
local CurrentCharTrans = 0
local CurrentLeftOffset = WEAPON_CAMERA_LEFT_OFFSET
local CurrentTab = "Weapons"
local CurrentCategory = "Slap"
local ExistingWeaponTrack: AnimationTrack?
local ExistingRunningTrack: AnimationTrack?
local ExistingAttackTrack: AnimationTrack?
local LastWeaponOriginScale = 1

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

local Controller = {} :: EquipmentsController

local function ApplyPreviewCharacterScale(character: Model, scale: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	ShrinkScale.Apply(character, humanoid, root, scale, AbilityConfig.Abilities.Shrink.ScaleWeapon)
	CurrentCharScale = scale
end

local function StopTimeStopPreview()
	if not TimeStopPreviewActive then
		return
	end
	TimeStopPreviewActive = false
	if AbilityShowcaseThread then
		task.cancel(AbilityShowcaseThread)
		AbilityShowcaseThread = nil
	end
	TimeStopEffect.Cancel(LocalPlayer, true)
	Dummy.DestroyAll()
end

local function StopShrinkPreview()
	local character = ShrinkPreviewCharacter
	if not character then
		return
	end
	ShrinkPreviewCharacter = nil
	if AbilityShowcaseThread then
		task.cancel(AbilityShowcaseThread)
		AbilityShowcaseThread = nil
	end
	CharacterScale = 1
	if character.Parent then
		ApplyPreviewCharacterScale(character, 1)
	end
end

local function ScalePreviewWeapon(weapon: Model, scale: number)
	local main = weapon:FindFirstChild("Main", true)
	if not main or not main:IsA("BasePart") then
		return
	end
	local mainFrame = main.CFrame
	local grips: { { Joint: WeldConstraint, Part1: BasePart } } = {}
	-- Release the hand grip while scaling so the preview character does not move.
	for _, descendant in weapon:GetDescendants() do
		if descendant:IsA("WeldConstraint") and descendant.Enabled then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 and (not part0:IsDescendantOf(weapon) or not part1:IsDescendantOf(weapon)) then
				table.insert(grips, { Joint = descendant, Part1 = part1 })
				descendant.Enabled = false
				descendant.Part1 = nil
			end
		end
	end
	weapon:ScaleTo(scale)
	weapon:PivotTo(mainFrame * main.CFrame:Inverse() * weapon:GetPivot())
	for _, grip in grips do
		grip.Joint.Part1 = grip.Part1
		grip.Joint.Enabled = true
	end
end

local function StopBigWeaponPreview()
	local preview = BigWeaponPreview
	if not preview then
		return
	end
	BigWeaponPreview = nil
	if AbilityShowcaseThread then
		task.cancel(AbilityShowcaseThread)
		AbilityShowcaseThread = nil
	end
	if preview.Weapon.Parent then
		ScalePreviewWeapon(preview.Weapon, preview.BaseScale)
	end
	UseSmoothCameraAnimation = false
	CameraOffset = Vector3.zero
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
	local newRotation = TargetRotation - rotationChange
	TargetRotation = (newRotation) % 1

	if newRotation > TargetRotation then
		InstantRotationChange = -1
	elseif newRotation < TargetRotation then
		InstantRotationChange = 1
	end
end

local function GetOwnedWeapons(): {[string]: number}
	local ownedWeaponAttribute = PlayerData.Get(LocalPlayer, OWNED_WEAPONS_ATTRIBUTE)
	
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
	local equippedWeapon = tostring(PlayerData.Get(LocalPlayer, EQUIPPED_WEAPON_ATTRIBUTE))
	local equippedBaseWeapon = tostring(PlayerData.Get(LocalPlayer, EQUIPPED_BASE_WEAPON_ATTRIBUTE))
	
	return equippedWeapon, equippedBaseWeapon
end

local function GetEquippedAbility(): string
	local equippedAbility = tostring(PlayerData.Get(LocalPlayer, EQUIPPED_ABILITY_ATTRIBUTE))
	
	return equippedAbility
end

local function GetOwnedAbilites(): {string}
	local abilties = {}

	local value = PlayerData.Get(LocalPlayer, OWNED_ABILITY_ATTRIBUTE)
	
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

local function SortListing()-- listing by rarity type and equip-able state, currently not use
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
	local coinAmount = tonumber(PlayerData.Get(LocalPlayer, COINS_ATTRIBUTE)) or 0
	local coinDisplay = EquipmentFrame.CurrencyHolder.Value

	coinDisplay.Text = FormatNumber(coinAmount)
end

function Controller.SetCameraFocus(enabled: boolean)
	Camera.CameraType = enabled and Enum.CameraType.Scriptable or Enum.CameraType.Custom
	
	if CameraFocusThread then
		task.cancel(CameraFocusThread)
	end
	
	if enabled then
		CurrentRotation = 0
		TargetRotation = 0
		CameraFocusThread = task.spawn(function()
			while true do
				local dt = task.wait()
				local t = time() * CAMERA_NOISE_SPEED
				local showcaseCharacter = EquipmentShowcase:FindFirstChild("Character")
				
				CurrentRotation = math.lerp(CurrentRotation + InstantRotationChange, TargetRotation, dt / 0.1)
				InstantRotationChange = 0
				
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
				CurrentParallax = CurrentParallax:Lerp(targetParallax, dt / 0.25)
				local parallaxCFrame = CFrame.Angles(-CurrentParallax.Y, -CurrentParallax.X, 0)
				
				local elapsedSinceLastEnable = time() - LastEnabled
				local zoomProgress = 1 - EaseOutQuart(math.min(elapsedSinceLastEnable / ZOOM_IN_TIME, 1))
				local zoomDistance = ZOOM_DISTANCE * zoomProgress
				
				local charFixedCFrame = CharPos.CFrame
				-- Rotate character model without affecting the camera
				showcaseCharacter:PivotTo(charFixedCFrame * CFrame.Angles(0, math.rad(CurrentRotation * 360), 0) * CFrame.new(CharacterVectorOffset.X, CharacterVectorOffset.Y, CharacterVectorOffset.Z))
				
				if CurrentCharScale ~= CharacterScale then
					ApplyPreviewCharacterScale(showcaseCharacter, CharacterScale)
				end
				
				if CurrentCharTrans ~= CharacterTransparency then
					for _, item in ipairs(showcaseCharacter:GetDescendants()) do
						if item:IsA("BasePart") then
							item.LocalTransparencyModifier = CharacterTransparency
						end
					end
					
					CurrentCharTrans = CharacterTransparency
				end
				local targetLeftOffset = WEAPON_CAMERA_LEFT_OFFSET
				
				if CurrentTab == "Abilities" then
					targetLeftOffset = 0
				end
				
				CurrentLeftOffset = math.lerp(CurrentLeftOffset, targetLeftOffset, dt / 0.25)
				
				local targetCFrame = charFixedCFrame * angleNoise * CFrame.Angles(math.rad(15), 0, 0) * parallaxCFrame * CFrame.new(CurrentLeftOffset, 0, -8 - zoomDistance) * CFrame.Angles(0, math.rad(180), 0) * CFrame.new(CameraOffset.X, CameraOffset.Y, CameraOffset.Z)

				if CustomFollowPosition then					
					local currentPosition = targetCFrame.Position
					
					targetCFrame = CFrame.new(currentPosition, CustomFollowPosition)
				elseif CameraFollowCharacter then
					local currentPosition = targetCFrame.Position
					local charPosition = showcaseCharacter:GetPivot().Position

					targetCFrame = CFrame.new(currentPosition, charPosition)
				end

				if UseSmoothCameraAnimation then
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
	StopTimeStopPreview()
	StopShrinkPreview()
	StopBigWeaponPreview()
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
	
	if ExistingWeaponTrack then
		ExistingWeaponTrack:Stop()
	end

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play()	
	
	ExistingWeaponTrack = track
	
	if ExistingRunningTrack then
		ExistingRunningTrack:Stop()
	end
	
	local runAnim = EquipmentShowcase:FindFirstChild("DefaultRunAnim", true)
	if runAnim then
		local runTrack = animator:LoadAnimation(runAnim)
		runTrack.Priority = Enum.AnimationPriority.Movement		
		runTrack:Play()
		
		ExistingRunningTrack = runTrack
	end

	local attackAnimation = Instance.new("Animation")
	attackAnimation.AnimationId = data.Attack.AnimationId

	local attackTrack = animator:LoadAnimation(attackAnimation)
	attackTrack.Priority = Enum.AnimationPriority.Action2
	attackTrack.Looped = false
	ExistingAttackTrack = attackTrack

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
	
	TargetRotation = 0.9
	if CurrentRotation < 0.5 then
		InstantRotationChange = 1
	end
end

function Controller.EquipAbility(abilityName: string)
	Controller.ShowcaseAbility(abilityName)
	if table.find(GetOwnedAbilites(), abilityName) then
		EquipAbilityEvent:FireServer(abilityName)
	end
end

function Controller.ShowcaseAbility(abilityName: string?)
	StopTimeStopPreview()
	StopShrinkPreview()
	StopBigWeaponPreview()
	SelectedAbility = abilityName
	Controller.UpdateAbilityPurchase()
	Dummy.DestroyAll()

	-- Set everything back to default
	CharacterVectorOffset = Vector3.zero
	CharacterScale = 1
	CharacterTransparency = 0
	CameraFollowCharacter = false
	UseSmoothCameraAnimation = false
	CameraOffset = Vector3.zero
	CustomFollowPosition = nil
	SmashEffect.StopTelegraph(LocalPlayer)
	if ExistingRunningTrack then
		ExistingRunningTrack:Play()
		ExistingRunningTrack:AdjustSpeed(1)
	end
	if ExistingWeaponTrack then
		ExistingWeaponTrack:Play()
	end
	
	if AbilityShowcaseThread then
		task.cancel(AbilityShowcaseThread)
	end
	
	local currentCharacter = EquipmentShowcase:FindFirstChild("Character")
	local root = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
	local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
	local weapon = currentCharacter and currentCharacter:FindFirstChild("EquippedWeapon") :: Model?
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track ~= ExistingRunningTrack and track ~= ExistingWeaponTrack then
			track:Stop()
		end
	end
	
	if weapon then
		weapon:ScaleTo(LastWeaponOriginScale)
	end

	AbilityShowcaseThread = task.spawn(function()
		local start = time()
		if abilityName == "Shrink" then
			if not currentCharacter or not currentCharacter:IsA("Model") then
				return
			end
			ShrinkPreviewCharacter = currentCharacter
			local targetScale = AbilityConfig.Abilities.Shrink.Scale
			local shrinkDuration = 0.25
			
			while time() - start < shrinkDuration do
				local elapsed = time() - start
				local alpha = elapsed / shrinkDuration
				
				local value = TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Quart,
					Enum.EasingDirection.Out
				)
				
				CharacterScale = math.lerp(1, targetScale, value)
				task.wait()
			end
			
			CharacterScale = targetScale
			
			task.wait(AbilityConfig.Abilities.Shrink.Duration - shrinkDuration)
		elseif abilityName == "Invisible" then
			local targetTransparency = AbilityConfig.Abilities.Invisible.Transparency
			local duration = AbilityConfig.Abilities.Invisible.Duration
			
			local shrinkTime = 0.25
			
			while time() - start < shrinkTime do
				local elapsed = time() - start
				local alpha = elapsed / shrinkTime
				CharacterTransparency = math.lerp(0, targetTransparency, alpha)
				
				task.wait()
			end
			
			CharacterTransparency = targetTransparency
			task.wait(duration - shrinkTime)
		elseif abilityName == "Dash" then
			local dashOutTime = 0.25
			local dashOutDistance = 100
			local lastHologram = 0
			local hologramDelay = 0.04
			local trackSpeed = 10
			
			SoundService:PlayLocalSound(SFXFolder.Dash)
			
			while time() - start < dashOutTime do
				local elapsed = time() - start
				local alpha = elapsed / dashOutTime
				local value = TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Exponential,
					Enum.EasingDirection.In
				)				

				if currentCharacter and time() - lastHologram >= hologramDelay then
					SpawnDashHologram(currentCharacter, 1 - alpha)
					lastHologram = time()
				end
			
				local currentTrack = ExistingRunningTrack
				if currentTrack then
					currentTrack:AdjustSpeed(1 + alpha * trackSpeed)
				end
				
				CharacterVectorOffset = Vector3.new(0, 0, -dashOutDistance * value)
				task.wait()
			end
			
			local dashInTime = 0.5
			local dashInDistance = 200
			start = time()
			
			SoundService:PlayLocalSound(SFXFolder.Complete)
					
			while time() - start < dashInTime do
				local elapsed = time() - start
				local alpha = elapsed / dashInTime
				
				local value = 1 - TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Exponential,
					Enum.EasingDirection.Out
				)

				if currentCharacter and time() - lastHologram >= hologramDelay then
					SpawnDashHologram(currentCharacter, alpha)
					lastHologram = time()
				end
				
				local currentTrack = ExistingRunningTrack
				if currentTrack then
					currentTrack:AdjustSpeed(1 + (1 - alpha) * trackSpeed)
				end
				
				CharacterVectorOffset = Vector3.new(0, 0, dashInDistance * value)
				task.wait()
			end
		elseif abilityName == "MegaJump" then
			local jumpTime = 0.5
			local jumpHeight = 65
			local fallTime = 1.5
			local cameraDistance = 30
			
			SoundService:PlayLocalSound(SFXFolder.Jump)
			
			if root then
				GameplayController.PlayVFX("JumpEffect", root.CFrame + Vector3.new(0, -2, 0))				
			end
			CameraFollowCharacter = true
			UseSmoothCameraAnimation = true
			while time() - start < jumpTime do
				local elapsed = time() - start
				local alpha = elapsed / jumpTime

				local value = TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Quart,
					Enum.EasingDirection.Out
				)
				
				CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
				CameraOffset = Vector3.new(0, 0, cameraDistance * value)
				task.wait()
			end
			
			start = time()
			
			while time() - start < fallTime do
				local elapsed = time() - start
				local alpha = elapsed / fallTime
				
				local value = 1 - TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Sine,
					Enum.EasingDirection.InOut
				)
				
				CameraOffset = Vector3.new(0, 0, cameraDistance * value)
				CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
				task.wait()
			end

			CameraOffset = Vector3.new(0, 0, 0)
			CharacterVectorOffset = Vector3.new(0, 0, 0)
			
			task.wait(0.25)
		elseif abilityName == "SpawnInvulnerability" then
			SoundService:PlayLocalSound(SFXFolder.WheelStart)
		elseif abilityName == "Smash" then
			if animator then
				local anim1Id = AbilityConfig.Abilities.Smash.M2
				local anim2Id = AbilityConfig.Abilities.Smash.DownSlam
				local impactTime = AbilityConfig.Abilities.Smash.ImpactTime
				local jumpHeight = AbilityConfig.Abilities.Smash.JumpHeight
				local hitRadius = AbilityConfig.Abilities.Smash.HitRadius
				local cameraBackDistancePeak = 25
				local cameraBackDistanceMid = 20
				local cameraRestoreTime = 2

				local anim1 = Instance.new("Animation")
				local anim2 = Instance.new("Animation")

				anim1.AnimationId = anim1Id
				anim2.AnimationId = anim2Id
				
				local track = animator:LoadAnimation(anim1)

				track.Priority = Enum.AnimationPriority.Action2
				
				while track.Length == 0 do
					task.wait()
				end

				start = time()
				track:Play()
				SmashEffect.Dive(CharPos.Position)
				SmashEffect.Takeoff(CharPos.Position)

				CameraFollowCharacter = true
				UseSmoothCameraAnimation = true
				local charCFrame = CharPos.CFrame
				local dummyCFrame = charCFrame * CFrame.new(0, -3, 0)
				local pushDirection = (Camera.CFrame * CFrame.Angles(0, math.rad(-45), 0)).LookVector
				local dummy: Dummy.DummyType?
				while time() - start < impactTime do
					local elapsed = time() - start
					local alpha = elapsed / impactTime

					if alpha <= 0.7 then
						alpha = alpha / 0.7
					else
						alpha = 1 - (alpha - 0.7) / 0.3
					end
					
					local value = TweenService:GetValue(
						alpha,
						Enum.EasingStyle.Exponential,
						Enum.EasingDirection.Out
					)

					local distance = 0

					if alpha <= 0.7 then
						distance = cameraBackDistancePeak * value
					else
						if not dummy then
							dummy = Dummy.new(dummyCFrame)							
							SmashEffect.StartTelegraph(LocalPlayer, currentCharacter)
						end
						distance = math.lerp(cameraBackDistanceMid, cameraBackDistancePeak, value)
					end
					
					CameraOffset = Vector3.new(0, 0, distance)
					CharacterVectorOffset = Vector3.new(0, jumpHeight * value, 0)
					task.wait()
				end

				if dummy then
					dummy:Push(pushDirection, 30, 30)
				end
				start = time()
				SmashEffect.Impact(currentCharacter:GetPivot().Position + Vector3.new(0, -8, 0), hitRadius)
				CameraOffset = Vector3.new(0, 0, cameraBackDistanceMid)
				CharacterVectorOffset = Vector3.new(0, 0, 0)
				CameraFollowCharacter = false
				SmashEffect.StopTelegraph(LocalPlayer)
				while time() - start < cameraRestoreTime do
					local elapsed = time() - start
					local alpha = elapsed / cameraRestoreTime

					local value = 1 - TweenService:GetValue(
						alpha,
						Enum.EasingStyle.Exponential,
						Enum.EasingDirection.Out
					)					
					
					CameraOffset = Vector3.new(0, 0, cameraBackDistanceMid * value)
					task.wait()
				end
				
			end
		elseif abilityName == "Charge" then
			local config = AbilityConfig.Abilities.Charge
			local duration = config.Duration
			local runningAnim = config.Animation
			local dashOutTime = 0.75
			local dashOutDistance = 100
			local lastHologram = 0
			local hologramDelay = 0.04
			local trackSpeed = 5
			local dashInTime = 1.5
			local dashInDistance = 200

			local anim = Instance.new("Animation")
			anim.AnimationId = `rbxassetid://{runningAnim}`
			local track = animator:LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Movement

			while track.Length == 0 do
				task.wait()
			end
			
			if ExistingRunningTrack then
				ExistingRunningTrack:Stop()
			end

			if ExistingWeaponTrack then
				ExistingWeaponTrack:Stop()
			end

			track:Play()

			start = time()

			ChargeEffect.Start(Players.LocalPlayer, currentCharacter, duration)
			while time() - start < dashOutTime do
				local elapsed = time() - start
				local alpha = elapsed / dashOutTime
				local value = TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Exponential,
					Enum.EasingDirection.In
				)				

				if currentCharacter and time() - lastHologram >= hologramDelay then
					SpawnDashHologram(currentCharacter, 1 - alpha)
					lastHologram = time()
				end
			
				local currentTrack = track
				if currentTrack then
					currentTrack:AdjustSpeed(1 + alpha * trackSpeed)
				end
				
				CharacterVectorOffset = Vector3.new(0, 0, -dashOutDistance * value)
				task.wait()
			end
			
			local x, y, z = currentCharacter:GetPivot():ToEulerAnglesXYZ()
			local dummy = Dummy.new(CharPos.CFrame * CFrame.Angles(x, y, z) * CFrame.new(0, -3, 10))
			start = time()
			SoundService:PlayLocalSound(SFXFolder.Complete)
					
			while time() - start < dashInTime do
				local elapsed = time() - start
				local alpha = elapsed / dashInTime
				
				local value = 1 - TweenService:GetValue(
					alpha,
					Enum.EasingStyle.Linear,
					Enum.EasingDirection.In
				)

				if currentCharacter and time() - lastHologram >= hologramDelay then
					SpawnDashHologram(currentCharacter, alpha)
					lastHologram = time()
				end
				
				local currentTrack = track
				if currentTrack then
					currentTrack:AdjustSpeed(1 + (1 - alpha) * trackSpeed)
				end
				
				CharacterVectorOffset = Vector3.new(0, 0, dashInDistance * value)
				task.wait()
			end

			track:Stop()

			if ExistingWeaponTrack then
				ExistingWeaponTrack:Play()
			end
			if ExistingRunningTrack then
				ExistingRunningTrack:AdjustSpeed(1)
				ExistingRunningTrack:Play()
			end
			
			dummy:Push(currentCharacter:GetPivot().LookVector, 50, 10)
			ChargeEffect.Impact(LocalPlayer, CharPos.Position)
			ChargeEffect.ChargerHit(10)
			ChargeEffect.Stop(Players.LocalPlayer)
			CharacterVectorOffset = Vector3.zero
			CameraFollowCharacter = false
			UseSmoothCameraAnimation = true

			local trackTime = 1
			start = time()

			while time() - start < trackTime do
				task.wait()
				local model = dummy and dummy.Model
				local cFrame = model and model:GetPivot()

				if cFrame then
					CustomFollowPosition = cFrame.Position
				else
					CustomFollowPosition = nil
				end
			end

			CustomFollowPosition = nil
			task.wait(1)
		elseif abilityName == "Throw" then			
			local animId = `rbxassetid://{AbilityConfig.Abilities.Throw.Animation}`
			local anim = Instance.new("Animation")
			anim.AnimationId = animId

			local throwDuration = 3

			local track = animator:LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action2

			while track.Length == 0 do
				task.wait()	
			end

			start = time()

			track:Play()
			
			if ExistingWeaponTrack then
				ExistingWeaponTrack:Stop()
			end

			task.wait(0.5)

			if currentCharacter and root and root:IsA("BasePart") then
				local config = AbilityConfig.Abilities.Throw
				local forward = root.CFrame.LookVector
				forward = Vector3.new(forward.X, 0, forward.Z)
				if forward.Magnitude > 0.01 then
					forward = forward.Unit
				else
					forward = Vector3.zAxis
				end

				local hand = currentCharacter:FindFirstChild("RightHand") or currentCharacter:FindFirstChild("Right Arm")
				local origin = if hand and hand:IsA("BasePart") then hand.Position else root.Position + Vector3.new(0, 1, 0)
				local range = config.Range or 55
				local raycastParams = RaycastParams.new()
				raycastParams.FilterType = Enum.RaycastFilterType.Exclude
				raycastParams.FilterDescendantsInstances = { EquipmentShowcase }

				local hit = workspace:Raycast(origin, forward * range, raycastParams)
				if hit then
					range = math.max(6, hit.Distance - 2)
				end

				local weapon = currentCharacter:FindFirstChild("EquippedWeapon") :: Model
				local weaponName = weapon
					and (weapon:GetAttribute("WeaponName") or weapon:GetAttribute("WeaponId"))
					or PlayerData.Get(LocalPlayer, EQUIPPED_WEAPON_ATTRIBUTE)
				if type(weaponName) ~= "string" then
					weaponName = ""
				end

				if weapon then
					weapon.Name = "EquippedWeapon"
				end
				ThrowEffect.Launch(LocalPlayer, currentCharacter, {
					origin = origin,
					forward = forward,
					range = range,
					curve = math.min(config.Curve or 12, range * 0.3),
					outTime = config.OutTime or 0.55,
					hoverTime = config.HoverTime or 0.3,
					returnTime = config.ReturnTime or 0.7,
					startTime = workspace:GetServerTimeNow(),
					weaponName = weaponName,
				})
				if weapon and weapon.Parent == currentCharacter then
					weapon.Name = "EquippedWeapon"
				end

			end
			
			UseSmoothCameraAnimation = true
			CameraFollowCharacter = true
			while time() - start < throwDuration do
				task.wait()
				local combatLocalEffect = workspace:FindFirstChild("CombatLocalEffects")
				local currentWeapon = combatLocalEffect and combatLocalEffect:FindFirstChild("ThrownWeapon") :: Model?

				if currentWeapon then
					CustomFollowPosition = currentWeapon:GetPivot().Position	
				else
					CustomFollowPosition = nil
				end
			end

			if ExistingWeaponTrack then
				ExistingWeaponTrack:Play()
			end
		elseif abilityName == "Pull" then
			local config = AbilityConfig.Abilities.Pull
			local releaseTime = config.ReleaseTime or 0.35

			if currentCharacter and root and root:IsA("BasePart") then
				local forward = root.CFrame.LookVector
				forward = Vector3.new(forward.X, 0, forward.Z)
				if forward.Magnitude > 0.01 then
					forward = forward.Unit
				else
					forward = Vector3.zAxis
				end

				local track: AnimationTrack? = nil
				if animator and config.Animation then
					local animation = Instance.new("Animation")
					local animationId = config.Animation
					animation.AnimationId = animationId
					local newTrack = animator:LoadAnimation(animation)
					animation:Destroy()
					newTrack.Priority = Enum.AnimationPriority.Action2

					while newTrack.Length == 0 do
						task.wait()
					end

					newTrack:Play()

					track = newTrack
				end

				if ExistingWeaponTrack then
					ExistingWeaponTrack:Stop()
				end

				PullEffect.Cast(LocalPlayer, currentCharacter, {
					aim = forward,
					range = config.Range,
					angle = config.Angle,
					releaseTime = releaseTime,
					startTime = workspace:GetServerTimeNow(),
				})

				task.wait(config.Duration or releaseTime)
				if track then
					track:Stop(0.1)
					track:Destroy()
				end
				if ExistingWeaponTrack then
					ExistingWeaponTrack:Play()
				end
			end
		elseif abilityName == "Push" then
			local config = AbilityConfig.Abilities.Push
			local releaseTime = 0.15

			if currentCharacter and root and root:IsA("BasePart") then
				local forward = root.CFrame.LookVector
				forward = Vector3.new(forward.X, 0, forward.Z)
				if forward.Magnitude > 0.01 then
					forward = forward.Unit
				else
					forward = Vector3.zAxis
				end

				local track: AnimationTrack? = nil
				if animator and config.Animation then
					local animation = Instance.new("Animation")
					local animationId = tostring(config.Animation)
					if not string.find(animationId, "rbxassetid://", 1, true) then
						animationId = `rbxassetid://{animationId}`
					end
					animation.AnimationId = animationId
					local newTrack = animator:LoadAnimation(animation)
					animation:Destroy()
					while newTrack.Length == 0 do
						task.wait()
					end
					newTrack.Priority = Enum.AnimationPriority.Action2
					newTrack:Play()

					track = newTrack
				end

				if ExistingWeaponTrack then
					ExistingWeaponTrack:Stop()
				end

				PushEffect.Cast(LocalPlayer, currentCharacter, {
					aim = forward,
					range = config.Range,
					angle = config.Angle,
					releaseTime = releaseTime,
					startTime = workspace:GetServerTimeNow(),
				})

				local charCFrame = currentCharacter:GetPivot()
				local dummyCFrame = charCFrame * CFrame.new(0, -3, -10) * CFrame.Angles(0, math.rad(180), 0)
				local pushDirection = charCFrame.LookVector
				local dummy = Dummy.new(dummyCFrame)

				task.wait(0.15)
				dummy:Push(pushDirection, 50, 20)
				if track then
					track:Stop(1)
					Debris:AddItem(track, 1.5)
				end
				if ExistingWeaponTrack then
					ExistingWeaponTrack:Play()
				end
				local trackTime = 1
				start = time()
				
				UseSmoothCameraAnimation = true
				CameraFollowCharacter = true
				while time() - start < trackTime do
					task.wait()
					local model = dummy and dummy.Model
					local cFrame = model and model:GetPivot()

					if cFrame then
						CustomFollowPosition = cFrame.Position
					else
						CustomFollowPosition = nil
					end
				end

				CustomFollowPosition = nil
				task.wait(1)
			end
		elseif abilityName == "TimeStop" then
			TimeStopPreviewActive = true
			local config = AbilityConfig.Abilities.TimeStop
			local readyTime = config.ReadyTime
			local stopDuration = config.StopDuration
			TimeStopEffect.Ready(LocalPlayer, currentCharacter, {
				readyTime = readyTime,
				soundMode = config.ReadySoundMode
			})

			local charCFrame = currentCharacter:GetPivot()
			local dummyCFrame = charCFrame * CFrame.new(0, -3, -4) * CFrame.Angles(0, math.rad(180), 0)
			local dummy = Dummy.new(dummyCFrame)
			
			while time() - start < readyTime do
				task.wait()
			end

			TimeStopEffect.Start(LocalPlayer, currentCharacter, {
				stopDuration = stopDuration,
				since = workspace:GetServerTimeNow()
			})

			local punchCount = 0
			local nextPunch = readyTime + 0.5

			while time() - start < readyTime + stopDuration do
				task.wait()
				local elapsed = time() - start

				if elapsed >= nextPunch then
					punchCount += 1
					TimeStopEffect.Mark(dummy.Model, punchCount)
					if ExistingAttackTrack then
						ExistingAttackTrack:Play()
					end
					nextPunch += 0.5 + math.random() * 0.5
				end
			end

			TimeStopEffect.End(LocalPlayer)
			TimeStopPreviewActive = false
		elseif abilityName == "BigWeapon" then
			if not weapon or not currentCharacter or not currentCharacter:IsA("Model") then
				return
			end
			local previewWeapon = weapon
			local previewCharacter = currentCharacter
			local config = AbilityConfig.Abilities.BigWeapon
			local baseScale = LastWeaponOriginScale
			local targetScale = baseScale * config.Scale
			BigWeaponPreview = { Weapon = previewWeapon, BaseScale = baseScale }
			local function animateScale(fromScale: number, toScale: number, duration: number, direction: Enum.EasingDirection): boolean
				local startedAt = time()
				repeat
					if previewWeapon.Parent ~= previewCharacter or previewCharacter.Parent ~= EquipmentShowcase then
						return false
					end
					local alpha = if duration > 0 then math.min((time() - startedAt) / duration, 1) else 1
					local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, direction)
					ScalePreviewWeapon(previewWeapon, math.lerp(fromScale, toScale, eased))
					if alpha >= 1 then
						return true
					end
					task.wait()
				until false
			end

			UseSmoothCameraAnimation = true
			CameraOffset = Vector3.new(0, 0, 10)
			local grew = animateScale(baseScale, targetScale, config.GrowTime, Enum.EasingDirection.Out)

			while grew and previewWeapon.Parent == previewCharacter and previewCharacter.Parent == EquipmentShowcase
				and time() - start < config.Duration do
				task.wait()
			end
			CameraOffset = Vector3.new(0, 0, 0)

			if grew then
				animateScale(targetScale, baseScale, config.ShrinkTime, Enum.EasingDirection.InOut)
			end
			if previewWeapon.Parent then
				ScalePreviewWeapon(previewWeapon, baseScale)
			end

			task.wait(1)
		end

		-- Restore everything to default
		CharacterVectorOffset = Vector3.zero
		CharacterScale = 1
		if ShrinkPreviewCharacter then
			if ShrinkPreviewCharacter.Parent then
				ApplyPreviewCharacterScale(ShrinkPreviewCharacter, 1)
			end
			ShrinkPreviewCharacter = nil
		end
		CharacterTransparency = 0
		CameraFollowCharacter = false
		UseSmoothCameraAnimation = false
		CameraOffset = Vector3.zero
		CustomFollowPosition = nil
		ChargeEffect.Stop(Players.LocalPlayer)
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			if track ~= ExistingRunningTrack and track ~= ExistingWeaponTrack then
				track:Stop()
			end
		end
		
		if ExistingWeaponTrack then
			ExistingWeaponTrack:Play()
		end
		if ExistingRunningTrack then
			ExistingRunningTrack:AdjustSpeed(1)
			ExistingRunningTrack:Play()
		end
		if weapon then
			weapon:ScaleTo(LastWeaponOriginScale)
		end
		Dummy.DestroyAll()
		BigWeaponPreview = nil
	end)
end

function Controller.UpdateAbilityPurchase()
	local abilityName = SelectedAbility
	local config = if abilityName then AbilityConfig.Abilities[abilityName] else nil
	local price = config and config.Price
	local owned = abilityName ~= nil and table.find(GetOwnedAbilites(), abilityName) ~= nil
	local ready = PlayerData.Get(LocalPlayer, "DataLoaded") == true
	local pending = AbilityPurchasePending or PlayerData.Get(LocalPlayer, "SimpleCheckoutPending") == true
		or ((not price or price.IsRobux ~= true or RobuxShopConfig.CheckoutMode ~= "Simple")
			and PlayerData.Get(LocalPlayer, "ManagedCheckoutPending") == true)
	local canBuy = false
	PriceFrame.Visible = not owned
	PriceFrame.Icon.Visible = price ~= nil and price.IsRobux ~= true
	PriceFrame.Price.Text = "OFF-SALE"


	if price and not config.Unlisted then
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
			local coins = tonumber(PlayerData.Get(LocalPlayer, COINS_ATTRIBUTE)) or 0
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
		StopTimeStopPreview()
		StopShrinkPreview()
		StopBigWeaponPreview()
	else
		NotifyFrame.Visible = false
	end
	EquipmentShowcase.Parent = enabled and workspace or nil
	IsEnabled = enabled
	PlayerData.SetLocal(LocalPlayer, "OpenedEquipment", enabled)
	if enabled then
		LastEnabled = time()
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
				TweenService:Create(EquipmentFrame.ExitButton, TweenInfo.new(0), {Position = UDim2.new(1.5, 0, 0.1, 30)}),
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
				TweenService:Create(EquipmentFrame.ExitButton, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Position = UDim2.new(1, 0, 0.1, 30)}),
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
					EquipWeaponEvent:FireServer(item)
				end
			end)
		end
	end
	
	-- Load the list of abilities
	for ability, data: AbilityConfig.AbilityConfig in pairs(AbilityConfig.Abilities) do
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
		StopTimeStopPreview()
		StopShrinkPreview()
		StopBigWeaponPreview()
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
	BuyButton.Activated:Connect(Controller.PurchaseAbility)
	for _, attribute in ipairs({ COINS_ATTRIBUTE, "DataLoaded", "ManagedCheckoutPending", "SimpleCheckoutPending" }) do
		PlayerData.Observe(LocalPlayer, attribute, Controller.UpdateAbilityPurchase)
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
	
	PlayerData.Observe(LocalPlayer, OWNED_WEAPONS_ATTRIBUTE, function()
		Controller.UpdateItemStates()
	end)
	
	PlayerData.Observe(LocalPlayer, EQUIPPED_WEAPON_ATTRIBUTE, function()
		Controller.UpdateEquipState()
	end)
	
	PlayerData.Observe(LocalPlayer, OWNED_ABILITY_ATTRIBUTE, function()
		Controller.UpdateItemStates()
		Controller.UpdateAbilityPurchase()
	end)
	
	PlayerData.Observe(LocalPlayer, EQUIPPED_ABILITY_ATTRIBUTE, function()
		Controller.UpdateEquipState()
	end)

	PlayerData.Observe(LocalPlayer, COINS_ATTRIBUTE, function()
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
		PlayerData.Observe(LocalPlayer, OWNED_ABILITY_ATTRIBUTE, function()
			NotifyFrame.Visible = true
		end)

		PlayerData.Observe(LocalPlayer, OWNED_ABILITY_ATTRIBUTE, function()
			NotifyFrame.Visible = true			
		end)
	end)
	
	--// Default setup
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
		local ready = PlayerData.Get(LocalPlayer, "DataLoaded") == true
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
