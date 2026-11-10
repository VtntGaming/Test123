local WeaponService = {}
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local WeaponsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons")
local EquipEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("EquipWeaponEvent")
local WeaponConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("WeaponConfig"))
local SFX = SoundService:WaitForChild("SFX")
local initialized = false
local connections, characterConnections, lastRequest = {}, {}, {}
local pendingEquips = {}
local REPOSITIONING_ABILITIES = {
	"BigWeapon"
}

local function owns(player, name)
	for _, entry in string.split(player:GetAttribute("OwnedWeapons") or "", ",") do
		if string.match(entry, "^%s*(.-)%s*$") == name then return true end
	end
	return false
end

local function clearEquippedWeapon(character)
	character:SetAttribute("WeaponRevision", (character:GetAttribute("WeaponRevision") or 0) + 1)
	local old = character:FindFirstChild("EquippedWeapon")
	if old then old:Destroy() end
end

local function updateWeaponStance(player: Player, internal: boolean?)
	local character = player.Character
	local weapon = character and character:FindFirstChild("EquippedWeapon")
	local main = weapon and weapon:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then return end
	local old = main:FindFirstChild("WeaponWeld")
	if old then old:Destroy() end
	local combatReady = player:GetAttribute("IsOnArena") or player:GetAttribute("IsInTrainingArea")
	local target = combatReady and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
		or (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso"))
	if not target or not target:IsA("BasePart") then return end
	local transform = target.CFrame
	if not combatReady then
		local rotation = weapon:GetAttribute("WeaponId") == "Slap" and CFrame.Angles(math.rad(90), 0, math.rad(90))
			or CFrame.Angles(math.rad(90), math.rad(-45), 0)
		transform = transform * CFrame.new(-0.5, -0.5, 1.1) * rotation
	end
	main.CFrame = transform
	local weld = Instance.new("WeldConstraint")
	weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponWeld", target, main, main

	if not internal and not combatReady and table.find(REPOSITIONING_ABILITIES, player:GetAttribute("EquippedAbility")) then
		task.delay(0.5, function()
			-- We check for another time
			updateWeaponStance(player, true)
		end)
	end
end
local function updateWeaponSound(weapon: Model)
	-- FIX: Check for the new WeaponSkinName attribute first
	local name = weapon:GetAttribute("WeaponSkinName") or weapon:GetAttribute("WeaponName")
	if type(name) ~= "string" then
		return
	end
	local info = WeaponConfig.GetWeaponInfo(name)
	if not info then
		return
	end
	local host = weapon.PrimaryPart or weapon:FindFirstChildWhichIsA("BasePart")
	if not host then return end
	local soundTemplate = SFX:FindFirstChild(info.HitSound)
	if soundTemplate and soundTemplate:IsA("Sound") then
		local sound = soundTemplate:Clone() :: Sound
		sound.Name = info.HitSound
		sound.Looped = false
		sound.Parent = host
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local effects = assets and assets:FindFirstChild("SFX")
	local library = effects and effects:FindFirstChild("WeaponEffects")
	local effectTemplate = library and library:FindFirstChild(info.Variant)
	if effectTemplate and effectTemplate:IsA("Sound") then
		local sound = effectTemplate:Clone()
		sound.Name = "WeaponEffectHit"
		sound.Looped = false
		sound.Parent = host
	end
end

local function equipWeapon(player, name)
	local character = player.Character
	if player:GetAttribute("DataLoaded") ~= true or not character or character:GetAttribute("IsRagdolled") then return false end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not hand or not hand:IsA("BasePart") or not torso or not torso:IsA("BasePart") then return false end
	if type(name) ~= "string" or #name > 100 or not owns(player, name) then return false end
	local info = WeaponConfig.GetWeaponInfo(name)
	if not info then return false end
	local template = WeaponsFolder:FindFirstChild(name) or WeaponsFolder:FindFirstChild(info.BaseName)
	if not template or not template:IsA("Model") then return false end
	local model = template:Clone()
	local main = model:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then model:Destroy(); return false end

	model.Name = "EquippedWeapon"
	model:SetAttribute("WeaponId", info.BaseName)

	-- FIX: CombatService strictly requires this to be the Base Name ("Hammer"), NOT the skin!
	model:SetAttribute("WeaponName", info.BaseName) 
	-- Store the skin name safely out of the way so sounds still work
	model:SetAttribute("WeaponSkinName", name)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide, part.CanTouch, part.CanQuery, part.Massless, part.Anchored = false, false, false, true, false
			if part ~= main then
				local weld = Instance.new("WeldConstraint")
				weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponAssembly", main, part, part
			end
		end
	end
	clearEquippedWeapon(character)
	model:SetAttribute("EquipmentRevision", character:GetAttribute("WeaponRevision"))
	model.Parent = character
	player:SetAttribute("EquippedWeaponName", name)
	player:SetAttribute("EquippedBaseWeapon", info.BaseName)
	updateWeaponStance(player)
	updateWeaponSound(model)
	return true
end

local function equipWeapon(player, name)
	local character = player.Character
	if player:GetAttribute("DataLoaded") ~= true or not character or character:GetAttribute("IsRagdolled") then return false end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not hand or not hand:IsA("BasePart") or not torso or not torso:IsA("BasePart") then return false end
	if type(name) ~= "string" or #name > 100 or not owns(player, name) then return false end
	local info = WeaponConfig.GetWeaponInfo(name)
	if not info then return false end
	local template = WeaponsFolder:FindFirstChild(name) or WeaponsFolder:FindFirstChild(info.BaseName)
	if not template or not template:IsA("Model") then return false end
	local model = template:Clone()
	local main = model:FindFirstChild("Main")
	if not main or not main:IsA("BasePart") then model:Destroy(); return false end
	model.Name = "EquippedWeapon"
	model:SetAttribute("WeaponId", info.BaseName)
	model:SetAttribute("WeaponName", name)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide, part.CanTouch, part.CanQuery, part.Massless, part.Anchored = false, false, false, true, false
			if part ~= main then
				local weld = Instance.new("WeldConstraint")
				weld.Name, weld.Part0, weld.Part1, weld.Parent = "WeaponAssembly", main, part, part
			end
		end
	end
	clearEquippedWeapon(character)
	model:SetAttribute("EquipmentRevision", character:GetAttribute("WeaponRevision"))
	model.Parent = character
	player:SetAttribute("EquippedWeaponName", name)
	player:SetAttribute("EquippedBaseWeapon", info.BaseName)
	updateWeaponStance(player)
	updateWeaponSound(model)
	return true
end

local function requestEquip(player, name, expectedCharacter)
	local character = player.Character
	if not character or (expectedCharacter and expectedCharacter ~= character)
		or player:GetAttribute("DataLoaded") ~= true or character:GetAttribute("IsRagdolled")
		or type(name) ~= "string" or #name > 100 or not owns(player, name) or not WeaponConfig.GetWeaponInfo(name) then return end
	local request = {
		character = character, generation = character:GetAttribute("RagdollGeneration"),
		revision = character:GetAttribute("WeaponRevision") or 0,
	}
	pendingEquips[player] = request
	task.spawn(function()
		local deadline = os.clock() + 10
		local function current()
			return pendingEquips[player] == request and player.Character == character and character.Parent ~= nil
				and (not request.generation or character:GetAttribute("RagdollGeneration") == request.generation)
				and (character:GetAttribute("WeaponRevision") or 0) == request.revision
		end
		local function waitFor(nameToFind)
			if not current() then return nil end
			local existing = character:FindFirstChild(nameToFind)
			if existing then return existing end
			local remaining = deadline - os.clock()
			if remaining <= 0 then return nil end
			return character:WaitForChild(nameToFind, remaining)
		end
		local humanoid = waitFor("Humanoid")
		local ready = humanoid and humanoid:IsA("Humanoid") and waitFor("HumanoidRootPart")
		if ready and humanoid and humanoid:IsA("Humanoid") then
			local r15 = humanoid.RigType == Enum.HumanoidRigType.R15
			ready = waitFor(r15 and "RightHand" or "Right Arm") and waitFor(r15 and "UpperTorso" or "Torso")
		end
		if current() then
			pendingEquips[player] = nil
			if ready then equipWeapon(player, name) end
		elseif pendingEquips[player] == request then
			pendingEquips[player] = nil
		end
	end)
end

local function equipSaved(player, expectedCharacter)
	local character = player.Character
	if not character or (expectedCharacter and character ~= expectedCharacter) or player:GetAttribute("DataLoaded") ~= true then return end
	if character:GetAttribute("IsRagdolled") then return end
	--local saved = "Bat"
	local saved = player:GetAttribute("EquippedWeaponName") or "Bat"
	if type(saved) ~= "string" or saved == "" or not owns(player, saved) then saved = player:GetAttribute("EquippedBaseWeapon") end
	if type(saved) ~= "string" or not owns(player, saved) then
		saved = nil
		for _, name in string.split(player:GetAttribute("OwnedWeapons") or "", ",") do
			if WeaponConfig.GetWeaponInfo(name) then saved = name; break end
		end
	end
	if saved then
		local current = character:FindFirstChild("EquippedWeapon")
		if current and current:GetAttribute("WeaponName") == saved then updateWeaponStance(player); return end
		requestEquip(player, saved, character)
	else
		clearEquippedWeapon(character)
		player:SetAttribute("EquippedWeaponName", "")
		player:SetAttribute("EquippedBaseWeapon", nil)
	end
end

function WeaponService.Init()
	if initialized then return end
	initialized = true
	EquipEvent.OnServerEvent:Connect(function(player, name)
		local now = os.clock()
		if now - (lastRequest[player] or -math.huge) < 0.15 then return end
		lastRequest[player] = now
		requestEquip(player, name)
	end)
	local function attachPlayer(player)
		if connections[player] then return end
		local list = {}
		connections[player] = list
		for _, attribute in { "IsOnArena", "IsInTrainingArea" } do
			table.insert(list, player:GetAttributeChangedSignal(attribute):Connect(function() updateWeaponStance(player) end))
		end
		table.insert(list, player:GetAttributeChangedSignal("DataLoaded"):Connect(function() equipSaved(player) end))
		table.insert(list, player:GetAttributeChangedSignal("OwnedWeapons"):Connect(function() equipSaved(player) end))
		local function added(character)
			pendingEquips[player] = nil
			for _, connection in characterConnections[player] or {} do connection:Disconnect() end
			characterConnections[player] = {
				character:GetAttributeChangedSignal("RagdollGeneration"):Connect(function()
					pendingEquips[player] = nil
					equipSaved(player, character)
				end),
				character:GetAttributeChangedSignal("IsRagdolled"):Connect(function()
					if not character:GetAttribute("IsRagdolled") then equipSaved(player, character) end
				end),
			}
			task.spawn(function()
				local root = character:WaitForChild("HumanoidRootPart", 10)
				local humanoid = character:WaitForChild("Humanoid", 10)
				if not root or not humanoid or player.Character ~= character then return end
				equipSaved(player, character)
			end)
		end
		table.insert(list, player.CharacterAdded:Connect(added))
		if player.Character then added(player.Character) end
	end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(function(player)
		for _, connection in connections[player] or {} do connection:Disconnect() end
		for _, connection in characterConnections[player] or {} do connection:Disconnect() end
		connections[player], characterConnections[player], lastRequest[player] = nil, nil, nil
		pendingEquips[player] = nil
	end)
	for _, player in Players:GetPlayers() do attachPlayer(player) end
end

return WeaponService
