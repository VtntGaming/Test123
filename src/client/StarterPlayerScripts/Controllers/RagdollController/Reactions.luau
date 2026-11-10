--!strict
-- Selects Cartoon reaction clips and controls live Animator tracks without retaining track handles.

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

--// Modules
local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local SharedConfig = require(ReplicatedStorage:WaitForChild("Config"))
local Combat = require(ReplicatedStorage:WaitForChild("Combat"))
local Knockback = require(ReplicatedStorage:WaitForChild("Knockback"))
local Reaction = Combat.Reaction
local Resolver = Combat.AnimationResolver
local Config = SharedConfig.Animation
local FREEZE_BOUNCE = Config.FreezeBounceAtLastFrame == true
local DEFAULT_LOCAL_REACTIONS = Config.LocalReactionPrediction == true
local Playback = require(script.Parent:WaitForChild("Playback"))
local BOUNCE_END_EPSILON = 0.0001 -- Stay just inside the end so the track retains its pose.
local Motion = require(script.Parent:WaitForChild("CartoonPresentation"))
local clips = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Knockback")
-- Stun and Fly may share an asset ID; overriding one live track must not change its authored loop default.
local AuthoredLoops: { [string]: boolean } = {}

-- Bounded local choices for one motion session; reused across temporary streaming removal.
type Decisions = {
	categories: { [number]: string }, -- Chosen reaction category indexed by collision ID.
	completed: { [number]: boolean }, -- Bounce completion flags indexed by collision ID.
	order: { number }, -- Insertion order of collision IDs, used to evict choices beyond the cache limit.
}
-- Weak packet keys retain choices across streaming without owning motion sessions.
local decisionCaches = setmetatable({} :: { [Knockback.Presentation]: Decisions }, { __mode = "k" })

-- Animation resources and presentation bookkeeping for one character.
export type State = {
	-- Last local clock sample during TimeStop; nil when reaction playback is running.
	pausedAt: number?,
	-- Playback speeds indexed by animation ID; no live track handles are retained.
	pausedSpeeds: { [string]: number },
	-- Shared phase, category, hit identity, and blend timing.
	presentation: Combat.ReactionState,
	-- Animation IDs mapped to their last reaction phase; live tracks are queried only when needed.
	trackIds: { [string]: string },
	-- Visual Animator currently controlled; replacement invalidates playback metadata.
	animator: Animator?,
	-- Animation ID selected for the current reaction, or nil after stopping.
	currentId: string?,
	-- Whether the current clip loops, sampled when the reaction starts.
	currentLooped: boolean,
	-- Last known clip length in seconds, retained to recognize completion after a track disappears.
	currentLength: number,
	-- Local os.clock() origin for reconstructing playback time after track replacement.
	playbackStarted: number,
	-- Whether a restored track is waiting for its clip length before seeking.
	needsSeek: boolean,
	-- Last transition token whose animation playback was started.
	playedToken: number,
	-- Transition token awaiting Bounce completion handling.
	pendingCompletion: number?,
	-- Local os.clock() deadline before retrying a missing or failed animation.
	retryAt: number,
	-- Weapon family used to resolve animation slots.
	weapon: string,
	-- Phase to restore after presentation temporarily stops or streams out.
	resumePhase: string,
	-- Last transition whose outgoing tracks were prepared, preventing repeated fades.
	preparedToken: number,
	-- Animation-ID ownership and competing-animation filter state.
	playback: Playback.State,
	-- Invalidates delayed cleanup when a new reaction starts.
	cleanupRevision: number,
	-- Motion record owning this character's current local decision cache.
	decisionPacket: Knockback.Presentation?,
	-- Collision ID whose Bounce track needs a late/streaming playback seek.
	catchupImpact: number?,
	-- Buffered seconds since that impact, used to seek Bounce playback.
	catchupAge: number,
	-- Configured playback multiplier for the current clip.
	playbackSpeed: number,
	-- Whether this client chooses reactions itself; always true for NPCs.
	localReactions: boolean,
}

