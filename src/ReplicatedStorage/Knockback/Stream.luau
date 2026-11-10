--!strict
local SharedConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local Combat = require(game:GetService("ReplicatedStorage"):WaitForChild("Combat"))
-- Transport-independent client reducer. No remotes, character writes or scheduling.
local Stream = {}
local Config = SharedConfig.Network
local Codec = require(script.Parent:WaitForChild("Codec"))
local Diagnostics = require(script.Parent:WaitForChild("Diagnostics"))
-- Client buffer and presentation state for one actor's motion session.
export type Record = {
	actorId: number, -- Server-assigned combat actor ID, shared by players, NPCs, and bags.
	actorKind: string, -- Player, NPC, or Bag; selects presentation behavior.
	userId: number, -- Owning player's user ID, or zero for actors without a player owner.
	session: number, -- Unique motion session ID; replaced by a new hit.
	generation: string, -- Actor lifetime identifier used to reject replacement-character updates.
	revision: number, -- Hit number within this actor lifetime.
	control: number, -- Highest contiguous reliable-control version applied.
	sequence: number, -- Highest sample sequence accepted, including samples waiting for controls.
	timestamp: number, -- Newest server sample time inserted into the presentation buffer.
	reactionVersion: number, -- Latest accepted version of synchronized category/completion metadata.
	packets: {Codec.Sample}, -- Time-ordered movement samples available for interpolation.
	future: {Codec.Sample}, -- Samples waiting for a required reliable-control version.
	controls: {[number]: any}, -- Out-of-order reliable events, indexed by control version.
	blockedAt: number?, -- Local os.clock() time when waiting for missing controls began.
	stopped: boolean, -- Whether this session has ended and must stop rendering movement.
	closedAt: number?, -- Local close time used to expire stopped-session records.
	phase: string, -- Motion phase currently selected for buffered presentation.
	weaponId: string, -- Weapon profile identity used to resolve reaction animation assets.
	velocity: Vector3, -- Velocity of the currently presented motion sample.
	wasAnchored: boolean, -- Whether the client has observed the root anchored during this session.
	renderedRoot: BasePart?, -- Root last controlled by local presentation, if currently available.
	stopApplied: boolean, -- Whether the final recovery/teleport frame was applied locally.
	stopFrame: CFrame?, -- Authoritative final root transform supplied by the stop message.
	impacts: {Combat.ReactionImpact}, -- Bounded collision history with directional reaction metadata.
	presentedTime: number, -- Server timeline time currently exposed to reaction playback.
	phaseTime: number, -- Timestamp of the sample establishing the currently presented phase.
	bootstrap: boolean, -- Whether the record was first created from an initial-state response.
	flyOffset: CFrame, -- Transform from sphere center to the displayed root while flying.
	restOffset: CFrame, -- Transform from sphere center to the root during Bounce, Slide, and Rest.
	stunOffset: CFrame, -- Transform from sphere center to the held root during Stun.
	consumedImpactId: number, -- Highest collision ID handled by presentation; releases its checkpoint.
	checkpoints: {[number]: Codec.Sample}, -- Collision samples held until reaction selection consumes each impact.
}
-- Client transport bookkeeping across actors and motion sessions.
export type State = {
	records: {[number]: Record}, -- Current or recently stopped record indexed by actor ID.
	sessions: {[number]: Record}, -- Records indexed by motion session ID for incoming messages.
	highest: {[number]: number}, -- Highest session ID seen per actor, used to reject stale starts.
	closed: {[number]: number}, -- Closed session IDs mapped to local close times, rejecting late traffic.
	pending: {[number]: any}, -- Bounded messages received before their session descriptor.
	departed: {[number]: boolean}, -- Actor IDs marked as disconnected; prevents late messages recreating them.
	needResync: boolean, -- Whether missing or malformed data requires an initial-state refresh.
	lastResync: number, -- Local os.clock() time of the last resync request.
	stats: Diagnostics.State, -- Optional local counters for traffic, buffering, and discarded updates.
}

function Stream.New(): State
	return {records = {}, sessions = {}, highest = {}, closed = {}, pending = {}, departed = {},
		needResync = false, lastResync = -math.huge, stats = Diagnostics.New(Config.Diagnostics)}
