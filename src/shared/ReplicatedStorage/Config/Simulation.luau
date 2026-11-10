--!strict
-- Defines fixed simulation timing and client-only diagnostic switches.
-- Edit before starting a fresh Play session; changing switches during replay is unsupported.
-- All true preserves existing behavior. False skips only the named client calculation;
-- server simulation, input submission and authoritative replication continue unchanged.
-- These are NOT SetPredictionMode switches. An assembly can still be predicted and
-- corrected when one calculation is disabled, so mixed settings may deliberately mispredict.
-- Built-in player walking, match drop-in, freeze enforcement, and other players are unchanged.
local Config = {
	Frequency = Enum.StepFrequency.Hz60, -- Input/combat rate; analytical timelines and animations sample independently at 60 Hz.
	Priority = 2000,
	FacingResponsiveness = 18, -- Shared physical facing response per second; local camera-facing visuals are immediate.
	SchemaVersion = 1,
	Diagnostics = false,
	ClientSimulation = {
		LocalPlayer = {
			Movement = {
				GroundJump = true, -- Ground-jump request from the shared Jump action.
				AirJump = true, -- Air-jump impulse and consumption flag.
				WallJumpAndSlide = true, -- Wall detection, slide clamp and wall-jump impulse/count.
				KnockbackRecoveryJump = true, -- Jump out of eligible Cartoon flight; pair with CartoonMotion.
				FacingRotation = true, -- Predict the same facing decisions as the server.
			},
			Combat = {
				AttackChargeAndRelease = true, -- Attack edges, cancellation, strength and charge movement slowdown.
				AttackCooldowns = true, -- Predict the next attack-ready timestamp on release.
				AbilityActivationAndCooldowns = true, -- Ability edges, active lifetime and per-ability ready timestamps.
			},
			AbilityMovement = {
				Dash = true, -- Dash velocity from the tracked active ability and aim.
				MegaJump = true, -- One impulse per tracked ability ID.
				ChargeSteering = true, -- Charge direction, turn limit, speed and Humanoid movement.
				SmashRiseAndDive = true, -- Smash trajectory and landing state.
			},
			CartoonMotion = true, -- Knockback collisions, trajectory, phase/timers and root projection.
			BodyScaling = true, -- Body scale timeline, dimensions, hip height and joint/mesh offsets.
			WeaponScaling = true, -- Weapon scale timeline and geometry, including body-scale contribution.
			GameplayAnimations = true, -- Shared locomotion, attack and ability Animator updates.
		},
		NPCs = {
			WalkingFromServerIntent = true, -- Apply SANpcDirection through Humanoid:Move on this client.
			-- Current NPC facing uses Humanoid auto-rotation plus server-issued CFrames.
			-- False skips our client AutoRotate assignment; authoritative turns still replicate.
			FacingFromServerIntent = true,
			CartoonMotion = true, -- NPC knockback solver; training bags are unaffected.
			GameplayAnimations = true, -- Shared NPC locomotion and attack Animator updates.
		},
		Arena = {
			ShrinkingGeometry = true, -- Shrink dimensions, relative positions and mesh projection.
			FallingGeometry = true, -- Falling phase and shake/drop transforms.
			CollisionDeadlines = true, -- Disable platform collision/query/touch at its tracked deadline.
			-- Shrink/fall share transforms; disabling only one is a diagnostic combination.
		},
	},
	ClientPresentation = {
		FacingVisualResponsiveness = 20, -- Exponential response per second for scripted/NPC visuals; local camera facing is immediate.
		CorrectionSmoothTime = 0.1, -- SmoothDamp time in seconds for visual position/rotation errors.
		CorrectionDeadzone = {
			PositionStart = 0.1, -- Studs of accumulated visual error required to start damping.
			PositionStop = 0.02, -- Stop damping and hold this small residual instead of snapping it away.
			YawStartDegrees = 2, -- Degrees of accumulated visual yaw error required to start damping.
			YawStopDegrees = 0.5, -- Lower stop threshold prevents on/off chatter near the boundary.
		},
		MotionCorrectionSmoothing = true, -- Damp corrected predicted motion; never smooth the physical root outside replay.
		TimelineVisuals = true, -- Evaluate actor scale/drop paths on decorative geometry every render frame.
		FacingRotationSmoothing = true, -- Present local camera facing immediately without yaw corrections; physics stays replayable.
		ArenaVisuals = true, -- One decorative owner for continuous arena shrinking and falling.
		CartoonVisualRigs = true, -- Create isolated rigs, reactions/trails and redirect the local camera.
		CartoonCorrectionSmoothing = true, -- Dampen visual offsets only; false follows the simulated root directly.
	},
}

export type Simulation = typeof(Config)
return table.freeze(Config)
