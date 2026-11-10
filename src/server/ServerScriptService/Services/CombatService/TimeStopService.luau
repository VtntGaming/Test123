-- Owns scoped TimeStop sessions and generation-safe freeze restoration across actor resets.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ReplicatedValues = require(ReplicatedStorage.ReplicatedValues)
local PlayerData = require(ReplicatedStorage.PlayerData)
local Clock = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("TimeStopClock"))
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))

local SimulationState = require(ReplicatedStorage.Simulation.State)
local Simulation = require(ReplicatedStorage.Simulation)
local TimeStopService = {}

local deps = nil
local state = {
	session = nil, stopper = nil, character = nil, stopped = false, since = nil, config = nil,
	scope = nil, audience = {}, pose = nil,
}
local frozen = {}  -- [character] = saved state
local pending = {} -- [character] = { count, direction, context, strength }
local releases = {} -- Barrages waiting for their queued unfreeze to complete.
local activeReleases = 0
local initialized = false

local ACTOR_TAGS = { "CombatActor", "ArenaNPC", "LobbyNPC" }

type FreezeSnapshot = {
	humanoid: Humanoid,
	root: BasePart,
	walkSpeed: number,
	jumpPower: number,
	jumpHeight: number,
	anchored: boolean,
	generation: string?,
	applied: boolean,
}

-- ==========================================
-- SCOPE / AUDIENCE
-- ==========================================
local function casterScope(player)
	if PlayerData.Get(player, "IsOnArena") then
		return "Arena"
	end
	if PlayerData.Get(player, "IsInTrainingArea") then
		return "Training"
	end
	return nil
end

local function inScope(actor, scope)
	local player = Players:GetPlayerFromCharacter(actor)
	if scope == "Arena" then
		if player then
			return PlayerData.Get(player, "IsOnArena") == true and not PlayerData.Get(player, "TeleportingActive")
		end
		return CollectionService:HasTag(actor, "ArenaNPC")
	end
	if player then return false end -- cast trong training không ảnh hưởng người chơi khác
	return CollectionService:HasTag(actor, "LobbyNPC")
end

local function buildAudience(stopper, scope)
	local list = { stopper }
	if scope == "Arena" then
		for _, p in Players:GetPlayers() do
			if p ~= stopper and PlayerData.Get(p, "IsOnArena") then
				table.insert(list, p)
			end
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

local function isCaster(actor)
	if not actor then return false end
	if actor == state.character then return true end
	if state.stopper and Players:GetPlayerFromCharacter(actor) == state.stopper then return true end
	return false
end

local function SameLifetime(character: Model, saved: FreezeSnapshot): boolean
	return character:IsDescendantOf(Workspace)
		and character:GetAttribute("RagdollGeneration") == saved.generation
		and character:FindFirstChild("HumanoidRootPart") == saved.root
		and character:FindFirstChildOfClass("Humanoid") == saved.humanoid
end

-- ==========================================
-- FREEZE / UNFREEZE
-- ==========================================
local function freezeCharacter(character)
	-- BẢO VỆ TUYỆT ĐỐI: Không bao giờ đóng băng người tung chiêu
	if not character:IsDescendantOf(Workspace) or isCaster(character) or frozen[character] then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local record = SimulationState.Records[character]
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false
	end
	if
		not record
		or not record.Ready
		or record.Root ~= root
		or record.Generation ~= character:GetAttribute("RagdollGeneration")
	then
		return false
	end

	if deps.onFreeze then
		deps.onFreeze(character)
	end

	local saved: FreezeSnapshot = {
		humanoid = humanoid,
		root = root,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
		anchored = root.Anchored,
		generation = character:GetAttribute("RagdollGeneration"),
		applied = false,
	}
	local session = state.session
	frozen[character] = saved
	SimulationState.Queue(character, function()
		if
			state.session ~= session
			or not state.stopped
			or frozen[character] ~= saved
			or not SameLifetime(character, saved)
			or not inScope(character, state.scope)
			or humanoid.Health <= 0
		then
			if frozen[character] == saved then
				frozen[character], pending[character] = nil, nil
			end
			return
		end
		-- Earlier reset/cancel commands may still be queued when this entry is enrolled.
		saved.walkSpeed, saved.jumpPower, saved.jumpHeight = humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight
		saved.anchored = root.Anchored
		saved.applied = true
		character:SetAttribute("TimeStopped", true)
		humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight = 0, 0, 0
		root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
		root.Anchored = true
	end)
	return true
