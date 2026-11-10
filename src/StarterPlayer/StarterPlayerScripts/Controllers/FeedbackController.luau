local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local workspace = game:GetService("Workspace")
local MailboxPart = workspace:WaitForChild("Lobby"):WaitForChild("Mailbox"):WaitForChild("MailboxPart")
local ProximityPrompt = MailboxPart:WaitForChild("ProximityPrompt")

local FeedbackController = {}

function FeedbackController.Init()
	ProximityPrompt.Triggered:Connect(function()
		local success, errorMessage = pcall(function()
			SocialService:PromptFeedbackSubmissionAsync({FeedbackType = Enum.FeedbackType.Feedback})
		end)
	
		if not success then
			warn("Feedback prompt failed to open: " .. errorMessage)
		end
	end)	
end

return FeedbackController