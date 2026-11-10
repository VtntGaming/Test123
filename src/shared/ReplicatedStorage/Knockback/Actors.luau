--!strict
-- A streamed actor is available only while its tag, identity and root are present.
-- Removal means unavailable, not dead; tracked generations own simulation lifetimes.
local Actors = {}
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

-- Character Model or training-bag BasePart registered for combat.
export type Actor = Model | BasePart
-- Distinguishes player characters, NPC characters, and training bags.
export type Kind = "Player" | "NPC" | "Bag"
-- Callbacks for local actor availability, including streaming changes.
type Listener = {
	added: (Actor, number) -> (), -- Called with the actor and actor ID when it becomes available.
	removed: (Actor, number) -> () -- Called with the actor and actor ID when it becomes unavailable; not necessarily dead.
}
-- Connections and current identity for one tagged actor.
type Watch = {
	connections: {RBXScriptConnection}, -- Attribute and ancestry listeners disconnected when this actor is unregistered.
	id: number?, -- Currently exposed actor ID; nil while the actor is unavailable.
	generation: string?,
}
local initialized = false
local available: {[number]: Actor} = {}
local watched: {[Instance]: Watch} = {}
local listeners: {[Listener]: boolean} = {}

function Actors.GetKind(actor: Instance): Kind?
	local kind = actor:GetAttribute("KnockbackActorKind")
	if kind == "Player" or kind == "NPC" or kind == "Bag" then return kind end
	return nil
end

function Actors.GetRoot(actor: Instance): BasePart?
	if actor:IsA("BasePart") then return actor end
	local root = actor:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function remove(actor: Instance, watch: Watch)
	local id = watch.id
	watch.id = nil
	if id and available[id] == actor then
		available[id] = nil
		for listener in listeners do listener.removed(actor :: Actor, id) end
	end
end

local function refresh(actor: Instance, watch: Watch)
	local id = actor:GetAttribute("KnockbackActorId")
	local valid = (actor:IsA("Model") or actor:IsA("BasePart")) and actor:IsDescendantOf(Workspace)
		and actor:GetAttribute("CartoonVisualOnly") ~= true and Actors.GetRoot(actor) ~= nil
		and type(id) == "number" and id > 0 and id % 1 == 0
		and type(actor:GetAttribute("RagdollGeneration")) == "string" and Actors.GetKind(actor) ~= nil
	if not valid then remove(actor, watch)
return end
	local actorId = id :: number
	local generation = actor:GetAttribute("RagdollGeneration") :: string
	if watch.id == actorId and watch.generation == generation and available[actorId] == actor then
		return
	end
	remove(actor, watch)
	local previous = available[actorId]
	if previous and previous ~= actor then
		local previousWatch = watched[previous]
		if previousWatch then remove(previous, previousWatch) end
	end
	watch.id, available[actorId] = actorId, actor :: Actor
	watch.generation = generation
	for listener in listeners do listener.added(actor :: Actor, actorId) end
end

local function watchActor(actor: Instance)
	if watched[actor] then return end
	local watch: Watch = { connections = {}, id = nil, generation = nil }
	watched[actor] = watch
	for _, attribute in {"KnockbackActorId", "KnockbackActorKind", "RagdollGeneration"} do
		table.insert(watch.connections, actor:GetAttributeChangedSignal(attribute):Connect(function() refresh(actor, watch) end))
	end
	table.insert(watch.connections, actor.AncestryChanged:Connect(function() refresh(actor, watch) end))
	table.insert(
		watch.connections,
		actor.ChildAdded:Connect(function()
			refresh(actor, watch)
		end)
	)
	table.insert(
		watch.connections,
		actor.ChildRemoved:Connect(function()
			refresh(actor, watch)
		end)
	)
	refresh(actor, watch)
end

function Actors.Init()
	if initialized then return end
	initialized = true
	CollectionService:GetInstanceAddedSignal("CombatActor"):Connect(watchActor)
	CollectionService:GetInstanceRemovedSignal("CombatActor"):Connect(function(actor)
		local watch = watched[actor]
		if not watch then return end
		remove(actor, watch)
		for _, connection in watch.connections do connection:Disconnect() end
		watched[actor] = nil
	end)
	for _, actor in CollectionService:GetTagged("CombatActor") do watchActor(actor) end
end

function Actors.Get(actorId: number, generation: string?): Actor?
	Actors.Init()
	local actor = available[actorId]
	if actor and (generation == nil or actor:GetAttribute("RagdollGeneration") == generation) then return actor end
	return nil
end

function Actors.GetAll(): {[number]: Actor}
	Actors.Init()
	return table.clone(available)
end

function Actors.Observe(added: (Actor, number) -> (), removed: (Actor, number) -> ()): () -> ()
	Actors.Init()
	local listener: Listener = {added = added, removed = removed}
	listeners[listener] = true
	for id, actor in available do added(actor, id) end
	return function() listeners[listener] = nil end
end

return table.freeze(Actors)
