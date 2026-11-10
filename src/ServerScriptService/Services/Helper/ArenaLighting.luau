-- Temporarily replaces matching lighting classes while an arena is loaded.
local ArenaLighting = {}
ArenaLighting.__index = ArenaLighting

function ArenaLighting.new(lighting)
	return setmetatable({
		lighting = lighting,
		applied = {},
		displaced = {},
	}, ArenaLighting)
end

function ArenaLighting:Restore()
	for _, child in ipairs(self.applied) do
		child:Destroy()
	end
	table.clear(self.applied)
	for _, child in ipairs(self.displaced) do
		child.Parent = self.lighting
	end
	table.clear(self.displaced)
end

-- The arena is already a clone; source templates are never modified.
function ArenaLighting:Apply(arena)
	self:Restore()
	local replacements = {}
	local classes = {}
	local folder = arena:FindFirstChild("Lighting")
	if folder and folder:IsA("Folder") then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Sky") or child:IsA("Atmosphere") or child:IsA("PostEffect") then
				table.insert(replacements, child)
				classes[child.ClassName] = true
			end
		end
	else
		-- Preserve the existing layout used by arenas without a Lighting folder.
		for _, className in ipairs({ "Sky", "Atmosphere" }) do
			local child = arena:FindFirstChildOfClass(className)
			if child then
				table.insert(replacements, child)
				classes[className] = true
			end
		end
	end

	for _, child in ipairs(self.lighting:GetChildren()) do
		if classes[child.ClassName] then
			-- Keep the original instance and all of its properties for restoration.
			table.insert(self.displaced, child)
			child.Parent = nil
		end
	end
	for _, child in ipairs(replacements) do
		table.insert(self.applied, child)
		child.Parent = self.lighting
	end
end

return ArenaLighting
