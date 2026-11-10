--!strict
-- Partitions replayable actor state into bounded, explicitly predicted attribute carriers.
-- Field registration owns the storage location and reserves payload room before gameplay writes it.

--// Services
local RunService = game:GetService("RunService")

--// Modules
local Diagnostics = require(script.Parent.Diagnostics)

--// References
local IsServer = RunService:IsServer()

--// Constants
local CONTAINER_NAME = "SimulationState"
local CARRIER_MARKER = "SimulationCarrier"
local PAYLOAD_BUDGET = 768 -- Conservative estimate, with room below the engine's 1024-byte limit.
local ATTRIBUTE_LIMIT = 64
local STRING_LIMIT = 50
local VALUE_BYTES: { [string]: number } = { boolean = 1, number = 8, string = 54, Vector3 = 24, CFrame = 96 }

--// Types
type Store = { Container: Folder, Carriers: { [string]: Folder }, Mode: Enum.PredictionMode? }

export type Subscription = {
	-- Stops notifications and disconnects all owned listeners; repeated calls are harmless.
	Disconnect: (Subscription) -> (),
}
export type Attributes = {
	-- Creates server carriers or resolves replicated carriers for the root and optional humanoid; returns whether all are ready.
	Bind: (BasePart, Humanoid?) -> boolean,
	-- Sets client prediction mode on the source's bound carriers; repeated modes and server calls do nothing.
	Predict: (Instance, Enum.PredictionMode) -> (),
	-- Restores automatic client prediction and forgets cached carriers without destroying their instances.
	Remove: (Instance) -> (),
	-- Reads a registered field from its carrier, returning nil when the carrier or value is absent.
	Get: (Instance, string) -> unknown?,
	-- Writes or clears a registered field, asserting carrier readiness, the declared value type, and string size limits.
	Set: (Instance, string, unknown) -> (),
	-- Watches a field across carrier replacement, defers its initial notification, and returns a disconnectable subscription.
	Observe: (Instance, string, () -> ()) -> Subscription,
	-- Asserts attribute counts, string limits, and estimated payload budgets, reserving room for registered carrier fields.
	Validate: (Instance) -> (),
	-- Returns whether the instance is a Folder named SimulationState.
	IsContainer: (Instance) -> boolean,
	-- Counts currently bound carrier instances for local diagnostics; never estimates packet size.
	CarrierCount: () -> number,
}

--// Properties
local Fields: { [string]: { Group: string, Kind: string } } = {}
local Groups: { [string]: { [string]: string } } = {}
local RootGroups: { string } = {}
local HumanoidGroups: { string } = {}
local Stores: { [Instance]: Store } = {}

--// Controller
local Attributes: Attributes = {} :: Attributes