end

local function close(state: State, session: number, now: number)
	state.closed[session], state.pending[session] = now, nil
	local record = state.sessions[session]
	if record then
		record.stopped, record.blockedAt = true, nil
		record.closedAt = now
		table.clear(record.future)
		table.clear(record.controls)
		table.clear(record.checkpoints)
	end
	-- Bound tombstones even during long, crowded sessions.
	local count, oldest, oldestTime = 0, nil, math.huge
	for id, time in state.closed do
		count += 1
		if time < oldestTime then oldest, oldestTime = id, time end
	end
	if count > 256 and oldest then state.closed[oldest] = nil end
end

local function queue(state: State, session: number, kind: string, value: any, now: number)
	if state.closed[session] then return end
	local pending = state.pending[session]
	if not pending then
		local count = 0
		for _ in state.pending do count += 1 end
		if count >= Config.MaxPendingSessions then state.needResync = true; return end
		pending = {since = now, items = {}}
		state.pending[session] = pending
	end
	if #pending.items >= Config.MaxPendingMessages then
		table.remove(pending.items, 1)
		state.needResync = true
	end
	table.insert(pending.items, {kind = kind, value = value})
end

local function addSample(record: Record, sample: Codec.Sample)
	for _, previous in record.packets do if previous.sequence == sample.sequence then return end end
	table.insert(record.packets, sample)
	table.sort(record.packets, function(a, b)
		return a.time < b.time or (a.time == b.time and a.sequence < b.sequence)
	end)
	while #record.packets > Config.MaxSnapshots do table.remove(record.packets, 1) end
	record.timestamp = math.max(record.timestamp, sample.time)
end

local function addImpact(record: Record, impact: Combat.ReactionImpact)
	for _, current in record.impacts do
		if current.id == impact.id then
			if impact.category then current.category = impact.category end
			if impact.completed then current.completed = true end
			return
		end
	end
	table.insert(record.impacts, table.clone(impact))
	table.sort(record.impacts, function(a, b) return a.id < b.id end)
	while #record.impacts > 64 do table.remove(record.impacts, 1) end
end

local function releaseFuture(record: Record)
	local waiting: {Codec.Sample} = {}
	for _, sample in record.future do
		if sample.control <= record.control then addSample(record, sample) else table.insert(waiting, sample) end
	end
	record.future = waiting
	if #waiting == 0 and next(record.controls) == nil then record.blockedAt = nil end
end

function Stream.Sample(state: State, sample: Codec.Sample, now: number)
	if state.closed[sample.session] then Diagnostics.Add(state.stats, "DiscardedSamples"); return end
	local record = state.sessions[sample.session]
	if not record then queue(state, sample.session, "Sample", sample, now); return end
	if record.stopped or sample.sequence <= record.sequence then Diagnostics.Add(state.stats, "DiscardedSamples"); return end
	record.sequence = sample.sequence
	if sample.control > record.control then
		record.blockedAt = record.blockedAt or now
		table.insert(record.future, sample)
		while #record.future > Config.MaxSnapshots do table.remove(record.future, 1) end
	else
		addSample(record, sample)
	end
end

function Stream.Movement(state: State, data: any, now: number)
	Diagnostics.Add(state.stats, "MovementMessages")
	local samples = Codec.Decode(data)
	if not samples then Diagnostics.Add(state.stats, "MalformedPackets"); return end
	Diagnostics.Add(state.stats, "EncodedMovementBytes", buffer.len(data))
	for _, sample in samples do Stream.Sample(state, sample, now) end
end

local function applyControl(record: Record, event: any)
	record.control = event.version
	if event.impact then
		addImpact(record, event.impact)
		record.checkpoints[event.impact.id] = event.checkpoint
		for id in record.checkpoints do
			if id <= event.impact.id - 64 then record.checkpoints[id] = nil end
		end
	end
	-- A reliable boundary is inserted even if newer movement has already arrived.
	addSample(record, event.checkpoint)
	record.sequence = math.max(record.sequence, event.checkpoint.sequence)
end

