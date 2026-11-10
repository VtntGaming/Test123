--!strict
--// Services
local StarterPlayer = game:GetService("StarterPlayer")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
--// Modules
local ShopController = require(script.Parent.RobuxShopController)
--// Variables
local ShopFrame
local LocalPlayer = Players.LocalPlayer


local function OpenKaidoShop()
    local listing = ShopFrame.CanvasGroup.Listing :: ScrollingFrame
    local limitedItem = listing.Exclusive.LimitedItem :: Frame

    ShopController:ToggleEnabled(true)
    -- Wait for the shop's 0.35s opening scale tween before measuring positions.
    task.delay(0.4, function()
        if not ShopFrame.Visible or not ShopController.IsEnabled then
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

local module = {}
function module.Init()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    ShopFrame = playerGui:WaitForChild("MainGui"):WaitForChild("RobuxShopFrame")

    local kaidoItem = workspace.Lobby.Kaido :: Model
    local part = Instance.new("Part")
    part.CanCollide = false
    part.CanTouch = false
    part.CastShadow = false
    part.Anchored = true
    part.Transparency = 1
    part.Size = Vector3.zero
    part.CFrame = kaidoItem:GetPivot()
    part.Parent = kaidoItem

    local prompt = Instance.new("ProximityPrompt")
    prompt.HoldDuration = 0.25
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 15
    prompt.ActionText = "Kaido Hammer"
    prompt.Parent = part

    prompt.Triggered:Connect(function(a0: Player) 
        OpenKaidoShop()
    end)

    do -- kaido movement
        local numValue = Instance.new("NumberValue")
        numValue.Value = 0
        numValue.Parent = script

        local originCFrame = kaidoItem:GetPivot()
        numValue.Changed:Connect(function(num) 
            kaidoItem:PivotTo(originCFrame + Vector3.yAxis*num)
        end)

        local tween = TweenService:Create(numValue, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
            Value = 2.5
        })
        tween:Play()
    end
end

return module