--!strict
-- Presents one logical Player-data API over readable Value objects, inventory counts and local UI overrides.
-- Persistence and gameplay policy remain with their owning server services.

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Modules
local Schema = require(script.Schema)
local Types = require(script.Types)
local Values = require(script.Values)
local Signal = require(ReplicatedStorage.Utils.Signal)

--// References
local IsServer = RunService:IsServer()

--// Types
export type Connection = Signal.Connection
export type Value = Types.Value
type Overlay = { Value: Value?, Request: number }
type SettingState = { Value: Value?, Revision: number }
type Record = {
	Signals: { [string]: Signal.Signal<> },
	All: Signal.Signal<string>,
	Shown: { [string]: unknown },
	Seen: { [string]: boolean },
	Overlays: { [string]: Overlay },
	Settings: { [string]: SettingState },
}
export type PlayerData = {
	-- Shared defaults, readable storage groups, and setting or local-write permissions.
	Schema: Schema.Schema,
	-- Returns the visible field value including local overrides; client DataLoaded stays false until the published fields and inventory members arrive.
	Get: (Player, string) -> unknown?,
	-- Reads a cached inventory quantity; legacy CSV names retain trimmed ownership matching.
	GetItemCount: (Player, Types.InventoryKey, string) -> number,
	-- Sets or clears a scalar or serialized inventory on the server through its readable storage group and notifies observers when the visible value changes.
	Set: (Player, string, unknown) -> (),
	-- Returns a copy of the visible data, merging stored values, encoded inventories, local overrides, and client readiness.
	GetAll: (Player) -> { [string]: unknown },
	-- Subscribes to visible changes of one key and returns a connection; registration does not emit the current value.
	Observe: (Player, string, () -> ()) -> Connection,
	-- Subscribes to visible field changes and passes each changed key to the callback; registration does not emit current values.
	ObserveAll: (Player, (string) -> ()) -> Connection,
	-- Yields until the next visible change notification for the key.
	WaitForChange: (Player, string) -> (),
	-- Returns whether the attached native store has received its published fields and inventory members.
	IsReady: (Player) -> boolean,
	-- Sets an allowed scalar override for the owning client and returns its request sequence for response matching.
	SetLocal: (Player, string, unknown) -> number,
	-- Adopts an authoritative setting snapshot and clears only the matching optimistic request.
	ResolveSetting: (Player, string, number, unknown, number) -> (),
	-- Adopts an owner setting value/revision together; older snapshots cannot overwrite newer state.
	ApplySettingState: (Player, string, unknown, number) -> (),
	-- Returns the logical field revision, or zero when no revision has been published.
	Version: (Player, string) -> number,
	-- Creates the player's data record and observers once; released player lifetimes cannot be reattached.
	Attach: (Player) -> (),
	-- Permanently ends an attached player lifetime, removing storage records and destroying owned signals.
	Release: (Player) -> (),
	-- Returns whether the player currently has an attached data record.
	HasRecord: (Player) -> boolean,
}

--// Properties
local Records: { [Player]: Record } = {}
local Released = setmetatable({} :: { [Player]: boolean }, { __mode = "k" })
local RequestSequence = 0
local Undeclared: { [string]: boolean } = {}

--// Controller
local PlayerData: PlayerData = { Schema = Schema } :: PlayerData

local function ValueOf(value: unknown): Value?
	if value == nil then
		return nil
	end
	if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then
		assert(type(value) ~= "number" or (value == value and math.abs(value) < math.huge), "Player data numbers must be finite")
		return value
	end
	error("Unsupported Player data value type: " .. typeof(value), 3)
end

local function Raw(player: Player, key: string): unknown?
	return Values.Get(player, key)
end

local function Emit(player: Player, key: string)
	local record = Records[player]
	if not record then
		return
	end
	local value = PlayerData.Get(player, key)
	if record.Seen[key] and record.Shown[key] == value then
		return
	end
	record.Seen[key], record.Shown[key] = true, value
	local signal = record.Signals[key]
	if signal then
		signal:FireDeferred()
	end
	record.All:FireDeferred(key)
end

local function FieldSignal(player: Player, key: string): Signal.Signal<>
	PlayerData.Attach(player)
	local record = Records[player]
	assert(record ~= nil, "Player data lifetime has ended")
	local signal = record.Signals[key]
	if not signal then
		signal = Signal.new()
		record.Signals[key] = signal
	end
	record.Seen[key], record.Shown[key] = true, PlayerData.Get(player, key)
	return signal
