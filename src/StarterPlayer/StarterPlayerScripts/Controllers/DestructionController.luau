local DestructionController = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local EffectModule = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("DestructionEffect"))
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))

-- ==========================================
-- VARIABLES
-- ==========================================
local DestructionEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("DestructionEvent")
local SFX = SoundService:WaitForChild("SFX")

local lastSoundTime = 0

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================
local function shakeModelLocally(model)
	if not model then return end

	local partsData = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			partsData[part] = part.CFrame
		end
	end

	local startTime = os.clock()
	local connection
	local moveParts, moveFrames = {}, {}
	
	connection = RunService.RenderStepped:Connect(function()
		table.clear(moveParts)
		table.clear(moveFrames)
		local elapsed = os.clock() - startTime
		if elapsed >= GameConfig.ArenaDestruction.WarningDuration or not model.Parent then
			connection:Disconnect()
			-- Ripristina i CFrame originali di sicurezza prima della distruzione
			-- English: Restore the original safety CFrames before destruction.
			for part, origCFrame in pairs(partsData) do
				if part.Parent then
					table.insert(moveParts, part)
					table.insert(moveFrames, origCFrame)
				end
			end
			if #moveParts > 0 then workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireAllEvents) end
			return
		end

		-- Calcola lo scostamento del tremolio (effetto ondulatorio veloce)
		-- English: Calculate the shake offset (a fast oscillating effect).
		local shakeOffset = Vector3.new(
			math.sin(os.clock() * 60) * 0.15,
			0, -- Non muoviamo la Y per non far glitchare i player sopra
			-- English: Do not move Y to avoid glitches for players standing above.
			math.cos(os.clock() * 60) * 0.15
		)

		for part, origCFrame in pairs(partsData) do
			if part.Parent then
				table.insert(moveParts, part)
				table.insert(moveFrames, origCFrame + shakeOffset)
			end
		end
		if #moveParts > 0 then workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireAllEvents) end
	end)
end

-- ==========================================
-- INIT
-- ==========================================
function DestructionController.Init()
	DestructionEvent.OnClientEvent:Connect(function(actionType, ...)
		local args = {...}
		
		if actionType == "Warning" then
			local model = args[1]
			task.spawn(shakeModelLocally, model)
			
		elseif actionType == "Destroy" then
			local now = os.clock()
			if now - lastSoundTime > 0.1 then
				lastSoundTime = now
				local rockSound = SFX:FindFirstChild("RockMoving")
				if rockSound then
					rockSound:Play()
				end
			end
			local model = args[1] :: Instance
			if not model or not model:IsA("Model") then
				return
			end
			for _,ins in ipairs(model:GetDescendants()) do
				if ins:IsA("BasePart") and ins.Transparency < 1 then
					EffectModule.Play(ins.CFrame, ins.Size, ins.Color, ins.Material)
					ins:Destroy()
				end
			end
		end
	end)
end

return DestructionController
