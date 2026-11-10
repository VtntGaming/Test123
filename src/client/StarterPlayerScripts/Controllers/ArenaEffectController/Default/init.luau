local Default = {}
Default.__index = Default
local Config = require(script.Config)
local Helper = script.Parent.Helper
local EffectTransition = require(Helper.EffectTransition)

function Default.new(arena, player)
	local self = setmetatable({}, Default)
	self.effects = EffectTransition.new(Config, player)
	-- Atomic arenas arrive complete; take one snapshot instead of observing streaming.
	local folder = arena
	for _, name in Config.DynamicEffectsPath do
		folder = folder:FindFirstChild(name)
		if not folder then
			break
		end
	end
	if folder then
		for _, instance in folder:GetDescendants() do
			self.effects:Register(instance)
		end
	end
	return self
end

function Default:Update(elapsed, total, _dt)
	if not self.destroyed then
		self.effects:Update(elapsed, total)
	end
end

function Default:Reset()
	if not self.destroyed then
		self.effects:Reset()
	end
end

function Default:RefreshPlayer()
	if not self.destroyed then
		self.effects:RefreshPlayer()
	end
end

function Default:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	self.effects:Destroy()
end

return Default
