-- Attaches the shared simulation and configures local character display and allowed physics states.
local CharacterService = {}
local initialized = false
local players = {}
local characters = setmetatable({}, {__mode = "k"})

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Simulation = require(ReplicatedStorage.Simulation)
--// Variables
local LocalPlayer = Players.LocalPlayer :: Player

local function setupCharacter(character: Model)
	if characters[character] then return end
	characters[character] = true
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not humanoid:IsA("Humanoid") or not character.Parent then return end
	-- Server SetStateEnabled calls do not configure the local character's state machine.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
end

function CharacterService.Init()
	Simulation.Init()
	if initialized then return end
	initialized = true
	LocalPlayer.CharacterAdded:Connect(setupCharacter)
	if LocalPlayer.Character then task.spawn(setupCharacter, LocalPlayer.Character) end
end

return CharacterService
