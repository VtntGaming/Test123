-- Independent reason tokens own protection and shared transparency overrides.
local Protection = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
	if visual and (visual.character ~= character or not alpha) then restoreVisuals(player); visual = nil end
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
		-- a Shield is not blanket invulnerability: it only eats the first hit (see IsProtected)
		if not token.shield and (not token.character or token.character == player.Character) then protected = true; break end
	end
	player:SetAttribute("IsInvulnerable", protected)
	refreshVisuals(player)
end

function Protection.Set(player, reason, duration, character, transparency)
	local active = reasons[player]
	if not active then active = {}; reasons[player] = active end
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
	Protection.ClearShield(player)
	reasons[player] = nil
	publish(player)
end

-- ==========================================
-- SHIELD: blocks the first attack that reaches the player, then breaks.
-- IsProtected is what every hit check calls, so the first call on a shielded player breaks the shield
-- and keeps answering "protected" for a short window so one attack (multi-hit / several checks) is fully blocked.
-- ==========================================
local SHIELD_REASON = "Shield"
local DEFAULT_ABSORB_WINDOW = 0.35

local function breakShield(player, token)
	token.brokenAt = os.clock()
	local character = token.character
	if character and character.Parent then
		-- counter first, then the flag: clients tell "broken" from "expired" by the counter
		character:SetAttribute("ShieldBreak", (character:GetAttribute("ShieldBreak") or 0) + 1)
		character:SetAttribute("ShieldActive", false)
	end
	task.delay(token.window, function()
		local active = reasons[player]
		if active and active[SHIELD_REASON] == token then active[SHIELD_REASON] = nil end
	end)
end

function Protection.SetShield(player, character, absorbWindow)
	local active = reasons[player]
	if not active then active = {}; reasons[player] = active end
	active[SHIELD_REASON] = { character = character, shield = true, window = absorbWindow or DEFAULT_ABSORB_WINDOW }
	if character then character:SetAttribute("ShieldActive", true) end
	publish(player)
end

-- expired / cancelled (NOT broken by a hit)
function Protection.ClearShield(player)
	local active = reasons[player]
	local token = active and active[SHIELD_REASON]
	if not token then return end
	active[SHIELD_REASON] = nil
	local character = token.character
	if not token.brokenAt and character and character.Parent then
		character:SetAttribute("ShieldActive", false)
	end
end

function Protection.HasShield(player)
	local active = reasons[player]
	local token = active and active[SHIELD_REASON]
	return token ~= nil and not token.brokenAt
end

-- peek = true: only look (used for AI targeting), a shield is ignored and never breaks
function Protection.IsProtected(player, peek)
	for _, token in pairs(reasons[player] or {}) do
		if not token.character or token.character == player.Character then
			if not token.shield then return true end
			if not peek then
				if not token.brokenAt then breakShield(player, token) end
				if os.clock() - token.brokenAt <= token.window then return true end
			end
		end
	end
	return false
end

return table.freeze(Protection)