export type Reactions = {
	-- Creates presentation metadata without loading or retaining animation tracks.
	New: () -> State,
	-- Attaches the visual Animator's competing-animation filter.
	Observe: (State, Model, Humanoid?, boolean) -> (),
	-- Asynchronously preloads authored reaction assets without blocking startup.
	Preload: () -> (),
	-- Fades live reaction tracks and optionally retains per-impact choices for streaming recovery.
	Stop: (State, boolean?) -> (),
	-- Releases live reaction tracks and ID ownership without changing the torso recovery transition.
	ClearTracks: (State) -> (),
	-- Releases playback/filter resources and optionally preserves per-impact choices.
	Destroy: (State, boolean?) -> (),
	-- Selects the current reaction and restores interrupted live playback before Animator evaluation.
	Update: (State, Model, Humanoid, number?) -> (),
}

local Reactions: Reactions = {} :: Reactions

function Reactions.New()
	return {
		pausedAt = nil,
		pausedSpeeds = {},
		presentation = Reaction.New(),
		trackIds = {},
		animator = nil,
		currentId = nil,
		currentLooped = false,
		currentLength = 0,
		playbackStarted = 0,
		needsSeek = false,
		playedToken = -1,
		pendingCompletion = nil,
		retryAt = 0,
		weapon = "",
		resumePhase = "Fly",
		preparedToken = -1,
		playback = Playback.New(),
		cleanupRevision = 0,
		decisionPacket = nil,
		catchupImpact = nil,
		catchupAge = 0,
		playbackSpeed = 1,
		localReactions = DEFAULT_LOCAL_REACTIONS,
	}
end

local function forgetDecisions(state: State)
	if state.decisionPacket then
		decisionCaches[state.decisionPacket] = nil
	end
	state.decisionPacket, state.catchupImpact, state.catchupAge = nil, nil, 0
end

local function decisionsFor(state: State, packet: Knockback.Presentation): Decisions
	if state.decisionPacket ~= packet then
		forgetDecisions(state)
		state.decisionPacket = packet
	end
	local cache = decisionCaches[packet]
	if not cache then
		cache = { categories = {}, completed = {}, order = {} }
		decisionCaches[packet] = cache
	end
	return cache
end

local function localCategory(
	cache: Decisions,
	impact: Combat.ReactionImpact,
	character: Model,
	previous: string
): string
	local cached = cache.categories[impact.id]
	if cached then
		return cached
	end
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	local category = if torso and torso:IsA("BasePart")
		then Reaction.Classify(torso.CFrame, impact.normal, previous, impact.contactPosition)
		else previous
	cache.categories[impact.id] = category
	table.insert(cache.order, impact.id)
	while #cache.order > 64 do
		local expired = table.remove(cache.order, 1)
		if expired then
			cache.categories[expired], cache.completed[expired] = nil, nil
		end
	end
	return category
end

function Reactions.Observe(state, character, humanoid, active)
	state.localReactions = DEFAULT_LOCAL_REACTIONS or character:GetAttribute("KnockbackActorKind") == "NPC"
	Playback.Observe(state.playback, character, humanoid, active)
end

function Reactions.Preload()
	task.spawn(function()
		local animations: { Instance } = {}
		for _, clip in clips:GetDescendants() do
			if clip:IsA("Animation") then
				table.insert(animations, clip)
			end
		end
		local success, err = pcall(function()
			ContentProvider:PreloadAsync(animations)
		end)
		if not success then
			warn("Cartoon animation preload failed:", err)
		end
	end)
end

local function clearCompletion(state: State)
	state.pendingCompletion = nil
end

local function currentTrack(state: State): AnimationTrack?
	local animator, id = state.animator, state.currentId
	return if animator and animator.Parent and id then animator:GetTrackByAnimationId(id) else nil
end

local function phaseToResume(state: State): string
	local phase = state.presentation.phase
	return if phase == "Stun"
			or phase == "Rest"
			or (phase == "Bounce" and (FREEZE_BOUNCE or state.currentLooped))
		then phase
		else "Fly"
end

