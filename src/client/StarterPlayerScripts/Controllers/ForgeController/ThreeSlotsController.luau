--!strict

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--// Modules
local ForgeStates = require(script.Parent.ForgeStates)
local GhostItem = require(script.Parent.GhostItem)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)
local Signal = require(ReplicatedStorage.Utils.Signal)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainGui = PlayerGui:WaitForChild("MainGui")
local ForgeFrame = MainGui:WaitForChild("ForgeFrame")
local InventoryList = ForgeFrame.ScrollHolder.ScrollingFrame
local ItemTemplate = InventoryList.Template
local ThreeSlots = ForgeFrame["3Slots"]
local SlotFrames = {
	ThreeSlots.Slot1,
	ThreeSlots.Slot2 :: any,
	ThreeSlots.Slot3 :: any,
} :: {SlotFrameType}

--// Constants
local ROTATION_TIME = 60
local SIZING_TIME = 4
local SLOT_DIRECTIONS = {
	Vector2.new(0, 0.35),
	Vector2.new(0.3, -0.175),
	Vector2.new(-0.3, -0.175),
}

--// Types
type WeaponInfo = WeaponConfig.WeaponInfo
type SlotFrameType = typeof(ThreeSlots.Slot1)

export type ThreeSlotsController = {
	-- Properties
	Connections: { RBXScriptConnection },
	OwnedInstances: { Instance },
	Tweens: { Tween },
	RotationElapsed: number,
	SizingElapsed: number,
	LastDrop: number,
	Started: boolean,
	Destroyed: boolean,
	SlotChanged: Signal.Signal<>,
	-- Methods
	Setup: (self: ThreeSlotsController) -> (),
	Start: (self: ThreeSlotsController) -> (),
	Reset: (self: ThreeSlotsController) -> (),
	DropIntoSlot: (self: ThreeSlotsController, targetIndex: number, weaponName: string, sourceIndex: number?) -> (),
	DropIntoAnySlot: (self: ThreeSlotsController, weaponName: string) -> (),
	EndDrag: (self: ThreeSlotsController, input: InputObject) -> (),
	ClearSlotVisually: (self: ThreeSlotsController,slot: GuiObject) -> (),
}

--// Controller
local Controller = {} :: ThreeSlotsController

local function GetWeaponInfo(weaponName: string): WeaponInfo
	local weaponInfo = WeaponConfig.GetWeaponInfo(weaponName)
	assert(weaponInfo, `No weapon info exists for "{weaponName}"`)
	return weaponInfo
end

local function RemoveOwnedInstance(self: ThreeSlotsController, instance: Instance)
	local instanceIndex = table.find(self.OwnedInstances, instance)
	if instanceIndex then
		table.remove(self.OwnedInstances, instanceIndex)
	end
end

