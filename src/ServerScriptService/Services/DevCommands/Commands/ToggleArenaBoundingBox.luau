-- Displays the volume currently used by CartoonPresentation's crowd-cheer check.
local ToggleArenaBoundingBox = {
	PrimaryAlias = "/arenaBox",
	SecondaryAlias = "/arenaBounds",
}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))

local initialized = false
local enabled = false
local elapsed = 0
local runtimeFolder = nil
local boxPart = nil
local currentArena = nil
local currentBounds = nil
local UPDATE_INTERVAL = 0.1

local function clearBox()
	if runtimeFolder then runtimeFolder:Destroy() end
	runtimeFolder, boxPart, currentArena, currentBounds = nil, nil, nil, nil
end

local function arenaBounds()
	local arena = Workspace:FindFirstChild(GameConfig.ArenaName)
	if not arena or not arena:IsA("Model") then return nil, nil end
	-- Intentionally match the existing client selection, including its Main fallback.
	-- On Moon, the first recursive Main is an Attachment, so the whole arena is used.
	local block = arena:FindFirstChild("Block")
	local main
	if block and block:IsA("Folder") then
		main = block:FindFirstChild("Main")
	end
	return arena, if main and main:IsA("Model") then main else arena
end

local function updateBox()
	local arena, bounds = arenaBounds()
	if not arena or not bounds then
		clearBox()
		return
	end
	if currentArena ~= arena or currentBounds ~= bounds or not boxPart or not boxPart.Parent then
		clearBox()
		currentArena, currentBounds = arena, bounds
		runtimeFolder = Instance.new("Folder")
		runtimeFolder.Name = "DevCommandRuntime"
		boxPart = Instance.new("Part")
		boxPart.Name = "ArenaBoundingBox"
		boxPart.Anchored = true
		boxPart.CanCollide = false
		boxPart.CanTouch = false
		boxPart.CanQuery = false
		boxPart.CastShadow = false
		boxPart.Transparency = 1
		boxPart.Parent = runtimeFolder
		local outline = Instance.new("SelectionBox")
		outline.Name = "Outline"
		outline.Adornee = boxPart
		outline.Color3 = Color3.fromRGB(255, 80, 80)
		outline.LineThickness = 1
		outline.SurfaceTransparency = 1
		outline.Parent = boxPart
	end
	local frame, size = bounds:GetBoundingBox()
	boxPart.CFrame = frame
	boxPart.Size = size + Vector3.yAxis * 100
	-- Keep the helper outside the arena so it cannot enlarge GetBoundingBox().
	if runtimeFolder.Parent ~= Workspace then runtimeFolder.Parent = Workspace end
end

function ToggleArenaBoundingBox.Init()
	if initialized then return end
	initialized = true
	RunService.Heartbeat:Connect(function(deltaTime)
		if not enabled then return end
		elapsed += deltaTime
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0
		updateBox()
	end)
end

function ToggleArenaBoundingBox.Trigger(player, words)
	local requested = words[2] and string.lower(words[2])
	if #words > 2 or (requested and requested ~= "on" and requested ~= "off") then
		warn("[DevCommandService] Usage: /arenaBox [on|off]")
		return
	end
	local nextEnabled = if requested then requested == "on" else not enabled
	if nextEnabled then
		local arena = arenaBounds()
		if not arena then
			warn("[DevCommandService] No active arena model in Workspace; visibility unchanged.")
			return
		end
	end
	enabled = nextEnabled
	elapsed = 0
	if enabled then
		updateBox()
		print("[DevCommandService]", player.Name, "enabled arena bounds:", currentBounds:GetFullName())
	else
		clearBox()
		print("[DevCommandService]", player.Name, "disabled arena bounds.")
	end
end

return ToggleArenaBoundingBox