function Reactions.Stop(state, preserveDecisions)
	state.pausedAt = nil
	table.clear(state.pausedSpeeds)
	if state.localReactions and not preserveDecisions then
		forgetDecisions(state)
	end
	if state.presentation.phase == "Normal" and not state.currentId then
		return
	end
	clearCompletion(state)
	state.resumePhase = phaseToResume(state)
	local duration = (if state.presentation.phase == "Rest" then Config.RestToNormalFadeTime else Config.FlyFadeTime)
	Reaction.Transition(state.presentation, "Normal", duration, os.clock())
	local animator = state.animator
	if animator and animator.Parent then
		for id in state.trackIds do
			local track = animator:GetTrackByAnimationId(id)
			if track and track.IsPlaying then
				track:Stop(duration)
			end
		end
	end
	state.currentId, state.playedToken, state.needsSeek = nil, -1, false
	if state.localReactions then
		state.cleanupRevision += 1
		local cleanup = state.cleanupRevision
		-- Keep ID exemptions until the recovery fade has finished; resolve tracks again at cleanup time.
		task.delay(duration + 0.1, function()
			if state.cleanupRevision == cleanup and state.presentation.phase == "Normal" then
				Reactions.ClearTracks(state)
			end
		end)
	end
end

function Reactions.ClearTracks(state)
	state.pausedAt = nil
	table.clear(state.pausedSpeeds)
	state.cleanupRevision += 1
	clearCompletion(state)
	local animator = state.animator
	for id in state.trackIds do
		local track = if animator and animator.Parent then animator:GetTrackByAnimationId(id) else nil
		if track then
			track:Stop(0)
			track:Destroy()
		end
		Playback.Unregister(state.playback, id)
	end
	table.clear(state.trackIds)
	state.currentId, state.animator, state.playedToken, state.preparedToken = nil, nil, -1, -1
	state.currentLooped, state.currentLength, state.playbackStarted, state.needsSeek = false, 0, 0, false
end

function Reactions.Destroy(state, preserveDecisions)
	if preserveDecisions and state.presentation.phase ~= "Normal" then
		state.resumePhase = phaseToResume(state)
	end
	Reaction.Transition(state.presentation, "Normal", 0, os.clock())
	Reactions.ClearTracks(state)
	Playback.Detach(state.playback)
	if not preserveDecisions then
		forgetDecisions(state)
	end
end

-- Attributes are sampled when this reaction starts, including reused tracks.
-- Invalid/missing values fall back to speed 1, one-shot Bounce and looping Rest.
local function clipSettings(clip: Animation, phase: string, authoredLoop: boolean): (number, boolean)
	if phase == "Stun" then
		return 1, true
	end
	if phase ~= "Bounce" and phase ~= "Rest" then
		return 1, authoredLoop
	end
	local speed = clip:GetAttribute("PlaybackSpeed")
	local looped = clip:GetAttribute("Looped")
	return if type(speed) == "number" and speed == speed and speed > 0 and speed < math.huge then speed else 1,
		if type(looped) == "boolean" then looped else phase == "Rest"
end

local function seekRestoredTrack(state: State, track: AnimationTrack)
	if track.Length <= 0 then
		track:AdjustSpeed(0) -- Wait for streamed clip metadata before wrapping/clamping its time.
		return
	end
	state.currentLength = track.Length
	local position = math.max(0, os.clock() - state.playbackStarted) * state.playbackSpeed
	local lastFrame = math.max(0, track.Length - BOUNCE_END_EPSILON)
	track.TimePosition = if state.currentLooped then position % track.Length else math.min(position, lastFrame)
	local held = state.presentation.phase == "Rest" or (state.presentation.phase == "Bounce" and FREEZE_BOUNCE)
	track:AdjustSpeed(if held and not state.currentLooped and position >= lastFrame then 0 else state.playbackSpeed)
	state.needsSeek = false
end

