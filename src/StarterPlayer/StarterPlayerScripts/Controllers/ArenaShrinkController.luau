local ArenaShrinkController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ShrinkVisual = require(script.Parent.ArenaEffectController.Moon.ShrinkVisual)

-- ==========================================
-- VARIABLES
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local ShrinkEvent = Events:WaitForChild("ShrinkEvent")
local SFX = SoundService:WaitForChild("SFX")

local activeSound = nil

-- ==========================================
-- INIT
-- ==========================================
function ArenaShrinkController.Init()
	ShrinkVisual.Init()
	ShrinkEvent.OnClientEvent:Connect(function(action)
		if action == "Start" then
			if activeSound then activeSound:Destroy() end

			local rumbleSound = SFX:FindFirstChild("Earthquake") or SFX:FindFirstChild("RockMoving")
			if rumbleSound then
				activeSound = rumbleSound:Clone()
				activeSound.Looped = true
				activeSound.Parent = workspace
				activeSound:Play()
			end

		elseif action == "Stop" then
			if activeSound then
				activeSound:Stop()
				activeSound:Destroy()
				activeSound = nil
			end
		end
	end)
end

return ArenaShrinkController
