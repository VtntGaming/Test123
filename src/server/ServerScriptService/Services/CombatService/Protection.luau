-- Independent reason tokens own protection and shared transparency overrides.
local Protection = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerData)
local AbilityConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("AbilityConfig"))
local reasons = setmetatable({}, { __mode = "k" })
local visuals = setmetatable({}, { __mode = "k" })

local function restoreVisuals(player)
	local visual = visuals[player]
	if not visual then return end
	visuals[player] = nil
	visual.connection:Disconnect()
	for instance, transparency in pairs(visual.saved) do
		if instance.Parent then instance.Transparency = transparency end
	end
end

local function refreshVisuals(player)
	local active, character = reasons[player], player.Character
	local alpha
	for _, token in pairs(active or {}) do
		if token.character == character and token.transparency then
			alpha = math.max(alpha or 0, token.transparency)
		end
	end
	local visual = visuals[player]
	if visual and (visual.character ~= character or not alpha) then restoreVisuals(player)
visual = nil end
	if not alpha or not character then return end
	if not visual then
		visual = { character = character, saved = {}, alpha = alpha }
		visuals[player] = visual
		local current = visual
		local function apply(instance)
			if not (instance:IsA("BasePart") or instance:IsA("Decal")) then return end
			if current.saved[instance] == nil then current.saved[instance] = instance.Transparency end
			instance.Transparency = math.max(current.saved[instance], current.alpha)
		end
		visual.apply = apply
		visual.connection = character.DescendantAdded:Connect(apply)
		for _, instance in character:GetDescendants() do apply(instance) end
	else
		visual.alpha = alpha
		for instance, transparency in pairs(visual.saved) do
			if instance.Parent then instance.Transparency = math.max(transparency, alpha) end
		end
	end
end

local function publish(player)
	local active, protected = reasons[player], false
	for _, token in pairs(active or {}) do
		if not token.character or token.character == player.Character then protected = true
break end
	end
	PlayerData.Set(player, "IsInvulnerable", protected)
	refreshVisuals(player)
end

function Protection.Set(player, reason, duration, character, transparency)
	local active = reasons[player]
	if not active then active = {}
reasons[player] = active end
	if reason == "Spawn" and transparency == nil then transparency = AbilityConfig.Abilities.SpawnInvulnerability.Transparency end
	local token = { character = character or player.Character, transparency = transparency }
	active[reason] = token
	publish(player)
	if duration then
		task.delay(math.max(0, duration), function()
			if reasons[player] ~= active or active[reason] ~= token then return end
			active[reason] = nil
			publish(player)
		end)
	end
end

function Protection.Clear(player, reason)
	if reasons[player] then reasons[player][reason] = nil end
	publish(player)
end

function Protection.ClearAll(player)
	reasons[player] = nil
	publish(player)
end

function Protection.IsProtected(player)
	for _, token in pairs(reasons[player] or {}) do
		if not token.character or token.character == player.Character then return true end
	end
	return false
end

return table.freeze(Protection)