local function play(state: State, humanoid: Humanoid, owner: boolean)
	if not owner then
		return
	end
	local presentation = state.presentation
	if presentation.impactId > 0 and not presentation.categoryConfirmed then
		return
	end
	local slot = if presentation.phase == "Fly" or presentation.phase == "Stun"
		then presentation.phase
		else presentation.phase .. "_" .. presentation.category
	local clip = Resolver.Resolve(clips, Config, state.weapon, slot)
	local duration = if presentation.transition then presentation.transition.duration else 0
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	if state.animator ~= animator then
		Reactions.ClearTracks(state)
		state.animator = animator
	end
	if state.preparedToken ~= presentation.token then
		-- Contact ends Fly even if the next clip is missing or fails to load.
		-- Prepare only once so retries cannot restart outgoing fades.
		clearCompletion(state)
		local incomingId = if clip then clip.AnimationId else nil
		for id, outgoingPhase in state.trackIds do
			local other = animator:GetTrackByAnimationId(id)
			if id ~= incomingId and other and other.IsPlaying then
				local stopDuration = if outgoingPhase == "Stun"
						or presentation.phase == "Stun"
						or (outgoingPhase == "Fly" and presentation.phase ~= "Fly")
					then Config.FlyFadeTime
					else duration
				other:Stop(stopDuration)
			end
		end
		state.preparedToken, state.retryAt = presentation.token, 0
	end
	if os.clock() < state.retryAt then
		return
	end
	if not clip then
		state.retryAt = os.clock() + 1
		warn("Missing Cartoon animation slot:", state.weapon, slot)
		return
	end
	local id = clip.AnimationId
	local continuing = state.playedToken == presentation.token and state.currentId == id
	local track = animator:GetTrackByAnimationId(id)
	if continuing then
		if track and track.Length > 0 then
			state.currentLength = track.Length
		end
		if track and track.IsPlaying then
			track.Priority, track.Looped = Enum.AnimationPriority.Action4, state.currentLooped
			if state.needsSeek then
				seekRestoredTrack(state, track)
			elseif not (state.catchupImpact == presentation.impactId and presentation.phase == "Bounce") then
				local held = presentation.phase == "Rest" or (presentation.phase == "Bounce" and FREEZE_BOUNCE)
				local atEnd = not state.currentLooped
					and track.Length > 0
					and track.TimePosition >= math.max(0, track.Length - BOUNCE_END_EPSILON)
				local speed = if held and atEnd then 0 else state.playbackSpeed
				if track.Speed ~= speed then
					track:AdjustSpeed(speed)
				end
			end
			if track.WeightTarget == 0 then
				track:AdjustWeight(1, duration)
			end
			return -- Healthy playback advances naturally; do not restart or seek every frame.
		end
		local elapsed = math.max(0, os.clock() - state.playbackStarted) * state.playbackSpeed
		local held = presentation.phase == "Rest" or (presentation.phase == "Bounce" and FREEZE_BOUNCE)
		if not state.currentLooped and not held and state.currentLength > 0 and elapsed >= state.currentLength then
			-- A naturally completed one-shot must not be mistaken for interrupted playback.
			if presentation.phase == "Bounce" then
				state.pendingCompletion = presentation.token
			end
			return
		end
	end
	if not track then
		local success, result = pcall(function()
			return animator:LoadAnimation(clip)
		end)
		if not success then
			state.retryAt = os.clock() + 1
			warn("Cartoon animation could not load:", clip:GetFullName(), result)
			return
		end
		local loaded: AnimationTrack = result
		if AuthoredLoops[id] == nil then
			AuthoredLoops[id] = loaded.Looped
		end
		track = loaded
	end
	if not track then
		return
	end
	if not continuing then
		clearCompletion(state)
		local authoredLoop = AuthoredLoops[id]
		local speed, looped =
			clipSettings(clip, presentation.phase, if authoredLoop ~= nil then authoredLoop else track.Looped)
		state.playbackSpeed, state.currentLooped = speed, looped
		state.playbackStarted, state.currentLength = os.clock(), 0
	end
	state.trackIds[id] = presentation.phase
	Playback.Register(state.playback, id) -- Register the ID before AnimationPlayed can fire.
	track.Priority, track.Looped = Enum.AnimationPriority.Action4, state.currentLooped
	if track.IsPlaying then
		track:AdjustWeight(1, duration)
		track:AdjustSpeed(state.playbackSpeed)
	else
		track:Play(duration, 1, state.playbackSpeed)
	end
	state.currentId, state.playedToken = id, presentation.token
	state.needsSeek = continuing
	if continuing then
		seekRestoredTrack(state, track)
	else
		track.TimePosition = 0
	end
	if track.Length > 0 then
		state.currentLength = track.Length
	end
	if state.localReactions and state.catchupImpact == presentation.impactId and presentation.phase == "Bounce" then
		track:AdjustSpeed(0) -- Wait for Length before seeking a streamed/late clip.
	end
