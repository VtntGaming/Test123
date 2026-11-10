-- Presentation only. Collision decisions and phase boundaries come from the server.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SharedConfig = require(ReplicatedStorage:WaitForChild("Config"))
local Knockback = require(ReplicatedStorage:WaitForChild("Knockback"))

local Events = ReplicatedStorage:WaitForChild("Events")
local UpdateGameStateEvent = Events:WaitForChild("UpdateGameState")

local Controller = {}
local Config = SharedConfig.Network
local Stream, Diagnostics, Actors = Knockback.Stream, Knockback.Diagnostics, Knockback.Actors
local localPlayer = Players.LocalPlayer :: Player
-- Alias for the shared client motion buffer; field documentation is in Knockback.Stream.Record.
type Record = Knockback.StreamRecord
local state = Stream.New()
local records = state.records
local initialized = false
local controls: any = nil -- Roblox inserts PlayerModule outside the Studio sourcemap.
local lockCharacter: Model? = nil
local previousEnabled = true
local restorePending = false
local currentArena: Model?
local currentMainArena: Model?
local SFX = SoundService:WaitForChild("SFX")
local crowdCheerSound = SFX:WaitForChild("CrowdCheer") ::Sound
local cheerSoundPlayCache = {} :: {[Instance]: boolean}
local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local VOID_CHEER_MARGIN = 40
local function recordFor(actor: Instance): Record?
	local actorId = actor:GetAttribute("KnockbackActorId")
	local record = if type(actorId) == "number" then records[actorId] else nil
	local revision = actor:GetAttribute("RagdollRevision")
	if record and record.generation == actor:GetAttribute("RagdollGeneration")
		and record.revision >= (if type(revision) == "number" then revision else 0) then return record end
	return nil
end

