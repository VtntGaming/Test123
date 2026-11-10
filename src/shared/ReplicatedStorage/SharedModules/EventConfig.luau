--!strict
-- ReplicatedStorage.Configs.EventConfig
local SocialService = game:GetService("SocialService")

local EventConfig = {}

EventConfig.EventId = "657202668338545298"    

function EventConfig.FormatCountdown(seconds: number): string
	if seconds <= 0 then
		return "Event started!"
	end

	local days    = math.floor(seconds / 86400)
	local hours   = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs    = math.floor(seconds % 60)

	return string.format("%dd %dh %dm %ds", days, hours, minutes, secs)
end

-- Returns a real boolean, not the raw Enum.
function EventConfig.IsRsvped(): boolean
	local success, result = pcall(function()
		return SocialService:GetEventRsvpStatusAsync(EventConfig.EventId)
	end)

	if not success then
		warn("[EventConfig] Failed to get RSVP status: " .. tostring(result))
		return false
	end

	return result == Enum.RsvpStatus.Going
end

return EventConfig