end

local function freezeReaction(state: State, owner: boolean, dt: number?)
	local track = currentTrack(state)
	local phase = state.presentation.phase
	local hold = phase == "Rest" or (phase == "Bounce" and FREEZE_BOUNCE)
	if
		not hold
		or not owner
		or state.playedToken ~= state.presentation.token
		or not track
		or track.Looped
		or track.Length <= 0
	then
		return
	end
	local lastFrame = math.max(0, track.Length - BOUNCE_END_EPSILON)
	local step = if dt and dt == dt and dt >= 0 and dt < math.huge then dt else 1 / 60
	if track.IsPlaying then
		-- Check BEFORE Animator evaluation, including the upcoming animation step,
		-- so a short clip or a slow frame does not naturally end and fade away.
		if track.Speed == 0 and math.abs(track.TimePosition - lastFrame) <= BOUNCE_END_EPSILON then
			return
		end
		if track.TimePosition + math.max(0, track.Speed) * step < lastFrame then
			return
		end
		track:AdjustSpeed(0)
	else
		-- If the end was crossed before the check, restore only the final pose.
		-- The current reaction/token guard prevents reviving an interrupted clip.
		track:Play(0, 1, 0)
	end
	track.TimePosition = lastFrame
end

local function catchUpBounce(state: State)
	if not state.localReactions or not state.catchupImpact then
		return
	end
	local presentation, track = state.presentation, currentTrack(state)
	if presentation.phase ~= "Bounce" or presentation.impactId ~= state.catchupImpact then
		state.catchupImpact = nil
		return
	end
	if not track or state.playedToken ~= presentation.token or track.Length <= 0 then
		return
	end
	local position = state.catchupAge * state.playbackSpeed
	state.playbackStarted, state.currentLength, state.needsSeek = os.clock() - state.catchupAge, track.Length, false
	local lastFrame = math.max(0, track.Length - BOUNCE_END_EPSILON)
	track.TimePosition = if track.Looped then position % track.Length else math.min(position, lastFrame)
	track:AdjustSpeed(if not track.Looped and FREEZE_BOUNCE and position >= lastFrame then 0 else state.playbackSpeed)
	if
		not track.Looped
		and not FREEZE_BOUNCE
		and position >= math.max(0, track.Length - Config.BounceToFlyFadeTime * state.playbackSpeed)
	then
		state.pendingCompletion = presentation.token
	end
	state.catchupImpact = nil
end