end

local function unfreezeCharacter(character, saved)
	if not SameLifetime(character, saved) then
		return
	end
	SimulationState.Queue(character, function()
		-- A queued restore must never unlock a replacement lifetime or a newer freeze.
		if
			not saved.applied
			or not SameLifetime(character, saved)
			or (frozen[character] and frozen[character] ~= saved)
		then
			return
		end
		saved.applied = false
		character:SetAttribute("TimeStopped", nil)
		local locked = character:GetAttribute("IsFrozen") == true or character:GetAttribute("MovementLocked") == true
		if saved.root.Parent then
			saved.root.Anchored = saved.anchored
		end
		if saved.humanoid.Parent then
			saved.humanoid.WalkSpeed = if locked then 0 else saved.walkSpeed
			saved.humanoid.JumpPower = if locked then 0 else saved.jumpPower
			saved.humanoid.JumpHeight = if locked then 0 else saved.jumpHeight
		end
	end)
end

local function freezeEveryone(stopperCharacter, radius, scope)
	local stopperRoot = stopperCharacter:FindFirstChild("HumanoidRootPart")
	local victims = {}
	if not stopperRoot or not stopperRoot:IsA("BasePart") then
		return victims
	end
	local seen = {}
	local function consider(actor)
		if seen[actor] or not actor:IsA("Model") or isCaster(actor) then
			return
		end
		seen[actor] = true
		if not inScope(actor, scope) then
			return
		end
		local root = actor:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - stopperRoot.Position).Magnitude <= radius then
			if freezeCharacter(actor) then
				table.insert(victims, actor)
			end
		end
	end
	for _, tag in ACTOR_TAGS do
		for _, actor in CollectionService:GetTagged(tag) do
			consider(actor)
		end
	end
	for _, player in Players:GetPlayers() do
		if player.Character and not isCaster(player.Character) then
			consider(player.Character)
		end
	end
	return victims
end

local function RefreshFrozen(): boolean
	local changed = false
	for character, saved in frozen do
		if not SameLifetime(character, saved) or not inScope(character, state.scope) or saved.humanoid.Health <= 0 then
			frozen[character], pending[character] = nil, nil
			unfreezeCharacter(character, saved)
			changed = true
		end
	end
	return changed
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
		if
			not character:IsDescendantOf(Workspace)
			or character:GetAttribute("RagdollGeneration") ~= entry.generation
		then
			break
		end
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

	if landed > 0 and stopper and stopper.Parent == Players and PlayerData.Get(stopper, "IsOnArena") then
		PlayerData.Set(stopper, "MatchHits", (PlayerData.Get(stopper, "MatchHits") or 0) + landed)
	end
end

local function applyPending(config, stopper, audience)
	for character, entry in pending do
		local saved = frozen[character]
		if saved and SameLifetime(character, saved) and entry.generation == saved.generation then
			activeReleases += 1
			table.insert(releases, {
				character = character,
				entry = entry,
				saved = saved,
				config = config,
				stopper = stopper,
				audience = audience,
			})
		end
	end
	table.clear(pending)
end

local function DrainReleases()
	for index = #releases, 1, -1 do
		local item = releases[index]
		if not SameLifetime(item.character, item.saved) then
			table.remove(releases, index)
			activeReleases -= 1
		elseif not item.saved.applied then
			table.remove(releases, index)
			task.spawn(function()
				local ok, err = pcall(releaseOne, item.character, item.entry, item.config, item.stopper, item.audience)
				activeReleases -= 1
				if not ok then
					warn("[TimeStopService] release failed:", err)
				end
			end)
		end
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
	local saved = frozen[actor]
	return state.stopped and saved ~= nil and SameLifetime(actor, saved)
		and saved.humanoid.Health > 0 and inScope(actor, state.scope)
end
TimeStopService.IsFrozenTarget = TimeStopService.IsFrozen

function TimeStopService.CanStart(player)
	if state.session or activeReleases > 0 then
		return false
	end
	return casterScope(player) ~= nil
end

function TimeStopService.GetAttackCooldownScale(actor)
	if state.stopped and actor == state.character then
		return (state.config and state.config.AttackCooldownScale) or 1
	end
	return 1
end