end

--// APIs
function PlayerData.Attach(player)
	if Records[player] or Released[player] then
		return
	end
	Records[player] = { Signals = {}, All = Signal.new(), Shown = {}, Seen = {}, Overlays = {}, Settings = {} }
	Values.Attach(player, function(key: string)
		Emit(player, key)
	end)
end

function PlayerData.Get(player, key)
	PlayerData.Attach(player)
	local record = Records[player]
	if not record then
		return nil
	end
	local overlay = record.Overlays[key]
	local snapshot = record.Settings[key]
	local value = if overlay then overlay.Value elseif snapshot then snapshot.Value else Raw(player, key)
	if key == "DataLoaded" and not IsServer and not PlayerData.IsReady(player) then
		return false
	end
	return value
end

function PlayerData.GetItemCount(player, key, itemName)
	PlayerData.Attach(player)
	return if Records[player] then Values.GetItemCount(player, key, itemName) else 0
end

function PlayerData.Set(player, key, value)
	assert(IsServer, "PlayerData.Set is server-only; use an authorized gameplay request")
	local scalar = ValueOf(value)
	local field = Schema.Fields[key]
	if not field and RunService:IsStudio() and not Undeclared[key] then
		Undeclared[key] = true
		warn("[PlayerData] Undeclared dynamic field:", key)
	end
	assert(
		not field or field.Kind == nil or scalar == nil or type(scalar) == field.Kind,
		"Unexpected Player data field type: " .. key
	)
	PlayerData.Attach(player)
	-- Finalized lifetimes reject delayed writes instead of recreating state.
	if not Records[player] then
		return
	end
	if Values.Set(player, key, scalar) then
		-- Native callbacks share this deduplicating path with synchronous writes.
		Emit(player, key)
	end
end

function PlayerData.GetAll(player)
	PlayerData.Attach(player)
	if not Records[player] then
		return {}
	end
	local result: { [string]: unknown } = Values.GetAll(player)
	for key in Records[player].Settings do
		result[key] = PlayerData.Get(player, key)
	end
	for key in Records[player].Overlays do
		result[key] = PlayerData.Get(player, key)
	end
	if not IsServer then
		result.DataLoaded = PlayerData.Get(player, "DataLoaded")
	end
	return result
end

function PlayerData.Observe(player, key, callback)
	return FieldSignal(player, key):Connect(callback)
end

function PlayerData.ObserveAll(player, callback)
	PlayerData.Attach(player)
	local record = Records[player]
	assert(record ~= nil, "Player data lifetime has ended")
	return record.All:Connect(callback)
end

function PlayerData.WaitForChange(player, key)
	FieldSignal(player, key):Wait()
end

function PlayerData.IsReady(player)
	return Records[player] ~= nil and Values.IsReady(player)
end

function PlayerData.SetLocal(player, key, value)
	assert(not IsServer and player == Players.LocalPlayer, "Local Player data belongs to the owning client")
	assert(
		Schema.LocalKeys[key] ~= nil and (value == nil or type(value) == Schema.LocalKeys[key]),
		"Unsupported local Player data field: " .. key
	)
	local scalar = ValueOf(value)
	PlayerData.Attach(player)
	RequestSequence += 1
	Records[player].Overlays[key] = { Value = scalar, Request = RequestSequence }
	Emit(player, key)
	return RequestSequence
end

function PlayerData.ApplySettingState(player, key, value, revision)
	if IsServer or player ~= Players.LocalPlayer then return end
	local record = Records[player]
	if not record then return end
	local previous = record.Settings[key]
	if previous and previous.Revision >= revision then return end
	record.Settings[key] = { Value = ValueOf(value), Revision = revision }
	Emit(player, key)
end

function PlayerData.ResolveSetting(player, key, request, value, revision)
	if IsServer then return end
	local record = Records[player]
	if not record then return end
	PlayerData.ApplySettingState(player, key, value, revision)
	local overlay = record.Overlays[key]
	if overlay and overlay.Request == request then
		record.Overlays[key] = nil
		Emit(player, key)
	end
end

function PlayerData.Version(player, key)
	return Values.Revision(player, key)
end

function PlayerData.HasRecord(player)
	return Records[player] ~= nil
end

function PlayerData.Release(player)
	local record = Records[player]
	if not record then
		return
	end
	Records[player], Released[player] = nil, true
	Values.Remove(player)
	for _, signal in record.Signals do
		signal:Destroy()
	end
	record.All:Destroy()
end

return PlayerData