local function receive(kind: string, batch: {any})
	if kind ~= "Control" or type(batch) ~= "table" then return end
	Diagnostics.Add(state.stats, "ReliableMessages")
	Diagnostics.Add(state.stats, "ControlRecords", #batch)
	for _, event in batch do Stream.Control(state, event, os.clock()) end
end

function Controller.GetNetworkStats()
	return Diagnostics.Read(state.stats)
end

function Controller.RecordReactionSend()
	Diagnostics.Add(state.stats, "ReactionMessages")
end

function Controller.GetState(actor: Instance): (string?, string?)
	local record = recordFor(actor)
	if record then return if record.stopped then "Stop" else record.phase, record.weaponId end
	return nil, nil
end

function Controller.GetVelocity(actor: Instance): Vector3?
	local record = recordFor(actor)
	return if record and not record.stopped then record.velocity else nil
end

function Controller.GetPresentation(actor: Instance): Record?
	local record = recordFor(actor)
	return if record and not record.stopped then record else nil
end

local function restoreControls()
	lockCharacter = nil
	if not controls then return end
	-- A match freeze can outlast motion. Do not release somebody else's lock.
	if localPlayer:GetAttribute("IsFrozen") == true then restorePending = true; return end
	controls:Enable(previousEnabled)
	restorePending = false
end

local function updateControls()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and Actors.GetRoot(character)
	local record = character and recordFor(character)
	local active = character ~= nil and character:GetAttribute("IsRagdolled") == true
	if record then
		if record.stopped then
			active = lockCharacter == character and root ~= nil and root.Anchored
		elseif not record.wasAnchored or (root and root.Anchored) then
			active = true
		else
			active = false
		end
	end
	if not character or not character:IsDescendantOf(Workspace) or not humanoid or humanoid.Health <= 0 then active = false end
	if lockCharacter and (lockCharacter ~= character or not active) then restoreControls() end
	if active and character and not lockCharacter and controls then
		if not restorePending then previousEnabled = controls.controlsEnabled ~= false end
		restorePending = false
		lockCharacter = character
		controls:Disable()
	elseif not active and restorePending and localPlayer:GetAttribute("IsFrozen") ~= true then
		restoreControls()
	end
end
local function isMyDecidingKnockout(actor: Instance): boolean
	if actor:GetAttribute("LastHitBy") ~= localPlayer.Name then return false end
	local fallingPlayer = if actor:IsA("Model") then Players:GetPlayerFromCharacter(actor) else nil
	local lives = (fallingPlayer or actor):GetAttribute("Lives")
	if type(lives) ~= "number" or lives > 1 then return false end
	for _, other in Players:GetPlayers() do
		if other ~= localPlayer and other ~= fallingPlayer and other:GetAttribute("IsOnArena") then return false end
	end
	for _, npc in CollectionService:GetTagged("ArenaNPC") do
		if npc ~= actor and npc.Parent and (npc:GetAttribute("Lives") or 0) > 0 then return false end
	end
	return true
end



local function render()
	local renderTime = Workspace:GetServerTimeNow() - Config.InterpolationDelay
	for actorId, record in records do
		local actor = Actors.Get(actorId, record.generation)
		local root = actor and Actors.GetRoot(actor)
		local humanoid: Humanoid? = if actor and actor:IsA("Model") then actor:FindFirstChildOfClass("Humanoid") else nil
		if not actor or not root or not root:IsDescendantOf(Workspace)
			or (record.actorKind ~= "Bag" and (not humanoid or humanoid.Health <= 0)) then
			record.renderedRoot = nil -- Keep snapshots/decisions across streaming removal.
			continue
		end
		if record.stopped then
			if not record.stopApplied and root.Anchored and record.stopFrame then root.CFrame = record.stopFrame end
			record.stopApplied, record.renderedRoot = true, nil
			table.clear(record.packets)
			continue
		end
		if not root.Anchored then record.renderedRoot = nil; continue end	
		if (actor:GetAttribute("RagdollRevision") or 0) > record.revision then continue end
		record.wasAnchored = true
		local frame = Stream.Present(state, record, renderTime)
		if not frame then continue end
		root.CFrame = frame
		-- The independent server query sphere is not cosmetic. Leave its
		-- replicated transform alone; queries never use the displayed rig.
		record.renderedRoot = root
		
			

			
							
			
	end
	updateControls()
end

function Controller.Init()
	if initialized then return end
	initialized = true
	Actors.Init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local motion = remotes:WaitForChild("KnockbackMotion") :: RemoteEvent
	local bootstrap = remotes:WaitForChild("GetKnockbackState") :: RemoteFunction
	local snapshots = remotes:WaitForChild("KnockbackSnapshots") :: UnreliableRemoteEvent
	motion.OnClientEvent:Connect(receive)
	snapshots.OnClientEvent:Connect(function(data) Stream.Movement(state, data, os.clock()) end)
	Actors.Observe(function(_, actorId)
		state.departed[actorId] = nil
	end, function(actor, actorId)
		local record = records[actorId]
		if record then record.renderedRoot = nil end
		if actor:IsA("Model") and lockCharacter == actor then restoreControls() end
	end)
	Players.PlayerRemoving:Connect(function(player)
		local character = player.Character
		local actorId = character and character:GetAttribute("KnockbackActorId")
		if type(actorId) == "number" then Stream.RemoveActor(state, actorId, os.clock()) end
	end)
	localPlayer.CharacterRemoving:Connect(function(character: Model)
		local actorId = character:GetAttribute("KnockbackActorId")
		if type(actorId) == "number" then Stream.RemoveCharacter(state, actorId, character:GetAttribute("RagdollGeneration"), os.clock()) end
		if lockCharacter == character then restoreControls() end
	end)
	localPlayer:GetAttributeChangedSignal("IsFrozen"):Connect(updateControls)
	task.spawn(function()
		--local module = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript
		--local loadPlayerModule: (ModuleScript) -> any = require
		--controls = loadPlayerModule(module):GetControls()
		--updateControls()
	end)
	local requesting = false
	local function requestState()
		if requesting then state.needResync = true; return end
		requesting = true
		state.lastResync = os.clock()
		Diagnostics.Add(state.stats, "BootstrapRequests")
		task.spawn(function()
			local success, response = pcall(function() return bootstrap:InvokeServer() end)
			requesting = false
			if success then Stream.Bootstrap(state, response, os.clock())
			else state.needResync = true; warn("Cartoon state request failed:", response) end
		end)
	end
	requestState()
	RunService.Heartbeat:Connect(function()
		if Stream.PollResync(state, os.clock()) then requestState() end
	end)
	RunService:BindToRenderStep("CombatCartoonPresentation", Enum.RenderPriority.Camera.Value - 1, render)
	
	UpdateGameStateEvent.OnClientEvent:Connect(function(state, timerValue)
		if state == "GameOver" or state == "Waiting" or state == "Intermission" then
			table.clear(cheerSoundPlayCache)
		end
	end)
	do -- cache current arena
		local function onArenaDetected(ins: Instance)
			if not ins:IsA("Model") then
				return
			end
			if not ins:IsDescendantOf(workspace) then
				return
			end
			currentArena = ins
			currentMainArena = ins 
			local block = ins:FindFirstChild("Block")
			if block and block:IsA("Folder") then
				local main = block:FindFirstChild("Main")
				if main and main:IsA("Model") then
					currentMainArena = main
				end
			end
		end
		for _,ins in ipairs(CollectionService:GetTagged("Arena")) do
			onArenaDetected(ins)
		end
		CollectionService:GetInstanceAddedSignal("Arena"):Connect(function(ins)
			onArenaDetected(ins)
		end)
		CollectionService:GetInstanceRemovedSignal("Arena"):Connect(function(ins)
			if currentArena == ins then
				currentArena = nil
				currentMainArena = nil
			end
		end)
		
	end
end

return Controller
