local NextUpdateController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")

local lobby = workspace:WaitForChild("Lobby") :: Folder
local billboard = lobby:WaitForChild("Meshes"):WaitForChild("Props"):WaitForChild("Billboard") :: MeshPart
local billboardNextUpdateSurfaceGui = billboard:WaitForChild("Part"):WaitForChild("NextUpdateUI") :: SurfaceGui
local billboardNextUpdateProximityPrompt = billboard:WaitForChild("Part"):WaitForChild("Attachment"):WaitForChild("ProximityPrompt") :: ProximityPrompt

local EventConfig = require(game.ReplicatedStorage.SharedModules.EventConfig)
local EVENT_ID = EventConfig.EventId
-- ==========================================
-- STATE & VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local initialized = false
local elapsed = 0

local function updateDisplay(gui: SurfaceGui)
	local frame = gui and gui:FindFirstChild("Frame")
	local counter = frame and frame:FindFirstChild("Counter")
	if not counter or not counter:IsA("TextLabel") then
		return
	end

	local timestamp = workspace:GetAttribute("NextUpdate")
	local text = "--:--:--"
	if typeof(timestamp) == "number"
		and timestamp == timestamp
		and timestamp > 0
		and timestamp < math.huge
	then
		-- Round up so 00:00:00 means the deadline has actually passed.
		local remainingSeconds = math.ceil(math.max(0, timestamp - workspace:GetServerTimeNow()))
		--local hours = math.floor(remainingSeconds / 3600)
		--local minutes = math.floor(remainingSeconds / 60) % 60
		--local seconds = remainingSeconds % 60
		--text = string.format("%02d:%02d:%02d", hours, minutes, seconds)
		text = EventConfig.FormatCountdown(remainingSeconds)
	end

	if counter.Text ~= text then
		counter.Text = text
	end
end
local function isPlayerRsvped()
	local success, result = pcall(function()
		return SocialService:GetEventRsvpStatusAsync(EVENT_ID)
	end)

	if success then
		return result == Enum.RsvpStatus.Going
	else
		warn("⚠️ Failed to check RSVP status: " .. tostring(result))
		-- Fallback: return true so we don't spam the prompt if the network call fails
		return true
	end
end
-- ==========================================
-- INIT
-- ==========================================
function NextUpdateController.Init()
	if initialized then
		return
	end
	initialized = true

	do -- prompt handling
		billboardNextUpdateProximityPrompt.ActionText = "Notify me!"
		billboardNextUpdateProximityPrompt.RequiresLineOfSight = false
		billboardNextUpdateProximityPrompt.HoldDuration = 0.25
		billboardNextUpdateProximityPrompt.MaxActivationDistance = 15
		billboardNextUpdateProximityPrompt.Triggered:Connect(function()
			local success, result = pcall(function()
				return SocialService:PromptRsvpToEventAsync(EVENT_ID)
			end)

			if success then
				print("✅ RSVP prompt request sent successfully!")
			else
				warn("RSVP ERROR: " .. tostring(result))
				if string.find(tostring(result), "Studio") then
					warn("👉 REMINDER: This UI will only appear when playing in the actual Roblox App.")
				elseif string.find(tostring(result), "403") then
					warn("👉 Check your Creator Dashboard to ensure the Event is 'Published' and 'Public'.")
				end
			end
		end)
	end

	do -- gui countdown
		workspace:GetAttributeChangedSignal("NextUpdate"):Connect(function()
			updateDisplay(billboardNextUpdateSurfaceGui)
		end)
		updateDisplay(billboardNextUpdateSurfaceGui)
		-- Resolve the GUI again each tick because its ResetOnSpawn is enabled.
		RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed < 1 then
				return
			end
			elapsed %= 1
			updateDisplay(billboardNextUpdateSurfaceGui)
		end)
	end
end

return NextUpdateController