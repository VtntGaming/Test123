--!strict
-- Starts local prediction and samples camera-derived gameplay intent without writing character physics.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Modules
local PlayerData = require(ReplicatedStorage.PlayerData)
local Simulation = require(ReplicatedStorage.Simulation)
local Input = require(ReplicatedStorage.Simulation.Input)

--// References
local LocalPlayer = Players.LocalPlayer :: Player

--// Types
export type Controller = { Init: () -> (), Setup: (Controller) -> (), Start: (Controller) -> () }

--// Properties
local Initialized = false

--// Controller
local Controller: Controller = {} :: Controller

--// APIs
function Controller:Setup()
	Simulation.Init()
end

function Controller:Start()
	RunService.PreRender:Connect(function()
		local camera = Workspace.CurrentCamera
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		Input.Fire("Aim", if camera then camera.CFrame.LookVector else Vector3.zero)
		Input.Fire("Steer", if humanoid then humanoid.MoveDirection else Vector3.zero)
		Input.Fire(
			"Facing",
			if camera and PlayerData.Get(LocalPlayer, "ShiftLock") == true then camera.CFrame.LookVector else Vector3.zero
		)
	end)
end

function Controller.Init()
	if Initialized then
		return
	end
	Initialized = true
	Controller:Setup()
	Controller:Start()
end

return Controller
