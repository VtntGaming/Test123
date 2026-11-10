--!strict
-- Replaces Roblox's default animation module so the shared simulation is the sole gameplay animation owner.
-- The engine calls setupAnimation; character animation is initialized by Simulation instead.

--// Types
export type Animate = {
	-- Accepts the engine's animation setup arguments without registering a second animation loop.
	setupAnimation: (...unknown) -> (),
}

--// Controller
local Animate: Animate = {} :: Animate

--// APIs
function Animate.setupAnimation(...: unknown)
	-- Intentionally empty: ReplicatedStorage.Simulation.Animations owns the real Animator.
end

return Animate
