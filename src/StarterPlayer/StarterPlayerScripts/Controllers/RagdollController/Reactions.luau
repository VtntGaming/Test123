--!strict
local SharedConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local Combat = require(game:GetService("ReplicatedStorage"):WaitForChild("Combat"))
local Knockback = require(game:GetService("ReplicatedStorage"):WaitForChild("Knockback"))
-- Owner-confirmed reactions by default; optional independent playback on each client.
local Reactions = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local NetworkConfig = SharedConfig.Network
local Reaction = Combat.Reaction
local Resolver = Combat.AnimationResolver
local Config = SharedConfig.Animation
local FREEZE_BOUNCE = Config.FreezeBounceAtLastFrame == true
local DEFAULT_LOCAL_REACTIONS = Config.LocalReactionPrediction == true
local Playback = require(script.Parent:WaitForChild("Playback"))
local BOUNCE_END_EPSILON = 0.0001 -- Stay just inside the end so the track retains its pose.
local Motion = require(script.Parent:WaitForChild("CartoonPresentation"))
local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("KnockbackReaction") :: RemoteEvent
local clips = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Knockback")

-- Bounded local choices for one motion session; reused across temporary streaming removal.
type Decisions = {
	categories: { [number]: string }, -- Chosen reaction category indexed by collision ID.
	completed: { [number]: boolean }, -- Bounce completion flags indexed by collision ID.
	order: { number } -- Insertion order of collision IDs, used to evict choices beyond the cache limit.
}
-- Weak packet keys retain choices across streaming without owning motion sessions.
local decisionCaches = setmetatable({} :: { [Knockback.StreamRecord]: Decisions }, { __mode = "k" })

-- Animation resources and presentation bookkeeping for one character.
export type State = {
	presentation: Combat.ReactionState, -- Shared phase, category, hit identity, and blend timing.
	tracks: { [Animation]: AnimationTrack }, -- Reusable loaded animation tracks indexed by their Animation instance.
	animator: Animator?, -- Animator that owns the cached tracks; replacement invalidates the cache.
	current: AnimationTrack?, -- Track selected for the current reaction, if one is available.
	stopped: RBXScriptConnection?, -- Current Bounce Stopped listener used to detect natural completion.
	playedToken: number, -- Last transition token whose animation playback was started.
	pendingCompletion: number?, -- Transition token awaiting Bounce completion handling.
	retryAt: number, -- Local os.clock() deadline before retrying a missing or failed animation.
	weapon: string, -- Weapon family used to resolve animation slots.
	resumePhase: string, -- Phase to restore after presentation temporarily stops or streams out.
	preparedToken: number, -- Last transition whose outgoing tracks were prepared, preventing repeated fades.
	playback: Playback.State, -- Track-identity registration and competing-animation filter state.
	cleanupRevision: number, -- Invalidates delayed track destruction when a new reaction starts.
	decisionPacket: Knockback.StreamRecord?, -- Motion record owning this character's current local decision cache.
	catchupImpact: number?, -- Collision ID whose Bounce track needs a late/streaming playback seek.
	catchupAge: number, -- Buffered seconds since that impact, used to seek Bounce playback.
	playbackSpeed: number, -- Configured playback multiplier for the current clip.
	localReactions: boolean, -- Whether this client chooses reactions itself; always true for NPCs.
}

