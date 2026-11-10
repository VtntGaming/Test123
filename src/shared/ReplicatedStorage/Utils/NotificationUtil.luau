local NotificationUtil = {}

-- ==========================================
-- SERVICES
-- ==========================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local TweenUtils = require(script.Parent.TweenUtils)

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer

local NotificationStyles = {
	Error = { Text = Color3.fromRGB(255, 38, 0), Stroke = Color3.fromRGB(0, 0, 0) },
	Warning = { Text = Color3.fromRGB(255, 251, 0), Stroke = Color3.fromRGB(0, 0, 0) },
	Success = { Text = Color3.fromRGB(0, 249, 0), Stroke = Color3.fromRGB(0, 0, 0) },
	Info = { Text = Color3.fromRGB(255, 255, 255), Stroke = Color3.fromRGB(0, 0, 0) }
}

local activeNotifications = 0

local appearInfo = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local disappearInfo = TweenInfo.new(0.5, Enum.EasingStyle.Linear)

-- ==========================================
-- FUNCTIONS
-- ==========================================

--[[
	Displays a pop-up notification on the player's screen.
	
	@param notifType string -- The style of the notification ("Success", "Error", "Warning", "Info")
	@param text string -- The message to display to the player
]]
function NotificationUtil.Show(notifType: string, text: string)
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local notificationsGui = playerGui:FindFirstChild("Notifications")
	if not notificationsGui then return end

	notificationsGui.DisplayOrder = 999

	local container = notificationsGui:FindFirstChild("Container")
	local template = container and container:FindFirstChild("Template")

	if not container or not template then return end
	template.Visible = false 

	local style = NotificationStyles[notifType] or NotificationStyles.Info

	local notification = template:Clone()
	notification.Name = "Notification"

	notification.Size = UDim2.new(1, 0, 0, 0)
	notification.TextTransparency = 1
	notification.RichText = true
	notification.Text = string.upper(text)
	notification.TextColor3 = style.Text

	local uiStroke = notification:FindFirstChildWhichIsA("UIStroke")
	if uiStroke then
		uiStroke.Color = style.Stroke
		uiStroke.Transparency = 1
	end

	activeNotifications += 1
	notification.LayoutOrder = activeNotifications

	notification.Parent = container
	notification.Visible = true

	TweenUtils.PlayTweenSequence({
		true,
		TweenService:Create(notification, appearInfo, {			
			Size = UDim2.fromScale(1, 0.1), 
			TextTransparency = 0
		}),
		true,
		TweenService:Create(uiStroke, appearInfo, {		
			Transparency = 0
		}),
		3,
		true,
		TweenService:Create(notification, disappearInfo, {	
			TextTransparency = 1
		}),
		TweenService:Create(uiStroke, disappearInfo, {		
			Transparency = 1
		}),
		function()
			notification:Destroy()
		end
	})
end

return NotificationUtil