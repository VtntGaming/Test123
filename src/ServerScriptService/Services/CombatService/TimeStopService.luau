-- TimeStopService (SERVER ModuleScript) V3.1
-- SỬA LỖI: Caster KHÔNG BAO GIỜ bị freeze hay khóa tốc độ, di chuyển tự do 100%.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Clock = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("TimeStopClock"))
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))

local TimeStopService = {}

local deps = nil
local state = {
	session = nil, stopper = nil, character = nil, stopped = false, since = nil, config = nil,
	scope = nil, audience = {}, pose = nil,
}
local frozen = {}  -- [character] = saved state
local pending = {} -- [character] = { count, direction, context, strength }
local activeReleases = 0
local initialized = false

local ACTOR_TAGS = { "CombatActor", "ArenaNPC", "TraningNPC" }

-- ==========================================
-- SCOPE / AUDIENCE
-- ==========================================
local function casterScope(player)
	if player:GetAttribute("IsOnArena") then return "Arena" end
	if player:GetAttribute("IsInTrainingArea") then return "Training" end
	return nil
end

local function inScope(actor, scope)
	local player = Players:GetPlayerFromCharacter(actor)
	if scope == "Arena" then
		if player then
			return player:GetAttribute("IsOnArena") == true and not player:GetAttribute("TeleportingActive")
		end
		return CollectionService:HasTag(actor, "ArenaNPC")
	end
	if player then return false end -- cast trong training không ảnh hưởng người chơi khác
	return CollectionService:HasTag(actor, "TraningNPC")
end

local function buildAudience(stopper, scope)
	local list = { stopper }
	if scope == "Arena" then
		for _, p in Players:GetPlayers() do
			if p ~= stopper and p:GetAttribute("IsOnArena") then table.insert(list, p) end
		end
	end
	return list
end

local function fireTo(audience, ...)
	for _, p in audience do
		if p.Parent == Players then deps.AbilityEvent:FireClient(p, ...) end
	end
end

local function effectTo(audience, weaponId, position, direction)
	for _, p in audience do
		if p.Parent == Players then deps.EffectsEvent:FireClient(p, weaponId, position, direction) end
	end
end

-- ==========================================
-- HELPERS
-- ==========================================
local function waitUnless(session, seconds)
	local untilTime = os.clock() + seconds
	while os.clock() < untilTime do
		if state.session ~= session then return false end
		task.wait(0.05)
	end
	return state.session == session
end

local function isCaster(actor)
	if not actor then return false end
	if actor == state.character then return true end
	if state.stopper and Players:GetPlayerFromCharacter(actor) == state.stopper then return true end
	return false
end

local function playPose(character, animationId)
	if not animationId then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end
	local animation = Instance.new("Animation")
	animation.AnimationId = tostring(animationId)
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()
	if ok and track then
		track.Priority, track.Looped = Enum.AnimationPriority.Action3, false
		track:Play(0.1)
		state.pose = track
	end
end

local function stopPose()
	local track = state.pose
	state.pose = nil
	if track then
		track:Stop(0.2)
		task.delay(0.3, function() track:Destroy() end)
	end
end

-- ==========================================
-- FREEZE / UNFREEZE
-- ==========================================
local function freezeCharacter(character)
	-- BẢO VỆ TUYỆT ĐỐI: Không bao giờ đóng băng người tung chiêu
	if isCaster(character) or frozen[character] then return false end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then return false end
	if deps.Ragdoll.IsRagdolled(character) then return false end

	if deps.onFreeze then deps.onFreeze(character) end

	local saved = {
		humanoid = humanoid, root = root,
		walkSpeed = humanoid.WalkSpeed, jumpPower = humanoid.JumpPower, jumpHeight = humanoid.JumpHeight,
		anchored = root.Anchored, tracks = {},
	}
	humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight = 0, 0, 0
	root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
	root.Anchored = true

	-- Đóng băng animation của NPC phía Server
	if not Players:GetPlayerFromCharacter(character) then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				saved.tracks[track] = track.Speed
				track:AdjustSpeed(0)
			end
		end
	end

	frozen[character] = saved
	character:SetAttribute("TimeStopped", true)
	return true
end

