--!strict
-- Shared combat presentation rules. No startup work or transport dependencies.
local AnimationResolver = require(script:WaitForChild("AnimationResolver"))
local Reaction = require(script:WaitForChild("Reaction"))
-- Simulation-facing immutable identity and confirmed contact types.
export type ActionIdentity = { Generation: string, Revision: number, ActorId: number }
-- Public alias for one server collision and its cosmetic reaction metadata.
export type ReactionImpact = Reaction.Impact
-- Public alias for a character's current cosmetic reaction state.
export type ReactionState = Reaction.State
-- Public alias for the timing of a blend between reaction phases.
export type ReactionTransition = Reaction.Transition
return table.freeze({AnimationResolver = AnimationResolver, Reaction = Reaction})