local function ShowErrorFeedback(self: ThreeSlotsController, slot: GuiObject, message: string)
	local flashTween = TweenService:Create(
		slot,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
		{ BackgroundColor3 = Color3.fromRGB(255, 50, 50) }
	)
	table.insert(self.Tweens, flashTween)
	flashTween:Play()

	local feedbackLabel: TextLabel = Instance.new("TextLabel")
	table.insert(self.OwnedInstances, feedbackLabel)
	feedbackLabel.Parent = slot
	feedbackLabel.Size = UDim2.new(1.5, 0, 0.4, 0)
	feedbackLabel.Position = UDim2.fromScale(0.5, 0.5)
	feedbackLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	feedbackLabel.BackgroundTransparency = 1
	feedbackLabel.Text = message
	feedbackLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
	feedbackLabel.Font = Enum.Font.LuckiestGuy
	feedbackLabel.TextScaled = true
	feedbackLabel.ZIndex = 10

	local fadeTween = TweenService:Create(
		feedbackLabel,
		TweenInfo.new(0.8, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
		{
			Position = UDim2.fromScale(0.5, -0.5),
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}
	)
	table.insert(self.Tweens, fadeTween)
	fadeTween:Play()
	local completedConnection: RBXScriptConnection
	completedConnection = fadeTween.Completed:Connect(function()
		feedbackLabel:Destroy()
		RemoveOwnedInstance(self, feedbackLabel)

		local fadeTweenIndex = table.find(self.Tweens, fadeTween)
		if fadeTweenIndex then
			table.remove(self.Tweens, fadeTweenIndex)
		end

		local flashTweenIndex = table.find(self.Tweens, flashTween)
		if flashTweenIndex then
			table.remove(self.Tweens, flashTweenIndex)
		end

		local connectionIndex = table.find(self.Connections, completedConnection)
		if connectionIndex then
			table.remove(self.Connections, connectionIndex)
		end
		completedConnection:Disconnect()
	end)
	table.insert(self.Connections, completedConnection)
end

function Controller:ClearSlotVisually(slot: GuiObject)
	local icon: Instance? = slot:FindFirstChild("Icon")
	if icon then
		icon:Destroy()
		RemoveOwnedInstance(self, icon)
	end

	local slotTitle: Instance? = slot:FindFirstChild("SlotTitle")
	if slotTitle then
		slotTitle:Destroy()
		RemoveOwnedInstance(self, slotTitle)
	end

	local stroke: UIStroke? = slot:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Color3.fromRGB(150, 150, 150)
	end

	local emptyText: Instance? = slot:FindFirstChild("EmptyText")
	if emptyText and emptyText:IsA("GuiObject") then
		emptyText.Visible = true
	end
end

local function UpdateSlotVisually(self: ThreeSlotsController, slot: GuiObject, weaponName: string?)
	self:ClearSlotVisually(slot)
	if not weaponName then
		return
	end

	local emptyText: Instance? = slot:FindFirstChild("EmptyText")
	if emptyText and emptyText:IsA("GuiObject") then
		emptyText.Visible = false
	end

	local weaponInfo: WeaponInfo = GetWeaponInfo(weaponName)
	local templateIcon: Instance? = ItemTemplate:FindFirstChild("Icon")
	if templateIcon and templateIcon:IsA("ImageLabel") then
		local icon: ImageLabel = templateIcon:Clone()
		table.insert(self.OwnedInstances, icon)
		icon.Parent = slot
		icon.Image = weaponInfo.Icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ImageTransparency = 0
		icon.ZIndex = 3
		icon.Visible = true
	end

	local templateTitle: Instance? = ItemTemplate:FindFirstChild("Title")
	if templateTitle and templateTitle:IsA("TextLabel") then
		local title: TextLabel = templateTitle:Clone()
		table.insert(self.OwnedInstances, title)
		title.Name = "SlotTitle"
		title.Parent = slot
		title.Text = weaponInfo.DisplayName
		title.TextColor3 = weaponInfo.RarityColor
		title.Font = Enum.Font.LuckiestGuy
		title.ZIndex = 4
		title.Visible = true
	end

	local existingStroke: UIStroke? = slot:FindFirstChildOfClass("UIStroke")
	local stroke: UIStroke = existingStroke or Instance.new("UIStroke")
	if not existingStroke then
		table.insert(self.OwnedInstances, stroke)
	end
	stroke.Parent = slot
	stroke.Color = weaponInfo.RarityColor
	stroke.Thickness = 2
end

--// APIs
function Controller:Setup()
	self.Connections = {}
	self.OwnedInstances = {}
	self.Tweens = {}
	self.RotationElapsed = 0
	self.SizingElapsed = 0
	self.LastDrop = 0
	self.Started = false
	self.Destroyed = false
	self.SlotChanged = Signal.new()

	local slotFrames = SlotFrames
	if self.Destroyed or not slotFrames then
		return
	end

	for _, slot in ipairs(slotFrames) do
		if slot:FindFirstChild("EmptyText") then
			continue
		end

		local emptyText: TextLabel = Instance.new("TextLabel")
		emptyText.Parent = slot
		table.insert(self.OwnedInstances, emptyText)
		emptyText.Name = "EmptyText"
		emptyText.Size = UDim2.fromScale(0.8, 0.6)
		emptyText.Position = UDim2.fromScale(0.5, 0.5)
		emptyText.AnchorPoint = Vector2.new(0.5, 0.5)
		emptyText.BackgroundTransparency = 1
		emptyText.Text = "Drag\nWeapon"
		emptyText.TextColor3 = Color3.fromRGB(180, 180, 180)
		emptyText.TextTransparency = 0.5
		emptyText.Font = Enum.Font.LuckiestGuy
		emptyText.TextScaled = true
		emptyText.ZIndex = 2
	end
end

function Controller:Start()
	if self.Started or self.Destroyed then
		return
	end
	local threeSlots = ThreeSlots
	local slotFrames = SlotFrames
	if not threeSlots or not slotFrames then
		return
	end
	self.Started = true

	for index, slot in ipairs(slotFrames) do
		table.insert(self.Connections, slot.InputBegan:Connect(function(input: InputObject)
			if ForgeStates.GhostItem then
				return
			end

			if ForgeStates.ThreeSlotStatus.IsAnimating then
				return
			end

			local weaponName: string? = ForgeStates.ActiveSlots[index]
			local isDragInput: boolean = input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			if not weaponName or not isDragInput then
				return
			end

			ForgeStates.DragSource = index

			local ghostItem = GhostItem.new(weaponName)
			ghostItem.Created:Connect(function()
				ForgeStates.GhostItem = ghostItem
			end)
			ghostItem.Released:Connect(function()
				if ForgeStates.GhostItem == ghostItem then
					ForgeStates.GhostItem = nil
				end
			end)
			ghostItem:CreateGhost(slot, input.Position, "Slot")

			ForgeStates.ActiveSlots[index] = nil

			self.SlotChanged:Fire()
			self:ClearSlotVisually(slot)
		end))
	end

	table.insert(self.Connections, RunService.Heartbeat:Connect(function(deltaTime: number)
		local threeSlotStatus = ForgeStates.ThreeSlotStatus
		self.RotationElapsed += deltaTime * threeSlotStatus.RotationSpeed
		self.SizingElapsed += deltaTime * threeSlotStatus.ScaleSpeed

		local progress = (self.RotationElapsed % ROTATION_TIME) / ROTATION_TIME
		local rotation = progress * 360
		threeSlots.Rotation = rotation
		for _, slot in ipairs(slotFrames) do
			slot.Rotation = 360 - rotation
		end

		local scaleProgress = (self.SizingElapsed % SIZING_TIME) / SIZING_TIME
		if scaleProgress <= 0.5 then
			scaleProgress /= 0.5
		else
			scaleProgress = 1 - (scaleProgress - 0.5) / 0.5
		end

		local scaleValue = TweenService:GetValue(scaleProgress, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local scale = math.lerp(0.9, 1.15, scaleValue) * threeSlotStatus.ScaleMultiplier
		threeSlots.Center.UIScale.Scale = scale

		for index, slot in ipairs(slotFrames) do
			local position = Vector2.new(0.5, 0.5) + SLOT_DIRECTIONS[index] * scale
			slot.Position = UDim2.fromScale(position.X, position.Y)
		end
	end))
end

function Controller:Reset()
	local slotFrames = SlotFrames
	if self.Destroyed or not slotFrames then
		return
	end
	for index, slot in ipairs(slotFrames) do
		ForgeStates.ActiveSlots[index] = nil
		self:ClearSlotVisually(slot)
	end

	self.SlotChanged:Fire()
end

function Controller:DropIntoSlot(targetIndex: number, weaponName: string, sourceIndex: number?)
	local slotFrames = SlotFrames
	if self.Destroyed or not slotFrames then
		return
	end
	if time() - self.LastDrop < 0.01 then
		return
	end
	self.LastDrop = time()

	local targetSlot = slotFrames[targetIndex]
	assert(targetSlot, `Invalid forge slot index: {targetIndex}`)

	local weaponInfo: WeaponInfo = GetWeaponInfo(weaponName)
	for index = 1, #slotFrames do
		local slotWeaponName: string? = ForgeStates.ActiveSlots[index]
		if slotWeaponName
			and index ~= targetIndex
			and index ~= sourceIndex
			and GetWeaponInfo(slotWeaponName).BaseName ~= weaponInfo.BaseName
		then
			ShowErrorFeedback(self, targetSlot, "Incompatibile!")
			if sourceIndex then
				ForgeStates.ActiveSlots[sourceIndex] = weaponName
				UpdateSlotVisually(self, slotFrames[sourceIndex], weaponName)
			end
			return
		end
	end

	ForgeStates.ActiveSlots[targetIndex] = weaponName
	UpdateSlotVisually(self, targetSlot, weaponName)
	self.SlotChanged:Fire()
end

function Controller:DropIntoAnySlot(weaponName: string)
	local slotFrames = SlotFrames
	if self.Destroyed or not slotFrames then
		return
	end
	for index = 1, #slotFrames do
		if not ForgeStates.ActiveSlots[index] then
			self:DropIntoSlot(index, weaponName)
			return
		end
	end
end

function Controller:EndDrag(input: InputObject)
	local slotFrames = SlotFrames
	if self.Destroyed or not slotFrames then
		return
	end
	local ghostItem = ForgeStates.GhostItem
	if not ghostItem then
		return
	end
	local draggingName = ghostItem.ItemName

	local isReleaseInput: boolean = input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	if not isReleaseInput then
		return
	end

	local targetSlot: GuiObject? = nil
	if input.UserInputState ~= Enum.UserInputState.Cancel then
		local guiObjects: { GuiObject } = PlayerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)
		for _, guiObject in ipairs(guiObjects) do
			if table.find(slotFrames, guiObject :: any) then
				targetSlot = guiObject
				break
			elseif guiObject.Parent
				and guiObject.Parent:IsA("GuiObject")
				and table.find(slotFrames, guiObject.Parent :: any)
			then
				targetSlot = guiObject.Parent
				break
			end
		end
	end

	if targetSlot then
		local targetIndex: number? = table.find(slotFrames, targetSlot :: any)
		assert(targetIndex, "Drop target is not one of the forge slots")
		self:DropIntoSlot(targetIndex, draggingName, ForgeStates.DragSource)
	else
		self.SlotChanged:Fire()
	end

	ghostItem:Destroy()
	ForgeStates.DragSource = nil
end

return Controller