function TimeStopService.InterceptHit(actor, direction, context)
	if not TimeStopService.IsFrozen(actor) then return false end
	if typeof(direction) ~= "Vector3" or type(context) ~= "table" then return true end
	if context.attacker and context.attacker ~= state.character then return true end

	local entry = pending[actor]
	if not entry or entry.generation ~= actor:GetAttribute("RagdollGeneration") then
		entry = {
			count = 0,
			direction = Vector3.zero,
			context = context,
			strength = 1,
			generation = actor:GetAttribute("RagdollGeneration"),
		}
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
	local wasStopped, audience, scope = state.stopped, state.audience, state.scope
	state.session, state.stopper, state.character, state.stopped, state.since = nil, nil, nil, false, nil
	state.config, state.scope, state.audience = nil, nil, {}
	state.readyAt, state.endsAt = nil, nil
	state.generation, state.nextScanAt = nil, nil

	if wasStopped then
		Clock.End(time(), scope)
		if character and character.Parent then
			SimulationState.Queue(character, function()
				if state.character == character and state.stopped then
					return
				end
				character:SetAttribute("TimeStopActive", nil)
			end)
		end
		ReplicatedValues.Set(ReplicatedStorage, "TimeStopActive", nil)
		for victim, saved in frozen do
			unfreezeCharacter(victim, saved)
		end
		local totalHits = 0
		for _, entry in pending do
			totalHits += entry.count
		end
		fireTo(audience, "TimeStopEnd", stopper, { at = time(), total = totalHits })
		applyPending(config, stopper, audience)
		table.clear(frozen)
	else
		fireTo(audience, "TimeStopCancel", stopper)
	end
end

function TimeStopService.Start(player, character, config, effect)
	TimeStopService.Cancel()
	local scope = casterScope(player)
	if not scope then
		return
	end

	local session = {}
	state.session, state.stopper, state.character, state.config = session, player, character, config
	state.scope = scope
	state.generation = character:GetAttribute("RagdollGeneration")
	state.audience = buildAudience(player, scope)
	effect.restore = function()
		TimeStopService.Cancel(session)
	end

	local ready = config.ReadyTime or 2.0
	local duration = config.StopDuration or 8
	local radius = config.Radius or 200

	-- BẢO ĐẢM CASTER KHÔNG BỊ KHÓA TỐC ĐỘ:
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		local defaultSpeed = (GameConfig and GameConfig.Movement and GameConfig.Movement.WalkSpeed) or 16
		if hum.WalkSpeed <= 0 then
			hum.WalkSpeed = defaultSpeed
		end
	end

	fireTo(state.audience, "TimeStopReady", player, character, {
		readyTime = ready,
		stopDuration = duration,
		radius = radius,
		startTime = time(),
	})

	state.readyAt, state.endsAt = time() + ready, time() + ready + duration
end

function TimeStopService.Init(dependencies)
	if initialized then
		return
	end
	initialized = true
	deps = dependencies

	Simulation.AfterStep(function(dt, now)
		DrainReleases()
		if not state.session then
			return
		end
		local character, player, config = state.character, state.stopper, state.config
		if
			not character.Parent
			or player.Character ~= character
			or character:GetAttribute("RagdollGeneration") ~= state.generation
			or casterScope(player) ~= state.scope
			or PlayerData.Get(player, "TeleportingActive")
		then
			TimeStopService.Cancel()
			return
		end
		if not state.stopped and now >= state.readyAt then
			state.audience = buildAudience(player, state.scope)
			state.stopped, state.since = true, now
			Clock.Begin(now, state.scope)
			local session = state.session
			SimulationState.Queue(character, function()
				if state.session ~= session or not state.stopped then
					return
				end
				character:SetAttribute("TimeStopActive", true)
			end)
			ReplicatedValues.Set(ReplicatedStorage, "TimeStopActive", true)
			local victims = freezeEveryone(character, config.Radius or 200, state.scope)
			state.nextScanAt = now + 0.1
			fireTo(state.audience, "TimeStopStart", player, character, {
				since = now,
				stopDuration = config.StopDuration or 8,
				radius = config.Radius or 200,
				scope = state.scope,
				victims = victims,
			})
		elseif state.stopped and now >= state.endsAt then
			TimeStopService.Cancel(state.session)
		elseif state.stopped then
			-- Resets can reuse the Model; CharacterAdded alone cannot observe them.
			local changed = RefreshFrozen()
			if changed or now >= state.nextScanAt then
				freezeEveryone(character, config.Radius or 200, state.scope)
				state.nextScanAt = now + 0.1
			end
		end
	end, 20)

	Players.PlayerRemoving:Connect(function(player)
		if player == state.stopper then
			TimeStopService.Cancel()
		end
	end)
end

return TimeStopService
