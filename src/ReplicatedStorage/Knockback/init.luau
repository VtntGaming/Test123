--!strict
-- Shared transport helpers. Children require siblings directly, never this index.
local Codec = require(script:WaitForChild("Codec"))
local Diagnostics = require(script:WaitForChild("Diagnostics"))
local Stream = require(script:WaitForChild("Stream"))
local Actors = require(script:WaitForChild("Actors"))
-- Public alias for a character Model or a training-bag BasePart.
export type Actor = Actors.Actor
-- Public alias for Player, NPC, or Bag.
export type ActorKind = Actors.Kind
-- Public alias for one compact authoritative movement sample.
export type Sample = Codec.Sample
-- Public alias for optional local diagnostic counters.
export type DiagnosticsState = Diagnostics.State
-- Public alias for one actor's buffered motion session.
export type StreamRecord = Stream.Record
-- Public alias for all buffered sessions and transport bookkeeping.
export type StreamState = Stream.State
return table.freeze({Codec = Codec, Diagnostics = Diagnostics, Stream = Stream, Actors = Actors})