function Reactions.Update(state, character, humanoid, dt)
	state.localReactions = DEFAULT_LOCAL_REACTIONS or character:GetAttribute("KnockbackActorKind") == "NPC"
	if Motion.GetState(character) == "Stop" then
		Reactions.Stop(state)
		return
	end
	local now = os.clock()
	if state.pausedAt then
		local paused = math.max(0, now - state.pausedAt)
		state.playbackStarted += paused
		if state.presentation.transition then
			state.presentation.transition.started += paused
		end
	end
	local animator = state.animator
	if character:GetAttribute("TimeStopped") == true then
		state.pausedAt = now
		if animator then
			for id in state.trackIds do
				local track = animator:GetTrackByAnimationId(id)
				if track then
					if state.pausedSpeeds[id] == nil then
						state.pausedSpeeds[id] = track.Speed
					end
					track:AdjustSpeed(0)
				end
			end
		end
		return
	end
	if state.pausedAt then
		state.pausedAt = nil
		if animator then
			for id, speed in state.pausedSpeeds do
				local track = animator:GetTrackByAnimationId(id)
				if track then
					track:AdjustSpeed(speed)
				end
			end
		end
		table.clear(state.pausedSpeeds)
	end
	if state.animator and state.animator.Parent ~= humanoid then
		state.resumePhase = phaseToResume(state)
		Reactions.Destroy(state, state.localReactions)
		if state.localReactions then
			Reactions.Observe(state, character, humanoid, true)
		end
	end
	local packet = Motion.GetPresentation(character)
	if packet and state.decisionPacket and state.decisionPacket ~= packet then
		Reactions.Stop(state)
		state.presentation = Reaction.New()
	end
	local revision = ReplicatedValues.GetNumber(character, "RagdollRevision")
	local generation = character:GetAttribute("RagdollGeneration")
	if packet then
		generation, revision = packet.generation, packet.revision
	end
	if type(generation) ~= "string" or type(revision) ~= "number" then
		return
	end
	local presentation = state.presentation
	local owner = true -- Every visual Animator is owned by this client.
	local drivesTracks = owner or state.localReactions
	local cache = if state.localReactions and packet then decisionsFor(state, packet) else nil
	local phase = if packet then packet.phase else ReplicatedValues.GetString(character, "RagdollPhase")
	local weapon = if packet then packet.weaponId else ReplicatedValues.GetString(character, "RagdollWeaponId")
	state.weapon = if type(weapon) == "string" then weapon else ""
	local wasNormal = presentation.phase == "Normal"
	local began = Reaction.Begin(
		presentation,
		generation,
		revision,
		(if wasNormal then Config.NormalToFlyFadeTime else Config.FlyFadeTime),
		now
	)
	if began then
		clearCompletion(state)
		state.retryAt = 0
		state.cleanupRevision += 1
		state.catchupImpact, state.catchupAge = nil, 0
	elseif wasNormal then
		state.cleanupRevision += 1
	end
	if not began and wasNormal then
		local duration = if state.resumePhase == "Rest"
			then Config.RestFadeTime
			elseif state.resumePhase == "Bounce" then Config.BounceFadeTime
			else Config.NormalToFlyFadeTime
		Reaction.Transition(presentation, state.resumePhase, duration, now)
	end
	if phase == "Stun" then
		if presentation.phase ~= "Stun" then
			clearCompletion(state)
			Reaction.Transition(presentation, "Stun", 0.05, now)
		end
		play(state, humanoid, drivesTracks)
		return -- No contact selection, completion or Fly playback before launch.
	elseif phase == "Fly" and presentation.phase == "Stun" then
		clearCompletion(state)
		Reaction.Transition(presentation, "Fly", Config.FlyFadeTime, now)
	end
	local contacted = false
	local lastImpactTime = -math.huge
	local lastOutcome: string? = nil
	if packet then
		-- On initial/streaming observation, retire old contact checkpoints at the
		-- current buffered time instead of displaying every missed collision.
		local bootstrap = (began and packet.bootstrap) or wasNormal
		local presentedTime = packet.presentedTime
		local due: { Combat.ReactionImpact } = {}
		for _, impact in packet.impacts do
			if impact.id <= presentation.impactId then
				lastImpactTime, lastOutcome = impact.time, impact.outcome
			end
			if impact.time <= presentedTime and impact.id > presentation.impactId then
				table.insert(due, impact)
			end
		end
		-- Joining/streaming clients restore the current presentation instead of replaying history.
		if bootstrap and #due > 1 then
			due = { due[#due] }
		end
		for _, impact in due do
			packet.consumedImpactId = math.max(packet.consumedImpactId or 0, impact.id)
			contacted, lastImpactTime = true, impact.time
			lastOutcome = impact.outcome
			local category = impact.category
			if state.localReactions and cache then
				category = localCategory(cache, impact, character, presentation.category)
			elseif not state.localReactions and owner and not category then
				local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
				category = if torso and torso:IsA("BasePart")
					then Reaction.Classify(torso.CFrame, impact.normal, presentation.category, impact.contactPosition)
					else presentation.category
			end
			local duration = (if impact.outcome == "Rebound" then Config.BounceFadeTime else Config.RestFadeTime)
			if Reaction.Contact(presentation, impact, category, duration, now) then
				clearCompletion(state)
				-- An already-finished bounce in initial state must not replay on join.
				state.catchupImpact = if state.localReactions and bootstrap then impact.id else nil
				state.catchupAge = math.max(0, presentedTime - impact.time)
				local completed = if state.localReactions
					then cache and cache.completed[impact.id]
					else impact.completed
				if completed and not FREEZE_BOUNCE then
					Reaction.Complete(presentation, presentation.token, impact.id, 0, now)
				end
				if not state.localReactions then
					play(state, humanoid, owner)
				end
			end
		end
	end
	-- Landing wins before checking natural completion, even if both occur this frame.
	if phase == "Slide" or phase == "Rest" then
		local keepBounce = presentation.phase == "Bounce" and lastOutcome == "Rebound"
		if state.localReactions then
			keepBounce = false
		end -- Authoritative landing wins.
		-- A wall rebound during Slide can hold its last pose; settling still enters Rest.
		if FREEZE_BOUNCE and phase == "Rest" and not contacted then
			keepBounce = false
		end
		if presentation.phase ~= "Rest" and not keepBounce then
			clearCompletion(state)
			Reaction.Transition(presentation, "Rest", Config.RestFadeTime, now)
		end
	elseif
		phase == "Fly"
		and presentation.phase == "Rest"
		and not contacted
		and packet
		and packet.phaseTime > lastImpactTime
	then
		clearCompletion(state)
		Reaction.Transition(presentation, "Fly", Config.FlyFadeTime, now)
	end
	if state.localReactions then
		-- Start only the final phase for this frame (never a stale bootstrap Bounce).
		play(state, humanoid, drivesTracks)
		if state.catchupImpact and packet then
			for _, impact in packet.impacts do
				if impact.id == state.catchupImpact then
					state.catchupAge = math.max(state.catchupAge, packet.presentedTime - impact.time)
					break
				end
			end
		end
		catchUpBounce(state)
	end
	-- Non-looping held reactions wait for contact/recovery. Looping Bounce also
	-- skips natural completion; a new impact or authoritative landing replaces it.
	if not FREEZE_BOUNCE then
		local completed = state.pendingCompletion == presentation.token
		local track = currentTrack(state)
		-- Begin the return crossfade just before the last frame, while Bounce still has weight.
		if
			drivesTracks
			and presentation.phase == "Bounce"
			and state.playedToken == presentation.token
			and track
			and not track.Looped
			and track.Length > 0
			and track.TimePosition >= math.max(0, track.Length - Config.BounceToFlyFadeTime * state.playbackSpeed)
		then
			completed = true
		end
		if not state.localReactions and not owner and packet then
			for _, impact in packet.impacts do
				if impact.id == presentation.impactId and impact.completed then
					completed = true
				end
			end
		end
		if completed and phase ~= "Stop" then
			local id = presentation.impactId
			if Reaction.Complete(presentation, presentation.token, id, Config.BounceToFlyFadeTime, now) then
				clearCompletion(state)
				if phase == "Slide" or phase == "Rest" then
					Reaction.Transition(presentation, "Rest", Config.RestFadeTime, now)
				end
				if state.localReactions then
					if cache and cache.categories[id] then
						cache.completed[id] = true
					end
				elseif owner then
				end
			end
		end
	end
	-- Selection can arrive AFTER this contact has been consumed. Resolve only
	-- the current impact, after phase/completion handling, without replaying it.
	if not state.localReactions and packet and not presentation.categoryConfirmed and presentation.impactId > 0 then
		for _, impact in packet.impacts do
			if impact.id == presentation.impactId and impact.category then
				Reaction.ConfirmCategory(
					presentation,
					impact.id,
					impact.category,
					(if presentation.phase == "Rest" then Config.RestFadeTime else Config.BounceFadeTime),
					now
				)
				break
			end
		end
	end
	play(state, humanoid, drivesTracks)
	freezeReaction(state, drivesTracks, dt)
end

return Reactions
