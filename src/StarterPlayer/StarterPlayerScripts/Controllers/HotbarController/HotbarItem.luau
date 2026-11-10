--!strict
-- Displays an owned chest stack and equips it using its reserved hotbar shortcut.
--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--// Modules
local ChestCatalog = require(ReplicatedStorage.SharedModules.ChestCatalog)
local Signal = require(ReplicatedStorage.Utils.Signal)

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer.PlayerGui
local MainUI = PlayerGui:WaitForChild("MainGui") :: ScreenGui & {
    HUD: Frame & {
        Hotbar: Frame & {
            Template: Frame & {
                Item: ImageButton & { Icon: ImageLabel, Keybind: TextLabel, Amount: TextLabel },
                UIScale: UIScale,
            },
        },
    },
}
local HotbarFrame = MainUI.HUD.Hotbar
local Template = HotbarFrame.Template

--// Constants
local KEYCODES = {
    Enum.KeyCode.One,
    Enum.KeyCode.Two,
    Enum.KeyCode.Three,
    Enum.KeyCode.Four,
    Enum.KeyCode.Five,
    Enum.KeyCode.Six,
    Enum.KeyCode.Seven,
    Enum.KeyCode.Eight,
    Enum.KeyCode.Nine,
    Enum.KeyCode.Zero,
}

--// Types
export type FrameType = typeof(Template)

export type HotbarItem = {
    __index: HotbarItem,
    Frame: FrameType,
    ItemName: string,
    Count: number,
    Keybind: Enum.KeyCode?,
    Connections: {[string]: RBXScriptConnection},
    Activated: Signal.Signal<string>,
    new: (itemName: string) -> (HotbarItem),
    Start: (self: HotbarItem) -> (),
    SetCount: (self: HotbarItem, count: number) -> (),
    SetKeybind: (self: HotbarItem, num: number) -> (),
    GetTool: (self: HotbarItem) -> (Tool?),
    Destroy: (self: HotbarItem) -> (),
}

local Item = {} :: HotbarItem
Item.__index = Item
Item.Activated = Signal.new()

function Item.new(itemName)
    local self = setmetatable({}, Item) :: HotbarItem

    local data = ChestCatalog.Get(itemName)
    local iconImage = if data then data.Thumbnail else ""
    local frame = Template:Clone()
    frame.Item.Icon.Image = iconImage
    frame.Name = itemName
    frame.LayoutOrder = if data then -data.Order else 0
    frame.Parent = HotbarFrame
    frame.Visible = true

    self.ItemName = itemName
    self.Frame = frame
    self.Count = 0
    self.Connections = {}

    self:Start()

    return self
end

function Item:Start()
    self.Connections.OnButtonActive = self.Frame.Item.Activated:Connect(function()
        self.Activated:Fire(self.ItemName)
    end)

    local scale = self.Frame.UIScale

    self.Connections.KeyCodeActivated = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if input.KeyCode == self.Keybind and not gameProcessed and not UserInputService:GetFocusedTextBox() then
            self.Activated:Fire(self.ItemName)
            TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Scale = 0.85}):Play()
        end
    end)

    self.Connections.KeyCodeDeactivated = UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == self.Keybind then
            TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
        end
    end)
end

function Item:SetCount(count)
    local amountDisplay = self.Frame.Item.Amount
    amountDisplay.Visible = count > 1
    amountDisplay.Text = `x<font size="20">{count}</font>`
    self.Count = count
end

function Item:GetTool()
    local backpack = LocalPlayer:WaitForChild("Backpack")
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and tool:GetAttribute("ChestName") == self.ItemName then
            return tool
        end
    end
    return nil
end

function Item:SetKeybind(num)
    local keybind = KEYCODES[num]
    self.Keybind = keybind
    self.Frame.Visible = true
    self.Frame.Item.Keybind.Visible = keybind ~= nil

    if keybind then
        self.Frame.Item.Keybind.Text = tostring((num) % 10)
    end
end

function Item:Destroy()
    self.Frame:Destroy()

    for _, conn in pairs(self.Connections) do
        conn:Disconnect()
    end

    table.clear(self)
end

return Item
