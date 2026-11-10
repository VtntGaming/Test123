local CommandController = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NotificationUtil = require(ReplicatedStorage.Utils.NotificationUtil) -- adjust path as needed

local ShowNotificationEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("ShowNotificationEvent")

function CommandController.Init()
	ShowNotificationEvent.OnClientEvent:Connect(function(notifType: string, message: string)
		
		NotificationUtil.Show(notifType, message)
	end)
end

return CommandController