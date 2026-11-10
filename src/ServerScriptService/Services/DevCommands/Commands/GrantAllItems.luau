local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local WeaponConfig = require(SharedModules:WaitForChild("WeaponConfig"))
local AbilityConfig = require(SharedModules:WaitForChild("AbilityConfig"))
local Weapons = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons")

local GrantAllItems = {
	Weapons = { PrimaryAlias = "/allWeapons", SecondaryAlias = "/giveAllWeapons" },
	Abilities = { PrimaryAlias = "/allAbilities", SecondaryAlias = "/giveAllAbilities" },
}

local function grantMissing(player, attribute, names, label)
	if player:GetAttribute("DataLoaded") ~= true then
		warn("[DevCommandService] Wait for your player data to load before granting " .. label .. ".")
		return 0
	end
	local items, owned = {}, {}
	for _, entry in string.split(player:GetAttribute(attribute) or "", ",") do
		if entry ~= "" then
			table.insert(items, entry) -- Preserve existing copies used by forging.
			owned[string.match(entry, "^%s*(.-)%s*$")] = true
		end
	end
	table.sort(names)
	local added = 0
	for _, name in names do
		if not owned[name] then
			owned[name] = true
			table.insert(items, name)
			added += 1
		end
	end
	if added > 0 then player:SetAttribute(attribute, table.concat(items, ",")) end
	print("[DevCommandService]", player.Name, "granted", added, "new " .. label .. "; already-owned items skipped.")
	return added
end

function GrantAllItems.Weapons.Trigger(player)
	local names = {}
	for _, template in Weapons:GetChildren() do
		if template:IsA("Model") and WeaponConfig.GetWeaponInfo(template.Name) then
			table.insert(names, template.Name)
		end
	end
	return grantMissing(player, "OwnedWeapons", names, "weapons")
end

function GrantAllItems.Abilities.Trigger(player)
	local names = {}
	for name, settings in AbilityConfig.Abilities do
		if not settings.Unlisted then table.insert(names, name) end
	end
	return grantMissing(player, "OwnedAbilities", names, "abilities")
end

return GrantAllItems
