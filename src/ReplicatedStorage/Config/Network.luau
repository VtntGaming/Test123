--!strict
return table.freeze({
	SnapshotRate = 20,
	InterpolationDelay = 0.1,
	MaxPayloadBytes = 850,
	MaxSnapshots = 12,
	MaxPendingSessions = 64,
	MaxPendingMessages = 64,
	PendingTimeout = 1,
	ResyncInterval = 1,
	Diagnostics = false, -- Local counters only; never replicated as attributes.
})

