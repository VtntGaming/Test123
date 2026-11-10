local Controller = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local UpdateGameState = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdateGameState")

local modules = { Default = require(script.Default), Iceberg = require(script.Iceberg), Moon = require(script.Moon), Island = require(script.Island), Mecha = require(script.Mecha) }
local initialized = false
local connections = {}
local arena, handler, selectedModule, moduleConnection
local player, duration
local elapsedSample, sampledAt = nil, 0
local Clock = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("TimeStopClock"))
	
local function update(dt)
	if Clock.IsStopped() then -- scenery freezes with the world (the clock only exists for players inside the match)
		sampledAt += dt
		dt = 0
	end
	if not handler then
		return
	end
	-- Wait for the first match sample, then run continuously until the arena is removed.
	if elapsedSample == nil then
		return
	end
	-- The server stops timer reports during the result delay; movement must keep advancing.
	local elapsed = elapsedSample + math.max(os.clock() - sampledAt, 0)
	handler:Update(elapsed, duration, dt)
end

local function selectModule()
	local module = modules[arena:GetAttribute("ArenaEffectModule")] or modules.Default
	if module == selectedModule then
		return
	end
	if handler then
		handler:Destroy()
	end
	handler, selectedModule = nil, nil
	-- Constructors validate their child Config through the shared helper.
	handler = module.new(arena, player)
	selectedModule = module
	update(0)
end

local function detachArena()
	if moduleConnection then
		moduleConnection:Disconnect()
		moduleConnection = nil
	end
	if handler then
		handler:Destroy()
	end
	arena, handler, selectedModule = nil, nil, nil
	elapsedSample, sampledAt = nil, 0
end

local function attachArena(candidate)
	if candidate == arena then
		return
	end
	detachArena()
	if not candidate or not candidate:IsA("Model") then
		return
	end
	arena = candidate
	moduleConnection = arena:GetAttributeChangedSignal("ArenaEffectModule"):Connect(selectModule)
	selectModule()
end

function Controller.Init()
	if initialized then
		return
	end
	player = Players.LocalPlayer :: Player
	assert(player, "ArenaEffectController must run on the client")
	duration = GameConfig.MatchTimeLimit
	assert(
		type(duration) == "number" and duration > 0 and duration < math.huge,
		"GameConfig.MatchTimeLimit must be finite and positive"
	)
	initialized = true

	table.insert(
		connections,
		ReplicatedStorage:WaitForChild("Events"):WaitForChild("MatchEndKOEvent").OnClientEvent:Connect(function()
			if handler and handler.Finish then
				update(0)
				handler:Finish()
				update(0)
			end
		end)
	)

	table.insert(
		connections,
		UpdateGameState.OnClientEvent:Connect(function(state, remaining)
			if state ~= "Playing" then return end
			if ReplicatedStorage:GetAttribute("MatchState") ~= "Playing" then
				return
			end
			if type(remaining) ~= "number" or remaining ~= remaining or math.abs(remaining) == math.huge then
				return
			end
			local now = os.clock()
			local reported = duration - math.clamp(remaining, 0, duration)
			local current = if elapsedSample ~= nil then elapsedSample + math.max(now - sampledAt, 0) else reported
			-- Delayed timer reports must not rewind a scene or reset its structures.
			elapsedSample, sampledAt = math.max(reported, current), now
			update(0)
		end)
	)
	table.insert(
		connections,
		player:GetAttributeChangedSignal("IsOnArena"):Connect(function()
			if handler then
				handler:RefreshPlayer()
			end
		end)
	)
	table.insert(
		connections,
		workspace.ChildAdded:Connect(function(child)
			if child.Name == GameConfig.ArenaName and child:IsA("Model") then
				attachArena(child)
			end
		end)
	)
	table.insert(
		connections,
		workspace.ChildRemoved:Connect(function(child)
			if child == arena then
				attachArena(workspace:FindFirstChild(GameConfig.ArenaName))
			end
		end)
	)
	table.insert(connections, RunService.Heartbeat:Connect(update))
	attachArena(workspace:FindFirstChild(GameConfig.ArenaName))
end

function Controller.Destroy()
	initialized = false
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	detachArena()
	elapsedSample, sampledAt = nil, 0
	player, duration = nil, nil
end

return Controller
