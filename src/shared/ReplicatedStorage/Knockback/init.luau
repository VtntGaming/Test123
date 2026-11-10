--!strict
-- Exposes shared Cartoon simulation and actor identity without a custom movement transport.
local Actors = require(script.Actors)
local Motion = require(script.CartoonMotion)
local State = require(script.State)
local Diagnostics = require(script.Diagnostics)
export type Actor = Actors.Actor
export type ActorKind = Actors.Kind
export type Presentation = State.Presentation
export type DiagnosticsState = Diagnostics.State
export type DiagnosticsSnapshot = Diagnostics.Snapshot
return table.freeze({ Actors = Actors, Motion = Motion, State = State, Diagnostics = Diagnostics })
