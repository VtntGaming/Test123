--!strict
-- Keeps opt-in actor, correction and cleanup counters local to this execution context.
export type State = { enabled: boolean, counters: { [string]: number } }
export type Snapshot = { enabled: boolean, counters: { [string]: number } }
export type Diagnostics = {
	New: (boolean) -> State,
	Add: (State, string, number?) -> (),
	Set: (State, string, number) -> (),
	Read: (State) -> Snapshot,
}
local Diagnostics: Diagnostics = {} :: Diagnostics
function Diagnostics.New(enabled)
	return { enabled = enabled, counters = {} }
end
function Diagnostics.Add(state, name, value)
	if state.enabled then
		state.counters[name] = (state.counters[name] or 0) + (value or 1)
	end
end
function Diagnostics.Set(state, name, value)
	if state.enabled then
		state.counters[name] = value
	end
end
function Diagnostics.Read(state)
	return { enabled = state.enabled, counters = table.clone(state.counters) }
end
return Diagnostics
