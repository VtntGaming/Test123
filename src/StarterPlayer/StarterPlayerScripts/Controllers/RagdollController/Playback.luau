--!strict
-- Keep the real Animator. Identity exemptions protect our tracks even when slots
-- share an asset; observer filters also reject delayed replicated reaction tracks.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local SharedConfig = require(ReplicatedStorage:WaitForChild("Config"))
local WeaponCatalog = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("WeaponConfig"))
local Motion = require(script.Parent:WaitForChild("CartoonPresentation"))
local Playback = {}
local LOCAL_PLAYERS = SharedConfig.Animation.LocalReactionPrediction == true
local clips = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Knockback")
local reactionIds: {[string]: boolean} = {}
local weaponIds: {[string]: boolean} = {}
local defaultNames: {[string]: boolean} = {
	idle = true, walk = true, run = true, swim = true, swimidle = true,
	jump = true, fall = true, climb = true, sit = true, wave = true,
	point = true, dance = true, dance2 = true, dance3 = true, laugh = true, cheer = true,
}

local function assetId(value: string): string?
	return string.match(value, "^%s*rbxassetid://(%d+)")
		or string.match(value, "[?&]id=(%d+)") or string.match(value, "^%s*(%d+)%s*$")
end

for _, item in clips:GetDescendants() do
	if item:IsA("Animation") then
		local id = assetId(item.AnimationId)
		if id then reactionIds[id] = true end
	end
end
for _, weapon in WeaponCatalog.BaseWeapons do
	for _, value in {weapon.Idle, weapon.Attack.AnimationId, weapon.JumpAttack.AnimationId} do
		local id = assetId(value)
		if id then weaponIds[id] = true end
	end
end

-- Tracks owned by local reactions and filters for competing Animator playback.
export type State = {
	animator: Animator?, -- Existing character Animator currently being observed.
	connection: RBXScriptConnection?, -- AnimationPlayed listener that filters newly started competing tracks.
	active: boolean, -- Whether default and weapon animation suppression is active.
	owned: {[AnimationTrack]: boolean}, -- Locally registered track identities exempt from the incoming-track filter.
	defaultIds: {[string]: boolean}, -- Normalized asset IDs gathered from this character's default Animate script.
	filterReactions: boolean, -- Whether to suppress other clients' replicated knockback tracks on this observer.
	character: Model?, -- Character associated with the observed Animator.
}

function Playback.New(): State
	return {animator = nil, connection = nil, active = false,
		owned = {}, defaultIds = {}, filterReactions = false, character = nil}
end

function Playback.Register(state: State, track: AnimationTrack)
	state.owned[track] = true
end

function Playback.Unregister(state: State, track: AnimationTrack)
	state.owned[track] = nil
end

function Playback.Detach(state: State)
	if state.connection then state.connection:Disconnect() end
	state.connection, state.animator, state.active, state.character = nil, nil, false, nil
	table.clear(state.defaultIds)
end

local function suppress(state: State, track: AnimationTrack)
	if state.owned[track] then return end
	local animation = track.Animation
	if not animation then return end
	local id = assetId(animation.AnimationId)
	if id and reactionIds[id] then
		if state.filterReactions then track:Stop(0) end
		return -- Synchronized observers must retain the owner's replicated track.
	end
	local character = state.character
	if not state.active or not character or character:GetAttribute("IsRagdolled") ~= true
		or Motion.GetState(character) == "Stop" then return end
	if animation:GetAttribute("CombatWeaponAnimation") == true
		or (id and (state.defaultIds[id] or weaponIds[id])) then track:Stop(0); return end
	local animate = character and character:FindFirstChild("Animate")
	if animate and animation:IsDescendantOf(animate) then track:Stop(0); return end
	if animation.Parent ~= nil then return end
	local name = string.lower(animation.Name)
	if (defaultNames[name] and track.Priority == Enum.AnimationPriority.Core)
		or (name == "toolnone" and track.Priority == Enum.AnimationPriority.Idle)
		or ((name == "toolslash" or name == "toollunge") and track.Priority == Enum.AnimationPriority.Action) then
		track:Stop(0)
	end
end

function Playback.Observe(state: State, character: Model, humanoid: Humanoid?, active: boolean)
	if not character:IsDescendantOf(Workspace) or not humanoid or humanoid.Health <= 0 then
		Playback.Detach(state)
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then Playback.Detach(state); return end
	local attaching, entering = state.animator ~= animator, active and not state.active
	if attaching then Playback.Detach(state); state.animator = animator end
	state.character, state.active = character, active
	state.filterReactions = character ~= Players.LocalPlayer.Character
		and (LOCAL_PLAYERS or character:GetAttribute("KnockbackActorKind") == "NPC")
	-- Rebuilt only on character/attribute events, never on every render frame.
	table.clear(state.defaultIds)
	local animate = character:FindFirstChild("Animate")
	if animate then
		for _, item in animate:GetDescendants() do
			if item:IsA("Animation") then
				local id = assetId(item.AnimationId)
				if id then state.defaultIds[id] = true end
			end
		end
	end
	if attaching then
		state.connection = animator.AnimationPlayed:Connect(function(track)
			if state.animator == animator then suppress(state, track) end
		end)
	end
	if attaching or entering then
		for _, track in animator:GetPlayingAnimationTracks() do suppress(state, track) end
	end
end

return Playback
