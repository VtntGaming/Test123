--!strict
-- Pure presentation rules, shared by the server, owner, observers and isolated checks.
local Reaction = {}
-- One collision within a hit; movement and animation consume the same impact ID.
export type Impact = {
	id: number, -- Collision number within this hit; prevents processing the same contact twice.
	time: number, -- Server time in seconds when this contact occurred.
	normal: Vector3, -- World-space surface normal pointing away from the contacted surface.
	outcome: string, -- "Landing" enters Rest; "Rebound" starts a Bounce reaction.
	category: string?, -- Selected Chest, Back, LeftSide, or RightSide; nil while unresolved.
	completed: boolean?, -- Whether synchronized Bounce playback has reported completion.
	contactPosition: Vector3?, -- World-space sphere contact point used for ambiguous head/feet selection.
	restDirection: Vector3?, -- Horizontal resting heading for no-slide landings; nil for normal sliding.
}
-- Describes one cosmetic blend; this does not move the server collision sphere.
export type Transition = {
	token: number, -- Reaction transition number used to reject outdated playback work.
	from: string, -- Presentation phase before the transition.
	to: string, -- Presentation phase being entered.
	started: number, -- Local os.clock() time in seconds when this blend began.
	duration: number -- Blend duration in seconds; zero applies the target immediately.
}
-- Cosmetic state for one character, separate from authoritative motion.
export type State = {
	generation: string, -- Actor lifetime identifier; distinguishes replacement characters.
	revision: number, -- Hit number within that lifetime; rejects older hits.
	token: number, -- Changes on each phase transition to invalidate old animation callbacks.
	impactId: number, -- Most recently consumed collision ID within this hit.
	category: string, -- Current directional animation category; Chest is the initial fallback.
	categoryConfirmed: boolean, -- Whether this impact's category is resolved, including local prediction.
	phase: string, -- Current cosmetic phase: Normal, Stun, Fly, Bounce, or Rest.
	transition: Transition?, -- Current or most recent phase blend; nil before any transition.
	restDirection: Vector3?, -- Saved no-slide landing heading used by torso rotation.
}

function Reaction.IsCategory(value: any): boolean
	return value == "Chest" or value == "Back" or value == "LeftSide" or value == "RightSide"
end

function Reaction.Classify(
	torso: CFrame,
	normal: Vector3,
	previous: string?,
	contactPosition: Vector3?
): string
	local fallback = if Reaction.IsCategory(previous) then previous :: string else "Chest"
	if normal.Magnitude < 0.001 or normal.Magnitude ~= normal.Magnitude then return fallback end
	local toward = -normal.Unit
	local chest, right = torso.LookVector:Dot(toward), torso.RightVector:Dot(toward)
	-- For head/feet-dominant contacts, use the contact point's side of the displayed torso.
	if math.abs(torso.UpVector:Dot(toward)) >= math.max(math.abs(chest), math.abs(right)) then
		if not contactPosition then
			return fallback
		end
		local point = torso:PointToObjectSpace(contactPosition)
		local sideDistance = math.max(math.abs(point.X), math.abs(point.Z))
		-- Inside 0.1 studs of the head-to-feet axis, keep the previous category.
		if sideDistance ~= sideDistance or sideDistance == math.huge or sideDistance <= 0.1 then
			return fallback
		end
		chest, right = -point.Z, point.X
	end
	if math.abs(chest) >= math.abs(right) then return if chest >= 0 then "Chest" else "Back" end
	return if right >= 0 then "RightSide" else "LeftSide"
end

function Reaction.New(): State
	return {generation = "", revision = -1, token = 0, impactId = 0,
		category = "Chest", categoryConfirmed = false, phase = "Normal", transition = nil, restDirection = nil}
end

function Reaction.Transition(state: State, phase: string, duration: number, now: number)
	state.token += 1
	state.transition = {token = state.token, from = state.phase, to = phase, started = now, duration = duration}
	state.phase = phase
	if phase == "Normal" then
		-- Re-entering a streamed character must consult its impact metadata again.
		state.impactId, state.categoryConfirmed = 0, false
		state.restDirection = nil
	end
end

function Reaction.Begin(state: State, generation: string, revision: number, duration: number, now: number): boolean
	if generation == state.generation and revision <= state.revision then return false end
	state.generation, state.revision, state.impactId, state.category = generation, revision, 0, "Chest"
	state.restDirection = nil
	state.categoryConfirmed = false
	Reaction.Transition(state, "Fly", duration, now)
	return true
end

function Reaction.Contact(state: State, impact: Impact, category: string?, duration: number, now: number): boolean
	if impact.id <= state.impactId or (category ~= nil and not Reaction.IsCategory(category)) then return false end
	state.impactId, state.categoryConfirmed = impact.id, category ~= nil
	state.restDirection = impact.restDirection
	if category then state.category = category end
	-- Consume motion even when the observer is still waiting for the owner's choice.
	Reaction.Transition(state, if impact.outcome == "Rebound" then "Bounce" else "Rest", duration, now)
	return true
end

function Reaction.ConfirmCategory(state: State, impactId: number, category: string,
	duration: number, now: number): boolean
	if state.phase == "Normal" or impactId ~= state.impactId or state.categoryConfirmed
		or not Reaction.IsCategory(category) then return false end
	state.category, state.categoryConfirmed = category, true
	-- Restart only the visual blend. Keep phase and playback token unchanged:
	-- a late selection must not replay Bounce or rewind Rest back to Bounce.
	state.transition = {token = state.token, from = state.phase, to = state.phase,
		started = now, duration = duration}
	return true
end

function Reaction.CanComplete(state: State, token: number, impactId: number): boolean
	return state.token == token and state.impactId == impactId and state.phase == "Bounce"
end

function Reaction.Complete(state: State, token: number, impactId: number, duration: number, now: number): boolean
	if not Reaction.CanComplete(state, token, impactId) then return false end
	Reaction.Transition(state, "Fly", duration, now)
	return true
end

function Reaction.Alpha(transition: Transition, now: number): number
	return if transition.duration > 0 then math.clamp((now - transition.started) / transition.duration, 0, 1) else 1
end

function Reaction.Unwrap(previous: number, angle: number): number
	return previous + math.atan2(math.sin(angle - previous), math.cos(angle - previous))
end

-- Caller establishes identity from OnServerEvent's Player, never from client arguments.
function Reaction.Accept(impacts: {Impact}, generation: string, revision: number,
	requestGeneration: any, requestRevision: any, id: any, action: any, category: any): boolean
	if requestGeneration ~= generation or requestRevision ~= revision or type(id) ~= "number"
		or id % 1 ~= 0 then return false end
	local impact: Impact? = nil
	for _, candidate in impacts do if candidate.id == id then impact = candidate; break end end
	if not impact then return false end
	if action == "Select" and not impact.category and Reaction.IsCategory(category) then
		impact.category = category
		return true
	elseif action == "Complete" and impact == impacts[#impacts] and impact.outcome == "Rebound"
		and impact.category and not impact.completed then
		impact.completed = true
		return true
	end
	return false
end

return Reaction

