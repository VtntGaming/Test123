--!strict
-- Animation instances are the source of truth; edit their AnimationId before Play.
local Resolver = {}

function Resolver.SetName(config: any, weaponId: string): string
	return if config.UseGlobalAnimations then config.GlobalSet
		else config.WeaponSets[weaponId] or config.GlobalSet
end

local function usableClip(instance: Instance?): Animation?
	if not instance or not instance:IsA("Animation") then return nil end
	-- An empty slot is unavailable, just like a missing Animation instance.
	if not string.find(instance.AnimationId, "%S") then return nil end
	return instance
end

function Resolver.Resolve(root: Instance, config: any, weaponId: string, slot: string): Animation?
	local selected = root:FindFirstChild(Resolver.SetName(config, weaponId))
	local clip = usableClip(if selected then selected:FindFirstChild(slot) else nil)
	if not clip then
		local shared = root:FindFirstChild(config.GlobalSet)
		clip = usableClip(if shared then shared:FindFirstChild(slot) else nil)
	end
	return clip
end

return Resolver

