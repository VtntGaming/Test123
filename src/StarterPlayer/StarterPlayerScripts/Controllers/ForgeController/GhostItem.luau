--!strict
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local Signal = require(ReplicatedStorage.Utils.Signal)
local WeaponConfig = require(ReplicatedStorage.SharedModules.WeaponConfig)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local MainGui = LocalPlayer.PlayerGui:WaitForChild("MainGui")
local ForgeFrame = MainGui:WaitForChild("ForgeFrame")
local InventoryList = ForgeFrame.ScrollHolder.ScrollingFrame
local ItemTemplate = InventoryList.Template

--// Constants
local DRAG_Y_OFFSET = 58
local ROTATION_RESET_DELAY = 0.1

--// Types
export type GhostSource = "Inventory" | "Slot"

export type GhostItem = {
	__index: GhostItem,
	-- Properties
	ItemName: string,
	Frame: GuiObject?,
	Created: Signal.Signal<GuiObject>,
	Released: Signal.Signal<>,
	LastMouseX: number?,
	ResetRotationTask: thread?,
	RotationTween: Tween?,
	Started: boolean,
	Destroyed: boolean,
	-- Methods
	new: (itemName: string) -> GhostItem,
	Setup: (self: GhostItem, itemName: string) -> (),
	Start: (self: GhostItem) -> (),
	CreateGhost: (self: GhostItem, sourceFrame: GuiObject, cursorPosition: Vector2 | Vector3, source: GhostSource) -> (),
	Move: (self: GhostItem, position: Vector2) -> (),
	Destroy: (self: GhostItem) -> (),
}

--// Item
local GhostItem = {} :: GhostItem
GhostItem.__index = GhostItem

local function GetWeaponInfo(itemName: string): WeaponConfig.WeaponInfo
	local weaponInfo = WeaponConfig.GetWeaponInfo(itemName)
	assert(weaponInfo, `No weapon info exists for "{itemName}"`)
	return weaponInfo
end

--// APIs
function GhostItem.new(itemName: string)
	local self = setmetatable({}, GhostItem) :: GhostItem
	self:Setup(itemName)
	self:Start()
	return self
end

function GhostItem:Setup(itemName: string)
	self.ItemName = itemName
	self.Frame = nil
	self.Created = Signal.new()
	self.Released = Signal.new()
	self.LastMouseX = nil
	self.ResetRotationTask = nil
	self.RotationTween = nil
	self.Started = false
	self.Destroyed = false
end

function GhostItem:Start()
	if self.Started or self.Destroyed then
		return
	end
	self.Started = true
end

function GhostItem:CreateGhost(sourceFrame, cursorPosition_, source)
	assert(self.Started and not self.Destroyed, "Cannot create a ghost that has not started or was destroyed")
	assert(not self.Frame, "A ghost item can only create one ghost")

	local cursorPosition = Vector2.new()
	
	if typeof(cursorPosition_) == "Vector2" then
		cursorPosition = cursorPosition_
	elseif typeof(cursorPosition_) == "Vector3" then
		cursorPosition = Vector2.new(cursorPosition_.X, cursorPosition_.Y)
	end

	local inputPosition = cursorPosition
	if source == "Inventory" then
		cursorPosition = UserInputService:GetMouseLocation()
	end

	local sourceSize = sourceFrame.AbsoluteSize
	local anchorPoint = if source == "Inventory"
		then (cursorPosition - sourceFrame.AbsolutePosition - Vector2.new(0, DRAG_Y_OFFSET)) / sourceSize
		else Vector2.new(0.5, 0.5)
	local position = if source == "Inventory"
		then cursorPosition
		else cursorPosition + Vector2.new(0, DRAG_Y_OFFSET)
	local weaponInfo = GetWeaponInfo(self.ItemName)
	local ghost = ItemTemplate:Clone()

	ghost.Active = false
	ghost.Interactable = false
	ghost.Size = UDim2.fromOffset(sourceSize.X, sourceSize.Y)
	ghost.AnchorPoint = anchorPoint
	ghost.Position = UDim2.fromOffset(position.X, position.Y)
	ghost.Parent = MainGui :: any
	ghost.ZIndex = 100
	ghost.Visible = true

	local uiScale = ghost:FindFirstChildOfClass("UIScale")
	if uiScale then
		uiScale.Scale = 1
	end

	local quantityLabel = ghost.QuantityLabel
	quantityLabel.Visible = false

	for _, descendant in ipairs(ghost:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = 101
		end
	end

	local title = ghost.Title
	title.Text = weaponInfo.DisplayName
	title.TextColor3 = weaponInfo.RarityColor
	title.Font = Enum.Font.LuckiestGuy

	local icon = ghost.Icon
	icon.Image = weaponInfo.Icon
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ImageTransparency = 0

	local stroke = ghost:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = weaponInfo.RarityColor
	end

	self.Frame = ghost
	self.LastMouseX = inputPosition.X
	self.Created:Fire(ghost)
end

function GhostItem:Move(position: Vector2)
	local frame = self.Frame
	if self.Destroyed or not frame then
		return
	end

	frame.Position = UDim2.fromOffset(position.X, position.Y + DRAG_Y_OFFSET)

	local deltaX = 0
	local lastMouseX = self.LastMouseX
	if lastMouseX then
		deltaX = position.X - lastMouseX
	end
	self.LastMouseX = position.X

	if self.RotationTween then
		self.RotationTween:Cancel()
	end
	local rotationTween = TweenService:Create(
		frame,
		TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Rotation = math.clamp(deltaX * 1.5, -15, 15) }
	)
	self.RotationTween = rotationTween
	rotationTween:Play()

	local resetRotationTask = self.ResetRotationTask
	if resetRotationTask then
		task.cancel(resetRotationTask)
	end
	self.ResetRotationTask = task.delay(ROTATION_RESET_DELAY, function()
		self.ResetRotationTask = nil
		local currentFrame = self.Frame
		if self.Destroyed or not currentFrame then
			return
		end

		if self.RotationTween then
			self.RotationTween:Cancel()
		end
		local rotationTween = TweenService:Create(
			currentFrame,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Rotation = 0 }
		)
		self.RotationTween = rotationTween
		rotationTween:Play()
	end)
end

function GhostItem:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true

	local resetRotationTask = self.ResetRotationTask
	if resetRotationTask then
		task.cancel(resetRotationTask)
		self.ResetRotationTask = nil
	end

	local rotationTween = self.RotationTween
	if rotationTween then
		rotationTween:Cancel()
		self.RotationTween = nil
	end

	local frame = self.Frame
	if frame then
		frame:Destroy()
		self.Frame = nil
	end

	self.Released:Fire()
	self.Created:Destroy()
	self.Released:Destroy()
	table.clear(self)
	self.Destroyed = true
end

return GhostItem
