# shellcheck shell=bash
#
# Cancel and pause, from the buttons on the desktop's progress entry.
#
# A progress helper reports a click as one line on its stdout: "cancel",
# "pause" or "resume". Those lines land here, in a loop that runs next to the
# update as root.
#
# Nothing is ever cut off while it installs. Every long command runs through
# cau_work, which records what kind of command it is, and the loop only stops
# it where that is safe:
#
#   pacman   while it syncs and downloads, never once it checks or installs
#   aur      while paru builds, never while it holds pacman's lock
#   flatpak  any time, a deploy is atomic
#   other    never, the run stops or pauses once it is done
#
# Pause stops the command the same way. On resume the step runs again and
# picks up what is already downloaded.

CAU_CONTROL_FIFO="${CAU_RUNDIR}/control"
CAU_CONTROL_CANCEL="${CAU_RUNDIR}/cancel"
CAU_CONTROL_PAUSE="${CAU_RUNDIR}/pause"
CAU_CONTROL_WORK="${CAU_RUNDIR}/work"
CAU_CONTROL_STOPPED="${CAU_RUNDIR}/stopped"

CAU_CONTROL_FD=''
CAU_CONTROL_PID=0

# cau_control_reset
# A run starts with nothing asked for.
cau_control_reset() {
	rm -f "$CAU_CONTROL_CANCEL" "$CAU_CONTROL_PAUSE" "$CAU_CONTROL_WORK" \
		"$CAU_CONTROL_STOPPED" 2>/dev/null
	return 0
}

cau_control_cancelled() { [[ -e $CAU_CONTROL_CANCEL ]]; }

# cau_control_stopped
# Whether the last cau_work command was stopped by a click rather than ending
# on its own.
cau_control_stopped() { [[ -e $CAU_CONTROL_STOPPED ]]; }

# cau_control_wait
# Waits for as long as the run is paused. Fails once it is cancelled.
cau_control_wait() {
	cau_control_cancelled && return 1
	[[ -e $CAU_CONTROL_PAUSE ]] || return 0

	cau_info "Paused"
	cau_progress_suspended 1
	while [[ -e $CAU_CONTROL_PAUSE ]] && ! cau_control_cancelled; do
		sleep 1
	done
	cau_control_cancelled && return 1

	cau_info "Resumed"
	cau_progress_suspended 0
	return 0
}

# cau_work <kind> <note> <command> [args...]
# Runs a long command where the control loop can find it. kind is one of the
# words at the top, note is the pacman log for kind pacman. Does not start the
# command while the run is paused, and not at all once it is cancelled.
cau_work() {
	local kind="$1" note="$2" rc
	shift 2

	rm -f "$CAU_CONTROL_STOPPED" 2>/dev/null
	cau_control_wait || return 130

	# A subshell, so its pid is the root of everything the command starts.
	(
		printf '%s %s %s\n' "$kind" "$BASHPID" "$note" > "$CAU_CONTROL_WORK" 2>/dev/null
		"$@"
	)
	rc=$?
	rm -f "$CAU_CONTROL_WORK" 2>/dev/null
	return "$rc"
}

# cau_control_open
# The pipe the progress helpers write their clicks into. Read-write, so
# opening it never blocks and it never reports end-of-file.
cau_control_open() {
	CAU_CONTROL_FD=''
	rm -f "$CAU_CONTROL_FIFO" 2>/dev/null
	mkfifo -m 0600 "$CAU_CONTROL_FIFO" 2>/dev/null || return 1
	exec {CAU_CONTROL_FD}<> "$CAU_CONTROL_FIFO" || { CAU_CONTROL_FD=''; return 1; }
}

# cau_control_start
# Only once every helper runs: the loop writes back to them on their pipes.
cau_control_start() {
	[[ -n $CAU_CONTROL_FD ]] || return 0
	_cau_control_loop &
	CAU_CONTROL_PID=$!
}

cau_control_stop() {
	if (( CAU_CONTROL_PID )); then
		kill "$CAU_CONTROL_PID" 2>/dev/null
		wait "$CAU_CONTROL_PID" 2>/dev/null
		CAU_CONTROL_PID=0
	fi
	if [[ -n $CAU_CONTROL_FD ]]; then
		exec {CAU_CONTROL_FD}>&-
		CAU_CONTROL_FD=''
	fi
	rm -f "$CAU_CONTROL_FIFO" 2>/dev/null
	return 0
}

_cau_control_loop() {
	local line rc

	while :; do
		read -r -t 1 -u "$CAU_CONTROL_FD" line
		rc=$?

		if (( rc == 0 )); then
			# Only these three words. The line comes from a user's process.
			case "$line" in
				cancel) _cau_control_cancel ;;
				pause)  _cau_control_pause ;;
				resume) _cau_control_resume ;;
			esac
			continue
		fi
		(( rc > 128 )) || sleep 1

		# Asked for but not safe a moment ago. paru holds pacman's lock only
		# while it installs, so a few seconds later it usually is.
		if [[ -e $CAU_CONTROL_CANCEL || -e $CAU_CONTROL_PAUSE ]]; then
			_cau_control_interrupt
		fi
	done
}

