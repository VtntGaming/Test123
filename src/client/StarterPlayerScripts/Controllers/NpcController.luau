local NpcController = {}
local initialized = false
local observed = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Events = ReplicatedStorage:WaitForChild("Events")
local NpcAttackEvent = Events:WaitForChild("NpcAttackEvent")

local Assets = ReplicatedStorage:WaitForChild("Assets")
local Overheads = Assets:WaitForChild("Overheads")
local OverheadHeartsGuiTemplate = Overheads:WaitForChild("OverheadHeartsGui")
local OverheadUsernameGuiTemplate = Overheads:WaitForChild("OverheadUsernameGui")

local activeAttacks = {}
local MAX_LIVES = 3
local heartTweenInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ==========================================
-- OVERHEAD HELPERS (NPC)
-- ==========================================
local function updateHeartsVisual(npc, gui)
	if not gui then return end
	local currentLives = npc:GetAttribute("Lives") or MAX_LIVES

	for i = 1, MAX_LIVES do
		local heart = gui:FindFirstChild("Heart_" .. i)
		if heart then
			local isAlive = (i <= currentLives)
			local targetColor = isAlive and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(30, 30, 30)
			local targetTransparency = isAlive and 0 or 0.65

			TweenService:Create(heart, heartTweenInfo, {
				ImageColor3 = targetColor,
				ImageTransparency = targetTransparency
			}):Play()
		end
	end
end

local function setupOverheads(npc, connections)
	local head = npc:WaitForChild("Head", 5)
	if not head or observed[npc] ~= connections or not npc:IsDescendantOf(workspace) then return end

	if head:FindFirstChild("OverheadHeartsGui") then head.OverheadHeartsGui:Destroy() end
	if head:FindFirstChild("OverheadUsernameGui") then head.OverheadUsernameGui:Destroy() end

	-- 1. SETUP CUORI
	local heartsGui = OverheadHeartsGuiTemplate:Clone()
	heartsGui.Name = "OverheadHeartsGui"
	heartsGui.Adornee = head
	heartsGui.Parent = head

	-- Clonazione dei cuori come fa l'OverheadController del player
	local temp = heartsGui:WaitForChild("HeartTemp", 2)
	if observed[npc] ~= connections or not head.Parent then heartsGui:Destroy()
return end
	if temp then
		temp.Visible = false
		for i = 1, MAX_LIVES do
			local heart = temp:Clone()
			heart.Name = "Heart_" .. i
			heart.Visible = true
			heart.Parent = heartsGui
		end
	end

	updateHeartsVisual(npc, heartsGui)
	heartsGui.Enabled = (npc:GetAttribute("IsOnArena") == true)

	local usernameGui = OverheadUsernameGuiTemplate:Clone()
	usernameGui.Name = "OverheadUsernameGui"
	usernameGui.Adornee = head
	usernameGui.Parent = head

	-- Hide the complete wins row in the new GUI.
	local winsFrame = usernameGui:FindFirstChild("Wins")
	if winsFrame then
		winsFrame.Visible = false
	end

	local afkText = usernameGui:FindFirstChild("AFKText")
	if afkText then
		afkText.Visible = false
	end

	local icon = usernameGui:FindFirstChild("HardwareIcon", true)
	if icon then
		icon.Image = "rbxassetid://103495637950753"
	end

	local usernameLabel = usernameGui:FindFirstChild("PlayerUsernameText", true)
	if usernameLabel then
		usernameLabel.RichText = false
		usernameLabel.Text = npc.Name
	end

	local originalStudsY = usernameGui.StudsOffset.Y

	local function updateNpcStates()
		if observed[npc] ~= connections or not head.Parent then
			return
		end

		local inArena = npc:GetAttribute("IsOnArena") == true
		local isCombat = inArena
			or npc:GetAttribute("IsInTrainingArea") == true

		updateHeartsVisual(npc, heartsGui)
		heartsGui.Enabled = inArena

		-- Same height calculation as OverheadController.
		local reduction = (inArena and 0 or 1.2)
			+ (isCombat and 0.6 or 0)

		usernameGui.StudsOffset = Vector3.new(
			0,
			originalStudsY - reduction,
			0
		)
	end

	for _, attribute in {
		"Lives",
		"IsOnArena",
		"IsInTrainingArea",
		} do
		table.insert(
			connections,
			npc:GetAttributeChangedSignal(attribute):Connect(updateNpcStates)
		)
	end

	updateNpcStates()

	--local connection = npc:GetAttributeChangedSignal("Lives"):Connect(function()
	--	updateHeartsVisual(npc, heartsGui)
	--end)
	--if observed[npc] then table.insert(observed[npc], connection) else connection:Disconnect() end
end

-- ==========================================
-- UTILS (Combat)
-- ==========================================
local function cancelAttack(npc)
	local data = activeAttacks[npc]
	if not data then return end
	activeAttacks[npc] = nil
	if data.connection then data.connection:Disconnect() end
	if data.ended then data.ended:Disconnect() end
	if data.track then data.track:Stop(0)
data.track:Destroy() end
	if data.animation then data.animation:Destroy() end
end

local function handleNpcAttack(npc, weaponId, action)
	-- Shared simulation owns NPC attack animation tracks. This event remains presentation-only.
	if action == "Cancel" then
		cancelAttack(npc)
	end
end

local function releaseNpc(npc)
	cancelAttack(npc)
	local connections = observed[npc]
	observed[npc] = nil
	if connections then for _, connection in connections do connection:Disconnect() end end
end

local function observeNpc(npc)
	if observed[npc] then return end
	local connections = {}
	observed[npc] = connections
	for _, attribute in {"IsRagdolled", "IsFrozen", "RagdollGeneration"} do
		table.insert(connections, npc:GetAttributeChangedSignal(attribute):Connect(function()
			if attribute == "RagdollGeneration" or npc:GetAttribute("IsRagdolled") or npc:GetAttribute("IsFrozen") then cancelAttack(npc) end
		end))
	end
	local function resumeCharge()
		if observed[npc] == connections and npc:GetAttribute("IsCharging") and not activeAttacks[npc] then
			handleNpcAttack(npc, npc:GetAttribute("EquippedBaseWeapon") or "Slap", "Charge")
		end
	end
	table.insert(connections, npc:GetAttributeChangedSignal("IsCharging"):Connect(resumeCharge))
	table.insert(connections, npc.DescendantAdded:Connect(function(item)
		if item:IsA("Animator") then resumeCharge() end
	end))
	table.insert(connections, npc.Destroying:Connect(function() releaseNpc(npc) end))
	task.spawn(setupOverheads, npc, connections)
	resumeCharge()
end

-- ==========================================
-- INIT
-- ==========================================
function NpcController.Init()
	if initialized then return end
	initialized = true
	NpcAttackEvent.OnClientEvent:Connect(handleNpcAttack)
	for _, tag in {"ArenaNPC", "LobbyNPC"} do
		CollectionService:GetInstanceAddedSignal(tag):Connect(observeNpc)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(releaseNpc)
		for _, npc in CollectionService:GetTagged(tag) do observeNpc(npc) end
	end
end

return NpcController
