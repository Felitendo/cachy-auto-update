# shellcheck shell=bash
#
# Staying out of the way of a human using pacman/yay/paru.
#
# The contract this file implements: the machine's owner may run any package
# manager at any time and must never see a lock error caused by us. We can only
# guarantee that in one direction - by never *starting* while somebody else is
# mid-transaction - so the checks here run before anything is touched, and a
# refusal simply defers the run to the next hourly tick.

# Package managers that take /var/lib/pacman/db.lck. checkupdates is absent on
# purpose: it works against a private temporary database and never touches the
# real lock.
CAU_PACKAGE_MANAGERS=(
	pacman pacman-static
	yay paru pikaur aurman trizen
	pamac pamac-daemon pamac-manager pamac-tray
	octopi octopi-helper
	makepkg
)

# cau_acquire_lock
# Guards against two runs overlapping (a slow run still going when the next
# tick fires). Non-blocking: if another run holds it, this one is pointless.
cau_acquire_lock() {
	mkdir -p "$CAU_RUNDIR" 2>/dev/null || return 1

	exec {CAU_LOCK_FD}> "$CAU_LOCKFILE" || return 1
	flock -n "$CAU_LOCK_FD" || return 1

	return 0
}

# cau_pacman_lock_holder
# Prints the pids currently holding pacman's database lock, if any.
cau_pacman_lock_holder() {
	[[ -e $CAU_PACMAN_LOCK ]] || return 1
	cau_have fuser || return 0     # cannot tell; assume it is held
	fuser "$CAU_PACMAN_LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || return 0
}

# cau_package_manager_busy
# True when somebody else is using the package system right now. Sets
# CAU_SKIP_REASON.
cau_package_manager_busy() {
	local pm

	if [[ -e $CAU_PACMAN_LOCK ]]; then
		CAU_SKIP_REASON="$(cau_msg "pacman's database is locked by another process")"
		return 0
	fi

	for pm in "${CAU_PACKAGE_MANAGERS[@]}"; do
		if cau_process_running "$pm"; then
			CAU_SKIP_REASON="$(cau_msg "%s is currently running" "$pm")"
			return 0
		fi
	done

	return 1
}

# cau_track_stale_lock
# A db.lck with no process behind it is left over from a crashed transaction.
# Removing it automatically would be reckless - if the guess is wrong it
# corrupts a live transaction - so instead it is counted, and after enough
# consecutive sightings the user is told to clean it up.
CAU_STALE_LOCK_RUNS=3

cau_track_stale_lock() {
	local count

	if [[ ! -e $CAU_PACMAN_LOCK ]]; then
		cau_state_clear stale_lock_count
		return 1
	fi

	if [[ -n "$(cau_pacman_lock_holder)" ]]; then
		# genuinely held; not stale
		cau_state_clear stale_lock_count
		return 1
	fi

	count="$(cau_state_read stale_lock_count 0)"
	[[ $count =~ ^[0-9]+$ ]] || count=0
	count=$(( count + 1 ))
	cau_state_write stale_lock_count "$count"

	(( count >= CAU_STALE_LOCK_RUNS ))
}

# cau_inhibit_prefix
# Builds the command prefix that keeps logind from suspending or shutting the
# machine down mid-transaction. Falls back to running unprotected rather than
# refusing to update at all.
cau_inhibit_prefix() {
	if cau_have systemd-inhibit; then
		printf '%s\n' systemd-inhibit
		printf '%s\n' --what=sleep:shutdown
		printf '%s\n' --mode=block
		printf '%s\n' "--who=$CAU_PRETTY"
		printf '%s\n' "--why=$(cau_msg_in C "applying system updates")"
		printf '%s\n' --
	fi
}