local function Define(group: string, humanoid: boolean, fields: { [string]: string })
	assert(Groups[group] == nil, "Duplicate simulation state group: " .. group)
	Groups[group] = fields
	table.insert(if humanoid then HumanoidGroups else RootGroups, group)
	local count, bytes = 0, 32
	for field, kind in fields do
		assert(Fields[field] == nil, "Duplicate simulation state field: " .. field)
		assert(#field <= STRING_LIMIT and VALUE_BYTES[kind] ~= nil, "Invalid simulation state field: " .. field)
		Fields[field] = { Group = group, Kind = kind }
		count += 1
		bytes += #field + 5 + VALUE_BYTES[kind]
	end
	assert(count <= ATTRIBUTE_LIMIT and bytes <= PAYLOAD_BUDGET, "Simulation schema exceeds budget: " .. group)
end

Define("Knockback", false, {
	KBActive = "boolean",
	KBSession = "number",
	KBProfile = "number",
	KBStrength = "number",
	KBFlags = "number",
	KBPhase = "string",
	KBPhaseTime = "number",
	KBStunUntil = "number",
	KBGroundBounces = "number",
	KBWallBounces = "number",
	KBRestTime = "number",
	KBFlyTime = "number",
	KBFinished = "boolean",
	KBFinishReason = "string",
	KBRecoveryRequested = "boolean",
	KBBeforeAnchored = "boolean",
	KBBagCheckAt = "number",
	KBPauseAt = "number",
	KBPausedTime = "number",
})
Define("KnockbackMotion", false, {
	KBMotionSession = "number",
	KBMotionAt = "number",
	KBPosition = "Vector3",
	KBVelocity = "Vector3",
	KBRadius = "number",
	KBGravity = "number",
	KBHeading = "CFrame",
	KBRootToTorso = "Vector3",
	KBLaunchVelocity = "Vector3",
	KBStunOffset = "CFrame",
	KBLastSafe = "Vector3",
})
Define("KnockbackSupport", false, {
	KBSupportSession = "number",
	KBSupportId = "number",
	KBSupportFrame = "CFrame",
	KBSupportLocal = "Vector3",
	KBSupportSize = "Vector3",
	KBSupportNormal = "Vector3",
	KBSupportVelocity = "Vector3",
})
Define("KnockbackImpact", false, {
	KBImpactSession = "number",
	KBImpactId = "number",
	KBImpactTime = "number",
	KBImpactNormal = "Vector3",
	KBImpactPosition = "Vector3",
	KBImpactOutcome = "string",
	KBRestDirection = "Vector3",
})
Define("Actor", false, {
	SAAbilityAllowed = "boolean",
	SABodyScale = "number",
	SACombatAllowed = "boolean",
	SACommand = "number",
	SAEquippedAbility = "string",
	SAEquippedWeapon = "string",
	SANpcDirection = "Vector3",
	SAScaleWeapon = "boolean",
	SAWeaponScale = "number",
	SAWeaponScaleRevision = "number",
})
Define("Transition", false, {
	SADropAt = "number",
	SADropDone = "number",
	SADropDuration = "number",
	SADropFrom = "CFrame",
	SADropTo = "CFrame",
	SADropToken = "number",
})
Define("Combat", true, {
	SAAttackEquipment = "number",
	SAAttackId = "number",
	SAAttackReadyAt = "number",
	SAAttackReleased = "number",
	SAAttackType = "string",
	SAAttackWeapon = "string",
	SAChargeStarted = "number",
	SAChargeStrength = "number",
	SACharging = "boolean",
	SAReleasedAt = "number",
	SAWasAttack = "boolean",
})
Define("Ability", true, {
	SAAbilityAnimation = "string",
	SAAbilityEndsAt = "number",
	SAAbilityId = "number",
	SAAbilityReadyAt = "number",
	SAAbilityStarted = "number",
	SAActiveAbility = "string",
	SAWasAbility = "boolean",
})
Define("AbilityMotion", true, {
	SAAbilityAim = "Vector3",
	SAAbilityFacedId = "number",
	SAAbilityStartY = "number",
	SAChargeDirection = "Vector3",
	SAMegaJumpId = "number",
	SASmashCommittedId = "number",
	SASmashImpact = "boolean",
	SASmashImpactAt = "number",
	SASmashPosition = "Vector3",
})
Define("Cooldowns", true, {
	SACDBigWeapon = "number",
	SACDCharge = "number",
	SACDDash = "number",
	SACDInvisible = "number",
	SACDMegaJump = "number",
	SACDPull = "number",
	SACDPush = "number",
	SACDShrink = "number",
	SACDSmash = "number",
	SACDThrow = "number",
	SACDTimeStop = "number",
})
Define("Movement", true, {
	SAAirJumpUsed = "boolean",
	SALastJump = "number",
	SAJumpKind = "string",
	SAWallJumps = "number",
	SAWasJump = "boolean",
})

local function FindCarrier(source: Instance, group: string): Folder?
	local store = Stores[source]
	local cached = if store then store.Carriers[group] else nil
	if store and cached and cached.Parent == store.Container and store.Container.Parent == source then
		return cached
	end
	local container = source:FindFirstChild(CONTAINER_NAME)
	local carrier = if container and container:IsA("Folder") then container:FindFirstChild(group) else nil
	return if carrier and carrier:IsA("Folder") then carrier else nil
end

local function BindSource(source: Instance, groups: { string }): boolean
	local container = source:FindFirstChild(CONTAINER_NAME)
	if not container and IsServer then
		local created = Instance.new("Folder")
		created.Name, created.Archivable = CONTAINER_NAME, false
		-- Build the subtree before parenting so initial replication includes its complete layout.
		for _, group in groups do
			local carrier = Instance.new("Folder")
			carrier.Name, carrier.Archivable = group, false
			-- Empty attribute dictionaries can remain empty on an already-predicted client.
			-- Establish a replicated attribute payload before prediction can start, without inventing gameplay defaults.
			carrier:SetAttribute(CARRIER_MARKER, true)
			carrier.Parent = created
		end
		created.Parent = source
		container = created
	end
	if not container or not container:IsA("Folder") then
		return false
	end
	container.Archivable = false
	local previous = Stores[source]
	local store: Store = if previous and previous.Container == container
		then previous
		else { Container = container, Carriers = {}, Mode = nil }
	Stores[source] = store
	for _, group in groups do
		local carrier = container:FindFirstChild(group)
		if not carrier or not carrier:IsA("Folder") then
			return false
		end
		carrier.Archivable = false
		if IsServer and carrier:GetAttribute(CARRIER_MARKER) ~= true then
			carrier:SetAttribute(CARRIER_MARKER, true)
		end
		if store.Carriers[group] ~= carrier then
			store.Carriers[group], store.Mode = carrier, nil
		end
	end
	return true
end

local function ValidateInstance(instance: Instance, fields: { string }, budget: number)
	local attributes = instance:GetAttributes()
	local count, bytes = 0, 32
	for name, value in attributes do
		assert(#name <= STRING_LIMIT, "Simulation attribute name exceeds 50 characters: " .. name)
		assert(type(value) ~= "string" or #value <= STRING_LIMIT, "Simulation string exceeds 50 bytes: " .. name)
		local kind = typeof(value)
		local valueBytes = if type(value) == "string" then #value + 4 else VALUE_BYTES[kind]
		-- Unknown engine attribute types receive a conservative allowance on original instances.
		bytes += #name + 5 + (valueBytes or 128)
		count += 1
	end
	for _, name in fields do
		if attributes[name] == nil then
			local field = Fields[name]
			assert(field ~= nil, "Unregistered simulation field: " .. name)
			bytes += #name + 5 + VALUE_BYTES[field.Kind]
			count += 1
		end
	end
	assert(count <= ATTRIBUTE_LIMIT, "Predicted state exceeds 64 attributes: " .. instance:GetFullName())
	assert(bytes <= budget, "Predicted attribute payload estimate exceeds budget: " .. instance:GetFullName())
end

--// APIs
function Attributes.Bind(root, humanoid)
	local ready = BindSource(root, RootGroups)
	if humanoid then
		ready = BindSource(humanoid, HumanoidGroups) and ready
	end
	return ready
end

function Attributes.Predict(source, mode)
	local store = Stores[source]
	if IsServer or not store or store.Mode == mode then
		return
	end
	for _, carrier in store.Carriers do
		if carrier.Parent then
			RunService:SetPredictionMode(carrier, mode)
		end
	end
	store.Mode = mode
end

function Attributes.Remove(source)
	Attributes.Predict(source, Enum.PredictionMode.Automatic)
	Stores[source] = nil
end

function Attributes.Get(source, name)
	local field = Fields[name]
	assert(field ~= nil, "Unregistered simulation field: " .. name)
	local carrier = FindCarrier(source, field.Group)
	return if carrier then carrier:GetAttribute(name) else nil
end

function Attributes.Set(source, name, value)
	local field = Fields[name]
	assert(field ~= nil, "Unregistered simulation field: " .. name)
	assert(value == nil or typeof(value) == field.Kind, "Unexpected simulation field type: " .. name)
	assert(type(value) ~= "string" or #value <= STRING_LIMIT, "Simulation string exceeds 50 bytes: " .. name)
	local carrier = FindCarrier(source, field.Group)
	assert(carrier ~= nil, "Simulation carrier is not ready: " .. field.Group)
	if carrier:GetAttribute(name) ~= value then Diagnostics.Count("AttributeChanges") end
	Diagnostics.Count("AttributeWrites")
	carrier:SetAttribute(name, value)
end

function Attributes.Observe(source, name, callback)
	local field = Fields[name]
	assert(field ~= nil, "Unregistered simulation field: " .. name)
	local stopped = false
	local current: Folder? = nil
	local changed: RBXScriptConnection? = nil
	local connections: { RBXScriptConnection } = {}
	local subscription: Subscription = {} :: Subscription
	function subscription:Disconnect()
		if stopped then
			return
		end
		stopped = true
		if changed then
			changed:Disconnect()
		end
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	local function refresh()
		if stopped then
			return
		end
		local carrier = FindCarrier(source, field.Group)
		if carrier == current then
			return
		end
		if changed then
			changed:Disconnect()
		end
		current = carrier
		changed = if carrier then carrier:GetAttributeChangedSignal(name):Connect(callback) else nil
		if carrier then
			callback()
		end
	end
	table.insert(
		connections,
		source.DescendantAdded:Connect(function()
			task.defer(refresh)
		end)
	)
	table.insert(
		connections,
		source.DescendantRemoving:Connect(function()
			task.defer(refresh)
		end)
	)
	table.insert(
		connections,
		source.Destroying:Connect(function()
			subscription:Disconnect()
		end)
	)
	-- Defer initial notification so consumers can retain the subscription before their callback runs.
	task.defer(refresh)
	return subscription
end

function Attributes.Validate(source)
	ValidateInstance(source, {}, 1024)
	local store = Stores[source]
	if not store then
		return
	end
	for group, carrier in store.Carriers do
		local names: { string } = {}
		for name in Groups[group] do
			table.insert(names, name)
		end
		ValidateInstance(carrier, names, PAYLOAD_BUDGET)
	end
end

function Attributes.IsContainer(instance)
	return instance.Name == CONTAINER_NAME and instance:IsA("Folder")
end

function Attributes.CarrierCount()
	local count = 0
	for source, store in Stores do
		if store.Container.Parent == source then
			for _, carrier in store.Carriers do
				if carrier.Parent == store.Container then count += 1 end
			end
		end
	end
	return count
end

return Attributes
