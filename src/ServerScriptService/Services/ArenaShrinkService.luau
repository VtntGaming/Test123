-- Shrinks authoritative arena geometry; Moon clients render a smooth collidable copy.
local ArenaShrinkService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))

-- ==========================================
-- VARIABLES
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local ShrinkEvent = Events:FindFirstChild("ShrinkEvent") or Instance.new("RemoteEvent", Events)
ShrinkEvent.Name = "ShrinkEvent"

local isShrinking = false
local revision = 0
local visualTarget = nil
local visualParts = {}
local visualMeshes = {}

local function restoreVisuals()
	if visualTarget then
		CollectionService:RemoveTag(visualTarget, "MoonShrinkSource")
		visualTarget:SetAttribute("ShrinkActive", false)
	end
	for part, transparency in visualParts do
		if part.Parent then
			part.Transparency = transparency
			part:SetAttribute("ShrinkTransparency", nil)
			part:SetAttribute("ShrinkSize", nil)
			part:SetAttribute("ShrinkFrame", nil)
			part:SetAttribute("ShrinkCollide", nil)
		end
	end
	visualTarget = nil
	table.clear(visualParts)
	for mesh in visualMeshes do
		if mesh.Parent then
			mesh:SetAttribute("ShrinkMeshScale", nil)
			mesh:SetAttribute("ShrinkMeshOffset", nil)
		end
	end
	table.clear(visualMeshes)
end

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================
local function executeShrink(targetModel, token, clientVisuals)
	if not isShrinking or revision ~= token then return end

	local startTime = workspace:GetServerTimeNow()
	local minScaleMultiplier = GameConfig.ArenaShrink.MinScale
	local shrinkTime = GameConfig.MatchTimeLimit - GameConfig.ArenaShrink.InitialDelay
	local baseScale = targetModel:GetScale()
	local interval = if clientVisuals then GameConfig.ArenaShrink.ServerUpdateInterval else 0
	assert(type(interval) == "number" and interval >= 0 and interval < math.huge, "Invalid shrink interval")
	if clientVisuals then
		visualTarget = targetModel
		local pivot = targetModel:GetPivot()
		targetModel:SetAttribute("ShrinkPivot", pivot)
		targetModel:SetAttribute("ShrinkStartedAt", startTime)
		targetModel:SetAttribute("ShrinkDuration", shrinkTime)
		targetModel:SetAttribute("ShrinkMinimum", minScaleMultiplier)
		targetModel:SetAttribute("ShrinkRevision", token)
		for _, part in targetModel:GetDescendants() do
			if part:IsA("SpecialMesh") then
				visualMeshes[part] = true
				part:SetAttribute("ShrinkMeshScale", part.Scale)
				part:SetAttribute("ShrinkMeshOffset", part.Offset)
			end
			if part:IsA("BasePart") then
				visualParts[part] = part.Transparency
				part:SetAttribute("ShrinkTransparency", part.Transparency)
				part:SetAttribute("ShrinkSize", part.Size)
				part:SetAttribute("ShrinkFrame", pivot:ToObjectSpace(part.CFrame))
				part:SetAttribute("ShrinkCollide", part.CanCollide)
				part.Transparency = 1
				--(part:: BasePart).Color = BrickColor.Red().Color
			end
		end
		targetModel:SetAttribute("ShrinkActive", true)
		CollectionService:AddTag(targetModel, "MoonShrinkSource")
	end
	ShrinkEvent:FireAllClients("Start")

	task.spawn(function()
		while isShrinking and revision == token and targetModel.Parent do
			local elapsed = workspace:GetServerTimeNow() - startTime
			
			if elapsed >= shrinkTime then
				targetModel:Destroy()
				break
			end

			local currentMultiplier = 1 - ((elapsed / shrinkTime) * (1 - minScaleMultiplier))
			targetModel:ScaleTo(baseScale * currentMultiplier)
			
			task.wait(math.min(interval, math.max(0, shrinkTime - elapsed)))
		end
	end)
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function ArenaShrinkService.Start()
	restoreVisuals()
	revision += 1
	local token = revision
	isShrinking = true
	
	task.delay(GameConfig.ArenaShrink.InitialDelay, function()
		if not isShrinking or revision ~= token then return end
		
		local currentArena = CollectionService:GetTagged("DestroyableArena")[1]
		if not currentArena then return end

		local blocksContainer = currentArena:FindFirstChild("Blocks") or currentArena:FindFirstChild("Block") or currentArena:FindFirstChild("Main")
		local targetModel = blocksContainer and (blocksContainer:IsA("Model") and blocksContainer or blocksContainer:FindFirstChildWhichIsA("Model"))
		
		if targetModel and targetModel.PrimaryPart then
			executeShrink(targetModel, token, currentArena:GetAttribute("ArenaEffectModule") == "Moon")
		end
	end)
end

function ArenaShrinkService.Stop()
	revision += 1
	isShrinking = false
	restoreVisuals()
	ShrinkEvent:FireAllClients("Stop")
end

function ArenaShrinkService.Init()
end

return ArenaShrinkService
