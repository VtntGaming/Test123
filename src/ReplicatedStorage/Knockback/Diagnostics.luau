--!strict
local Diagnostics = {}
-- Optional counters stored locally in this execution context.
export type State = {
	enabled: boolean, -- Whether counter updates are recorded.
	counters: {[string]: number} -- Numeric counters or gauges indexed by diagnostic name.
}
function Diagnostics.New(enabled: boolean): State
	return {enabled = enabled, counters = {}}
end
function Diagnostics.Add(state: State, name: string, value: number?)
	if state.enabled then state.counters[name] = (state.counters[name] or 0) + (value or 1) end
end
function Diagnostics.Set(state: State, name: string, value: number)
	if state.enabled then state.counters[name] = value end
end
function Diagnostics.Read(state: State): any
	return {enabled = state.enabled, counters = table.clone(state.counters)}
end
return Diagnostics

