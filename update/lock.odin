package update

// LOCK_SUFFIX is the sidecar the operating system locks for the whole
// replace. It is never unlinked: the next update locks the same file, and a
// crash drops the lock when the process ends.
LOCK_SUFFIX :: ".update.lock"

// PART_SUFFIX is the temporary name of a copied backup. It is renamed onto
// <exe>.old only after it is durable, and removed if that does not happen.
PART_SUFFIX :: ".old.part"

// HOLD_COMMIT_ENV, when set, is a gate file the process locks after the
// backup is durable and before the new bytes take the launch path. The
// lifecycle harness holds that gate. A release build leaves it unset.
HOLD_COMMIT_ENV :: "LEITA_UPDATE_HOLD_COMMIT"

// Lock_Result is how taking the install lock went.
Lock_Result :: enum u8 {
	Taken,
	Held, // another update holds it; do not wait for that update
	Failed, // the lock file could not be opened
}