function Stream.Control(state: State, event: any, now: number)
	if type(event) ~= "table" or type(event.session) ~= "number" then return end
	local session = event.session
	if event.kind == "Stop" then
		close(state, session, now)
		if type(event.actorId) == "number" then
			state.highest[event.actorId] = math.max(state.highest[event.actorId] or 0, session)
			local current = state.records[event.actorId]
			if current and current.session <= session and current.generation == event.generation then
				close(state, current.session, now)
				current.stopFrame = event.rootFrame
			end
		end
		return
	end
	if state.closed[session] then return end
	if event.kind == "Start" or event.kind == "Bootstrap" then
		if type(event.actorId) ~= "number" or type(event.generation) ~= "string"
			or (event.actorKind ~= "Player" and event.actorKind ~= "NPC" and event.actorKind ~= "Bag") then return end
		if state.departed[event.actorId] then return end
		local current = state.records[event.actorId]
		local highest = state.highest[event.actorId] or 0
		if session < highest or (session == highest and (not current or current.stopped)) then return end
		local record = state.sessions[session]
		if not record then
			if current then close(state, current.session, now); state.sessions[current.session] = nil end
			local fresh: Record = {
				actorId = event.actorId, actorKind = event.actorKind, userId = event.userId or 0, session = session, generation = event.generation, revision = event.revision,
				control = event.version, sequence = event.checkpoint.sequence, timestamp = event.checkpoint.time,
				reactionVersion = event.reactionVersion or 0, packets = {}, future = {}, controls = {}, blockedAt = nil,
				stopped = false, closedAt = nil, phase = event.checkpoint.phase, weaponId = event.weaponId, velocity = event.checkpoint.velocity,
				wasAnchored = false, renderedRoot = nil, stopApplied = false, stopFrame = nil,
				impacts = {}, presentedTime = event.checkpoint.time, phaseTime = event.checkpoint.time,
				bootstrap = event.kind == "Bootstrap", flyOffset = event.flyOffset, restOffset = event.restOffset,
				stunOffset = event.stunOffset or event.flyOffset,
				consumedImpactId = 0, checkpoints = {},
			}
			record = fresh
			state.records[event.actorId], state.sessions[session], state.highest[event.actorId] = fresh, fresh, session
			addSample(fresh, event.checkpoint)
			if event.reaction then addImpact(fresh, event.reaction) end
		elseif event.kind == "Bootstrap" then
			if event.version >= record.control then
				record.control = event.version
				-- Do not rewind the pose when an older bootstrap response arrives late.
				addSample(record, event.checkpoint)
				record.sequence = math.max(record.sequence, event.checkpoint.sequence)
				for version in record.controls do if version <= record.control then record.controls[version] = nil end end
			end
			if (event.reactionVersion or 0) >= record.reactionVersion then
				record.reactionVersion = event.reactionVersion or 0
				if event.reaction then addImpact(record, event.reaction) end
			end
		end
		local pending = state.pending[session]
		state.pending[session] = nil
		if pending then
			for _, item in pending.items do
				if item.kind == "Sample" then Stream.Sample(state, item.value, now) else Stream.Control(state, item.value, now) end
			end
		end
		while record.controls[record.control + 1] do
			local nextEvent = record.controls[record.control + 1]
			record.controls[record.control + 1] = nil
			applyControl(record, nextEvent)
		end
		releaseFuture(record)
		return
	end
	local record = state.sessions[session]
	if not record then queue(state, session, "Control", event, now); return end
	if record.stopped then return end
	if event.kind == "Reaction" then
		if event.reactionVersion <= record.reactionVersion then return end
		record.reactionVersion = event.reactionVersion
		-- Full *single-impact* metadata also safely merges bootstrap/selection races.
		addImpact(record, event.impact)
		return
	end
	if event.kind ~= "Impact" and event.kind ~= "Phase" then return end
	if event.version <= record.control then return end
	if event.version > record.control + 1 then
		record.blockedAt = record.blockedAt or now
		local count = 0
		for _ in record.controls do count += 1 end
		if count >= Config.MaxPendingMessages then state.needResync = true; return end
		record.controls[event.version] = event
		return
	end
	applyControl(record, event)
	while record.controls[record.control + 1] do
		local nextEvent = record.controls[record.control + 1]
		record.controls[record.control + 1] = nil
		applyControl(record, nextEvent)
	end
	releaseFuture(record)