function Reactions.New(): State
	return {
		presentation = Reaction.New(),
		tracks = {},
		animator = nil,
		current = nil,
		stopped = nil,
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

local function decisionsFor(state: State, packet: Knockback.StreamRecord): Decisions
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

function Reactions.Observe(state: State, character: Model, humanoid: Humanoid?, active: boolean)
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

local function disconnect(state: State)
	if state.stopped then
		state.stopped:Disconnect()
		state.stopped = nil
	end
	state.pendingCompletion = nil
end

local function phaseToResume(state: State): string
	local phase = state.presentation.phase
	return if phase == "Stun"
			or phase == "Rest"
			or (phase == "Bounce" and (FREEZE_BOUNCE or (state.current ~= nil and state.current.Looped)))
		then phase
		else "Fly"
end

function Reactions.Stop(state: State, preserveDecisions: boolean?)
	if state.localReactions and not preserveDecisions then
		forgetDecisions(state)
	end
	if state.presentation.phase == "Normal" and not state.current then
		return
	end
	disconnect(state)
	state.resumePhase = phaseToResume(state)
	local duration = (
		if state.presentation.phase == "Rest" then Config.RestToNormalFadeTime else Config.FlyFadeTime
	)
	Reaction.Transition(state.presentation, "Normal", duration, os.clock())
	for _, track in state.tracks do
		if track.IsPlaying then
			track:Stop(duration)
		end
	end
	state.current, state.playedToken = nil, -1
	if state.localReactions then
		state.cleanupRevision += 1
		local cleanup = state.cleanupRevision
		-- Keep identity exemptions until the recovery fade has finished.
		task.delay(duration + 0.1, function()
			if state.cleanupRevision == cleanup and state.presentation.phase == "Normal" then
				Reactions.ClearTracks(state)
			end
		end)
	end
end

-- Release playback without cancelling the torso's recovery transition.
function Reactions.ClearTracks(state: State)
	state.cleanupRevision += 1
	disconnect(state)
	for _, track in state.tracks do
		track:Stop(0)
		Playback.Unregister(state.playback, track)
		track:Destroy()
	end
	table.clear(state.tracks)
	state.current, state.animator, state.playedToken, state.preparedToken = nil, nil, -1, -1
end

function Reactions.Destroy(state: State, preserveDecisions: boolean?)
	if preserveDecisions and state.presentation.phase ~= "Normal" then
		state.resumePhase = phaseToResume(state)
	end
	-- A queued Stopped callback can still arrive after Disconnect.
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

local function play(state: State, humanoid: Humanoid, owner: boolean)
	if not owner or state.playedToken == state.presentation.token then
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
	if state.preparedToken ~= presentation.token then
		-- Contact ends Fly even if the next clip is missing or fails to load.
		-- Prepare only once so retries cannot restart outgoing fades.
		disconnect(state)
		local incoming = if clip then state.tracks[clip] else nil
		for animation, other in state.tracks do
			if other ~= incoming and other.IsPlaying then
				local stopDuration = if animation.Name == "Stun"
						or presentation.phase == "Stun"
						or (animation.Name == "Fly" and presentation.phase ~= "Fly")
					then Config.FlyFadeTime
					else duration
				other:Stop(stopDuration)
			end
		end
		state.current = incoming
		state.preparedToken, state.retryAt = presentation.token, 0
	end
	if os.clock() < state.retryAt then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	if state.animator ~= animator then
		disconnect(state)
		for _, track in state.tracks do
			track:Stop(0)
			Playback.Unregister(state.playback, track)
			track:Destroy()
		end
		table.clear(state.tracks)
		state.current, state.animator = nil, animator
	end
	if not clip then
		state.retryAt = os.clock() + 1
		warn("Missing Cartoon animation slot:", state.weapon, slot)
		return
	end
	local track: AnimationTrack? = state.tracks[clip]
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
		loaded.Priority = Enum.AnimationPriority.Action4
		state.tracks[clip] = loaded
		Playback.Register(state.playback, loaded) -- Register before AnimationPlayed can fire.
		track = loaded
	end
	if not track then
		return
	end
	disconnect(state)
	local speed, looped = clipSettings(clip, presentation.phase, track.Looped)
	state.playbackSpeed = speed
	track.Looped = looped
	if track.IsPlaying then
		track:AdjustWeight(1, duration)
		track:AdjustSpeed(speed) -- Resume a held track using this clip's configured speed.
	else
		track:Play(duration, 1, speed)
	end
	track.TimePosition = 0
	if
		state.localReactions
		and state.catchupImpact == presentation.impactId
		and presentation.phase == "Bounce"
	then
		track:AdjustSpeed(0) -- Wait for Length before seeking a streamed/late clip.
	end
	state.current, state.playedToken = track, presentation.token
	if presentation.phase == "Bounce" and not track.Looped and not FREEZE_BOUNCE then
		local token = presentation.token
		state.stopped = track.Stopped:Connect(function()
			if state.presentation.token == token then
				state.pendingCompletion = token
			end
		end)
	end
end

local function freezeReaction(state: State, owner: boolean, dt: number?)
	local track = state.current
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
	local presentation, track = state.presentation, state.current
	if presentation.phase ~= "Bounce" or presentation.impactId ~= state.catchupImpact then
		state.catchupImpact = nil
		return
	end
	if not track or state.playedToken ~= presentation.token or track.Length <= 0 then
		return
	end
	local position = state.catchupAge * state.playbackSpeed
	local lastFrame = math.max(0, track.Length - BOUNCE_END_EPSILON)
	track.TimePosition = if track.Looped then position % track.Length else math.min(position, lastFrame)
	track:AdjustSpeed(
		if not track.Looped and FREEZE_BOUNCE and position >= lastFrame then 0 else state.playbackSpeed
	)
	if
		not track.Looped
		and not FREEZE_BOUNCE
		and position >= math.max(0, track.Length - Config.BounceToFlyFadeTime * state.playbackSpeed)
	then
		state.pendingCompletion = presentation.token
	end
	state.catchupImpact = nil
end

function Reactions.Update(state: State, character: Model, humanoid: Humanoid, dt: number?)
	state.localReactions = DEFAULT_LOCAL_REACTIONS or character:GetAttribute("KnockbackActorKind") == "NPC"
	if Motion.GetState(character) == "Stop" then
		Reactions.Stop(state)
		return
	end
	if state.animator and state.animator.Parent ~= humanoid then
		state.resumePhase = phaseToResume(state)
		Reactions.Destroy(state, state.localReactions)
		if state.localReactions then
			Reactions.Observe(state, character, humanoid, true)
		end
	end
	local packet = Motion.GetPresentation(character)
	local revision = character:GetAttribute("RagdollRevision")
	local generation = character:GetAttribute("RagdollGeneration")
	if packet then
		generation, revision = packet.generation, packet.revision
	end
	if type(generation) ~= "string" or type(revision) ~= "number" then
		return
	end
	local presentation, now = state.presentation, os.clock()
	local owner = Players.LocalPlayer.Character == character
	local drivesTracks = owner or state.localReactions
	local cache = if state.localReactions and packet then decisionsFor(state, packet) else nil
	local phase = if packet then packet.phase else character:GetAttribute("RagdollPhase")
	local weapon = if packet then packet.weaponId else character:GetAttribute("RagdollWeaponId")
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
		disconnect(state)
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
			disconnect(state)
			Reaction.Transition(presentation, "Stun", 0.05, now)
		end
		play(state, humanoid, drivesTracks)
		return -- No contact selection, completion or Fly playback before launch.
	elseif phase == "Fly" and presentation.phase == "Stun" then
		disconnect(state)
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
		if state.localReactions and bootstrap then
			presentedTime = math.max(
				presentedTime,
				math.min(packet.timestamp, Workspace:GetServerTimeNow() - NetworkConfig.InterpolationDelay)
			)
			for _, sample in packet.packets do
				if sample.time <= presentedTime then
					phase = sample.phase
				end
			end
		end
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
					then Reaction.Classify(
						torso.CFrame,
						impact.normal,
						presentation.category,
						impact.contactPosition
					)
					else presentation.category
				remote:FireServer(generation, revision, impact.id, "Select", category)
				Motion.RecordReactionSend()
			end
			local duration = (
				if impact.outcome == "Rebound" then Config.BounceFadeTime else Config.RestFadeTime
			)
			if Reaction.Contact(presentation, impact, category, duration, now) then
				disconnect(state)
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
			disconnect(state)
			Reaction.Transition(presentation, "Rest", Config.RestFadeTime, now)
		end
	elseif
		phase == "Fly"
		and presentation.phase == "Rest"
		and not contacted
		and packet
		and packet.phaseTime > lastImpactTime
	then
		disconnect(state)
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
		local track = state.current
		-- Begin the return crossfade just before the last frame, while Bounce still has weight.
		if
			drivesTracks
			and presentation.phase == "Bounce"
			and state.playedToken == presentation.token
			and track
			and not track.Looped
			and track.Length > 0
			and track.TimePosition
				>= math.max(0, track.Length - Config.BounceToFlyFadeTime * state.playbackSpeed)
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
				disconnect(state)
				if phase == "Slide" or phase == "Rest" then
					Reaction.Transition(presentation, "Rest", Config.RestFadeTime, now)
				end
				if state.localReactions then
					if cache and cache.categories[id] then
						cache.completed[id] = true
					end
				elseif owner then
					remote:FireServer(generation, revision, id, "Complete")
					Motion.RecordReactionSend()
				end
			end
		end
	end
	-- Selection can arrive AFTER this contact has been consumed. Resolve only
	-- the current impact, after phase/completion handling, without replaying it.
	if
		not state.localReactions
		and packet
		and not presentation.categoryConfirmed
		and presentation.impactId > 0
	then
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
