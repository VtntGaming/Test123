--!strict
-- Roll handlers are synchronous and return a server-selected weapon, or nil.
local handlers: { [string]: (Player, any) -> string? } = {}
local Registry = {}

function Registry.Register(kind: string, roll: (Player, any) -> string?)
	assert(not handlers[kind] or handlers[kind] == roll, "Conflicting chest reward kind: " .. kind)
	handlers[kind] = roll
end

function Registry.Roll(player: Player, info: any): string?
	local roll = handlers[info.RewardKind]
	return if roll then roll(player, info) else nil
end

return Registry
