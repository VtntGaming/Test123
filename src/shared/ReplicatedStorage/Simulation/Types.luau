--!strict
-- Declares the boundaries between replayable gameplay, server commands and presentation.
export type Actor = Model | BasePart
export type ActionSample = {
	-- Whether the attack action is currently pressed.
	Attack: boolean,
	-- Whether the ability action is currently pressed.
	Ability: boolean,
	-- Whether the jump action is currently pressed.
	Jump: boolean,
	-- Normalized finite aim direction, or Vector3.zero when unavailable or invalid.
	Aim: Vector3,
	-- Normalized finite facing direction, or Vector3.zero when unavailable or invalid.
	Facing: Vector3,
	-- Finite steering vector clamped to magnitude 1, or Vector3.zero when unavailable or invalid.
	Steer: Vector3,
}
export type ActorRecord = {
	-- Model or standalone part participating in shared gameplay simulation.
	Actor: Actor,
	-- Whether all required root and humanoid state carriers are available.
	Ready: boolean,
	-- Physical root used for motion, prediction, and root-level simulation state.
	Root: BasePart,
	-- Humanoid when the actor has one; standalone actors may omit it.
	Humanoid: Humanoid?,
	-- Player owning this character, or nil for actors without a player owner.
	Owner: Player?,
	-- Actor lifetime identifier used to reject commands from an earlier generation.
	Generation: string,
	-- Cached physical parts belonging to the actor, including its equipped weapon.
	Parts: { BasePart },
	-- Baseline part sizes and weapon membership used for replayable scaling.
	Geometry: { {
		-- Physical part whose size is scaled.
		Part: BasePart,
		-- Unscaled part size in studs.
		Size: Vector3,
		-- Whether this part belongs to the equipped weapon.
		Weapon: boolean
	} },
	-- Baseline joint frames and weapon membership projected outside simulation.
	Joints: { {
		-- Joint whose baseline frames are projected after simulation.
		Joint: JointInstance,
		-- Unscaled frame relative to the joint's Part0.
		C0: CFrame,
		-- Unscaled frame relative to the joint's Part1.
		C1: CFrame,
		-- Whether this joint belongs to the equipped weapon.
		Weapon: boolean
	} },
	-- Baseline mesh scale and offset data used for visual scaling.
	Meshes: { {
		-- Mesh whose visual scale and offset are projected.
		Mesh: SpecialMesh,
		-- Unscaled mesh scale vector.
		Scale: Vector3,
		-- Unscaled mesh offset in studs.
		Offset: Vector3,
		-- Whether this mesh belongs to the equipped weapon.
		Weapon: boolean
	} },
	-- Baseline attachment frames used to project body and weapon scaling.
	Attachments: { {
		-- Attachment whose local frame is projected.
		Attachment: Attachment,
		-- Unscaled attachment frame in parent-local space.
		Frame: CFrame,
		-- Whether this attachment belongs to the equipped weapon.
		Weapon: boolean
	} },
	-- Unscaled humanoid hip height used as the body-scaling baseline.
	HipHeight: number,
	-- Baseline model scale captured for the actor, or 1 for a standalone part.
	Scale: number,
	-- Whether the humanoid has positive health; actors without a humanoid count as alive.
	Alive: boolean,
	-- Whether the actor uses an R6 humanoid rig.
	R6: boolean,
	-- Current humanoid animator, refreshed before simulation when available.
	Animator: Animator?,
	-- Current EquippedWeapon model, or nil when the actor has no such model.
	Weapon: Model?,
}
export type Command = {
	-- Actor targeted by this queued replayable command.
	Actor: Actor,
	-- Actor lifetime identifier captured when the command was queued.
	Generation: string,
	-- Monotonically increasing command number used to reject already applied commands.
	Sequence: number,
	-- Callback applied when the actor generation and command sequence remain valid.
	Apply: () -> (),
}
export type Commit = {
	-- Actor targeted by this server-only post-simulation effect.
	Actor: Actor,
	-- Actor lifetime identifier captured when the commit was queued.
	Generation: string,
	-- Deduplication key shared by equivalent effects within an actor generation.
	Identity: string,
	-- Callback run after simulation once this identity is accepted for the generation.
	Apply: () -> (),
}
export type Step = (number, number) -> ()
return table.freeze({})