local function unfreezeCharacter(character, saved)
	if character.Parent then
		if saved.root.Parent then saved.root.Anchored = false end
		if saved.humanoid.Parent then
			local defaultSpeed = (GameConfig and GameConfig.Movement and GameConfig.Movement.WalkSpeed) or 16
			saved.humanoid.WalkSpeed = (saved.walkSpeed and saved.walkSpeed > 0) and saved.walkSpeed or defaultSpeed
			saved.humanoid.JumpPower = saved.jumpPower
			saved.humanoid.JumpHeight = saved.jumpHeight
		end
		for track, speed in saved.tracks do
			if track.IsPlaying then track:AdjustSpeed(speed) end
		end
		character:SetAttribute("TimeStopped", nil)
	end
end

local function freezeEveryone(stopperCharacter, radius, scope)
	local stopperRoot = stopperCharacter:FindFirstChild("HumanoidRootPart")
	local victims = {}
	if not stopperRoot then return victims end
	local seen = {}
	local function consider(actor)
		if seen[actor] or not actor:IsA("Model") or isCaster(actor) then return end
		seen[actor] = true
		if not inScope(actor, scope) then return end
		local root = actor:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - stopperRoot.Position).Magnitude <= radius then
			if freezeCharacter(actor) then table.insert(victims, actor) end
		end
	end
	for _, tag in ACTOR_TAGS do
		for _, actor in CollectionService:GetTagged(tag) do consider(actor) end
	end
	for _, player in Players:GetPlayers() do
		if player.Character and not isCaster(player.Character) then consider(player.Character) end
	end
	return victims
end

-- ==========================================
-- RELEASE
-- ==========================================
local function releaseOne(character, entry, config, stopper, audience)
	local interval = config.HitInterval or 0.08
	local perHit = config.PerHitKnockback or 0.08
	local maxMultiplier = config.MaxKnockbackMultiplier or 2.5
	local direction = if entry.direction.Magnitude > 0.01 then entry.direction.Unit else Vector3.zAxis
	local context = entry.context
	local baseMultiplier = context.knockbackMultiplier or 1
	local landed = 0

	for i = 1, entry.count do
		if not character:IsDescendantOf(Workspace) then break end
		local strength = math.clamp(entry.strength + (config.FinishStrengthPerHit or 0.03) * (i - 1), 1, 1.5)
		local multiplier = math.min(baseMultiplier * (1 + perHit * (i - 1)), maxMultiplier)
		local ok = deps.Ragdoll.ApplyHit(character, direction, {
			weaponId = context.weaponId, strength = strength, knockbackMultiplier = multiplier,
		})
		if ok then
			landed += 1
			if stopper and stopper.Parent == Players then
				character:SetAttribute("LastHitBy", stopper.Name)
			end
		end
		local position = deps.Ragdoll.GetAuthoritativePosition(character)
		if position then effectTo(audience, context.weaponId, position, direction) end
		fireTo(audience, "TimeStopHit", character, i, entry.count)
		if i < entry.count then task.wait(interval) end
	end

	if landed > 0 and stopper and stopper.Parent == Players and stopper:GetAttribute("IsOnArena") then
		stopper:SetAttribute("MatchHits", (stopper:GetAttribute("MatchHits") or 0) + landed)
	end
end

local function applyPending(config, stopper, audience)
	local list = {}
	for character, entry in pending do table.insert(list, { character, entry }) end
	table.clear(pending)

	for _, item in list do
		activeReleases += 1
		task.spawn(function()
			local ok, err = pcall(releaseOne, item[1], item[2], config, stopper, audience)
			activeReleases -= 1
			if not ok then warn("[TimeStopService] release failed:", err) end
		end)
	end
end

-- ==========================================
-- PUBLIC
-- ==========================================
function TimeStopService.IsStopped()
	return state.stopped
end

function TimeStopService.IsFrozen(actor)
	if isCaster(actor) then return false end
	return state.stopped and frozen[actor] ~= nil
end
TimeStopService.IsFrozenTarget = TimeStopService.IsFrozen

function TimeStopService.CanStart(player)
	if state.session or activeReleases > 0 then return false end
	return casterScope(player) ~= nil
end

function TimeStopService.GetAttackCooldownScale(actor)
	if state.stopped and actor == state.character then
		return (state.config and state.config.AttackCooldownScale) or 1
	end
	return 1
end