_cau_control_cancel() {
	[[ -e $CAU_CONTROL_CANCEL ]] && return 0
	: > "$CAU_CONTROL_CANCEL"
	rm -f "$CAU_CONTROL_PAUSE"
	cau_info "Cancel requested from the desktop"

	_cau_control_interrupt
	(( $? == 1 )) || return 0

	# The desktop drops the progress entry two seconds after the click, so a
	# step that has to finish first is announced with a notification.
	cau_info "Stopping once the current step is done"
	cau_notify_tagged run no normal no \
		"Stopping the update" \
		"The current step is finished first. Please leave the computer switched on until then."
}

_cau_control_pause() {
	[[ -e $CAU_CONTROL_CANCEL || -e $CAU_CONTROL_PAUSE ]] && return 0
	: > "$CAU_CONTROL_PAUSE"
	cau_info "Pause requested from the desktop"

	_cau_control_interrupt
	(( $? == 1 )) || return 0
	cau_progress_note "Pausing once the current step is done"
}

_cau_control_resume() {
	[[ -e $CAU_CONTROL_PAUSE ]] || return 0
	rm -f "$CAU_CONTROL_PAUSE"
	# In case it never got as far as pausing.
	cau_progress_note ''
}

# _cau_control_interrupt
# Stops what cau_work runs, if that is safe right now. Returns 0 when it was
# stopped, 1 when it is not safe yet, 2 when nothing is running.
_cau_control_interrupt() {
	local kind pid note p comm
	local -a tree

	[[ -e $CAU_CONTROL_STOPPED ]] && return 0
	{ read -r kind pid note < "$CAU_CONTROL_WORK"; } 2>/dev/null || return 2
	[[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 2
	mapfile -t tree < <(_cau_control_tree "$pid")

	case "$kind" in
		pacman)
			# Once the downloads are done pacman checks and then installs. A
			# signal from there on could leave half an upgrade behind.
			grep -qaE "$CAU_PACMAN_COMMIT_RE" "$note" 2>/dev/null && return 1

			# Marked first: the main loop looks for it as soon as pacman exits.
			# SIGINT, not SIGTERM: pacman catches it, ends the download and
			# releases its lock.
			: > "$CAU_CONTROL_STOPPED"
			for p in "${tree[@]}"; do
				{ read -r comm < "/proc/$p/comm"; } 2>/dev/null || continue
				[[ $comm == pacman ]] && kill -INT "$p" 2>/dev/null
			done
			;;
		aur)
			[[ -e $CAU_PACMAN_LOCK ]] && return 1

			# Frozen before the second look at the lock, so paru cannot start
			# installing in between.
			kill -STOP "${tree[@]}" 2>/dev/null
			mapfile -t tree < <(_cau_control_tree "$pid")
			kill -STOP "${tree[@]}" 2>/dev/null
			if ! _cau_control_frozen "${tree[@]}" || [[ -e $CAU_PACMAN_LOCK ]]; then
				kill -CONT "${tree[@]}" 2>/dev/null
				return 1
			fi

			: > "$CAU_CONTROL_STOPPED"
			kill -TERM "${tree[@]}" 2>/dev/null
			kill -CONT "${tree[@]}" 2>/dev/null
			;;
		flatpak)
			: > "$CAU_CONTROL_STOPPED"
			kill -TERM "${tree[@]}" 2>/dev/null
			;;
		*)
			return 1
			;;
	esac

	cau_info "Stopped the running $kind step"
	return 0
}

# _cau_control_tree <pid>
# The pid and every process below it, parents first.
_cau_control_tree() {
	ps -e -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
		{ kids[$2] = kids[$2] " " $1 }
		END {
			n = 1; q[1] = root
			for (i = 1; i <= n; i++) {
				print q[i]
				m = split(kids[q[i]], c, " ")
				for (j = 1; j <= m; j++) q[++n] = c[j]
			}
		}'
}

# _cau_control_frozen <pid...>
# Waits up to two seconds until every one of them has really stopped. SIGSTOP
# lands a moment later, and the lock check after it must not race a process
# that is still running.
_cau_control_frozen() {
	local p line state tries=40 busy nap

	exec {nap}<> <(:)
	while (( tries-- > 0 )); do
		busy=0
		for p in "$@"; do
			{ read -r line < "/proc/$p/stat"; } 2>/dev/null || continue
			state="${line##*) }"
			state="${state%% *}"
			[[ $state == [TtZX] ]] || { busy=1; break; }
		done
		if (( ! busy )); then
			exec {nap}>&-
			return 0
		fi
		read -r -t 0.05 -u "$nap" _ || true
	done
	exec {nap}>&-
	return 1
}