end

function Stream.Bootstrap(state: State, response: any, now: number)
	if type(response) ~= "table" or type(response.sessions) ~= "table" then state.needResync = true; return end
	local present: {[number]: boolean} = {}
	for _, descriptor in response.sessions do
		present[descriptor.session] = true
		Stream.Control(state, descriptor, now)
	end
	for _, record in state.records do
		if not record.stopped and not present[record.session] and record.timestamp <= response.time then
			close(state, record.session, now)
		end
	end
end

function Stream.PollResync(state: State, now: number): boolean
	local active = 0
	for actorId, record in state.records do
		if not record.stopped then active += 1 end
		local closedAt = record.closedAt
		if record.stopped and closedAt and now - closedAt > 60 then
			state.records[actorId], state.sessions[record.session], state.highest[actorId] = nil, nil, nil
		end
		if record.blockedAt and now - record.blockedAt >= Config.PendingTimeout then state.needResync = true end
	end
	Diagnostics.Set(state.stats, "ActiveCharacters", active)
	for session, pending in state.pending do
		if now - pending.since >= Config.PendingTimeout then state.pending[session] = nil; state.needResync = true end
	end
	for session, time in state.closed do if now - time > 60 then state.closed[session] = nil end end
	if state.needResync and now - state.lastResync >= Config.ResyncInterval then
		state.needResync, state.lastResync = false, now
		Diagnostics.Add(state.stats, "ResyncRequests")
		return true
	end
	return false
end

function Stream.RemoveCharacter(state: State, actorId: number, generation: any, now: number)
	local record = state.records[actorId]
	if record and record.generation == generation then close(state, record.session, now) end
end

function Stream.RemoveActor(state: State, actorId: number, now: number)
	local record = state.records[actorId]
	if record then close(state, record.session, now); state.sessions[record.session] = nil end
	state.records[actorId], state.departed[actorId] = nil, true
end

function Stream.Present(state: State, record: Record, renderTime: number): (CFrame?, Vector3?)
	local packets = record.packets
	if record.stopped or #packets == 0 then return nil, nil end
	-- Bags have no Animator/contact classifier to consume presentation boundaries.
	if record.actorKind == "Bag" then
		for _, impact in record.impacts do
			if impact.time <= renderTime then record.consumedImpactId = math.max(record.consumedImpactId, impact.id) end
		end
	end
	-- Give PreAnimation a contact checkpoint before rendering movement beyond it.
	-- Keep these separately so an outage cannot evict them from the sample ring.
	for id in record.checkpoints do
		if id <= record.consumedImpactId then record.checkpoints[id] = nil end
	end
	for _, impact in record.impacts do
		local boundary = record.checkpoints[impact.id]
		if boundary and impact.time <= renderTime then
			record.phase, record.phaseTime, record.presentedTime = boundary.phase, boundary.time, boundary.time
			record.velocity = boundary.velocity
			return CFrame.new(boundary.position) * (if boundary.phase == "Fly" then record.flyOffset else record.restOffset), boundary.position
		end
	end
	while #packets > 2 and packets[2].time <= renderTime do table.remove(packets, 1) end
	local first, second = packets[1], packets[2]
	local position, velocity = first.position, first.velocity
	record.phase, record.phaseTime = first.phase, first.time
	local latest = packets[#packets]
	record.presentedTime = math.max(first.time, math.min(renderTime, latest.time))
	if renderTime > latest.time + 1 / Config.SnapshotRate and latest.velocity.Magnitude > 0.05 then
		Diagnostics.Add(state.stats, "InterpolationUnderruns")
	end
	if second then
		local duration = second.time - first.time
		local alpha = if duration > 0 then math.clamp((renderTime - first.time) / duration, 0, 1) else 1
		position = position:Lerp(second.position, alpha)
		if first.control == second.control then velocity = velocity:Lerp(second.velocity, alpha) end
		if alpha >= 1 then record.phase, record.phaseTime, velocity = second.phase, second.time, second.velocity end
	end
	record.velocity = velocity
	return CFrame.new(position) * (if record.phase == "Stun" then record.stunOffset
		elseif record.phase == "Fly" then record.flyOffset else record.restOffset), position
end

return Stream