function TimeStopService.InterceptHit(actor, direction, context)
	if not state.stopped or not frozen[actor] then return false end
	if typeof(direction) ~= "Vector3" or type(context) ~= "table" then return true end
	if context.attacker and context.attacker ~= state.character then return true end

	local entry = pending[actor]
	if not entry then
		entry = { count = 0, direction = Vector3.zero, context = context, strength = 1 }
		pending[actor] = entry
	end
	entry.count += 1
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude > 0.001 then entry.direction += flat.Unit end
	entry.context = context
	entry.strength = math.max(entry.strength, type(context.strength) == "number" and context.strength or 1)

	fireTo(state.audience, "TimeStopMark", actor, entry.count)
	if typeof(context.position) == "Vector3" then
		effectTo(state.audience, context.weaponId, context.position, direction)
	end
	return true
end

function TimeStopService.Cancel(session)
	if not state.session then return end
	if session and state.session ~= session then return end

	local config, stopper, character = state.config, state.stopper, state.character
	local wasStopped, audience = state.stopped, state.audience
	state.session, state.stopper, state.character, state.stopped, state.since = nil, nil, nil, false, nil
	state.config, state.scope, state.audience = nil, nil, {}

	stopPose()

	if wasStopped then
		Clock.End(Workspace:GetServerTimeNow())
		if character and character.Parent then character:SetAttribute("TimeStopActive", nil) end
		ReplicatedStorage:SetAttribute("TimeStopActive", nil)
		for victim, saved in frozen do unfreezeCharacter(victim, saved) end
		table.clear(frozen)
		local totalHits = 0
		for _, entry in pending do totalHits += entry.count end
		fireTo(audience, "TimeStopEnd", stopper, { at = Workspace:GetServerTimeNow(), total = totalHits })
		applyPending(config, stopper, audience)
	else
		fireTo(audience, "TimeStopCancel", stopper)
	end
end

function TimeStopService.Start(player, character, config, effect)
	TimeStopService.Cancel()
	local scope = casterScope(player)
	if not scope then return end

	local session = {}
	state.session, state.stopper, state.character, state.config = session, player, character, config
	state.scope = scope
	state.audience = buildAudience(player, scope)
	effect.restore = function() TimeStopService.Cancel(session) end

	local ready = config.ReadyTime or 2.0
	local duration = config.StopDuration or 8
	local radius = config.Radius or 200

	-- BẢO ĐẢM CASTER KHÔNG BỊ KHÓA TỐC ĐỘ:
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		local defaultSpeed = (GameConfig and GameConfig.Movement and GameConfig.Movement.WalkSpeed) or 16
		if hum.WalkSpeed <= 0 then hum.WalkSpeed = defaultSpeed end
	end

	playPose(character, config.Animation)
	fireTo(state.audience, "TimeStopReady", player, character, {
		readyTime = ready, stopDuration = duration, radius = radius,
		startTime = Workspace:GetServerTimeNow(),
	})

	task.spawn(function()
		if not waitUnless(session, ready) then return end

		-- THỜI GIAN NGƯNG ĐỌNG
		stopPose() -- Ngắt pose ngay khi bước vào TimeStop để caster thoải mái chém/di chuyển
		state.audience = buildAudience(player, scope)
		local since = Workspace:GetServerTimeNow()
		state.stopped, state.since = true, since
		Clock.Begin(since)
		character:SetAttribute("TimeStopActive", true)
		ReplicatedStorage:SetAttribute("TimeStopActive", true)

		local victims = freezeEveryone(character, radius, scope)
		fireTo(state.audience, "TimeStopStart", player, character, {
			since = since, stopDuration = duration, radius = radius, scope = scope, victims = victims,
		})

		if not waitUnless(session, duration) then return end
		TimeStopService.Cancel(session)
	end)
end

function TimeStopService.Init(dependencies)
	if initialized then return end
	initialized = true
	deps = dependencies

	local function onCharacter(player, character)
		if not state.stopped or player == state.stopper then return end
		task.spawn(function()
			character:WaitForChild("HumanoidRootPart", 5)
			character:WaitForChild("Humanoid", 5)
			if state.stopped and not isCaster(character) and not frozen[character] and inScope(character, state.scope) then
				freezeCharacter(character)
			end
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character) onCharacter(player, character) end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function(character) onCharacter(player, character) end)
	end

	Players.PlayerRemoving:Connect(function(player)
		if player == state.stopper then TimeStopService.Cancel() end
	end)
end

return TimeStopService
