# shellcheck shell=bash
#
# The update's progress bar on the desktop.
#
# An unattended upgrade can take twenty minutes, and for most of that a user is
# told only that "an update is running". This drives the desktop's job list -
# the same widget that shows a bar while Dolphin copies files - so how far
# along the run is stays visible the whole time.
#
# The desktop ends the progress entry as soon as the D-Bus connection that
# asked for it goes away, which no one-shot bus client can survive. So an
# actual process per session holds that connection open and takes instructions
# on stdin; see cachy-auto-update-progress. Everything below is the writing end
# of those pipes, plus the arithmetic that turns "package 120 of 260 in the
# repository step" into one number for the bar.
#
# Absent anywhere along the way - no session, no Plasma, no Python bindings -
# this does nothing at all and the update proceeds exactly as before.

CAU_PROGRESS_HELPER="${CAU_LIBEXECDIR}/cachy-auto-update-progress"

# One entry per session being driven; the indices line up across all four.
CAU_PROGRESS_FDS=()
CAU_PROGRESS_PIDS=()
CAU_PROGRESS_FIFOS=()
CAU_PROGRESS_LOCALES=()

# What each step is worth on the bar. Rough shares of a typical run rather than
# anything measured: the repositories dominate - fetching them and unpacking
# them about equally, on a domestic line - and the cleanup is a rounding error.
# They do not have to add up to 100 - only the steps a given run will actually
# perform are counted, and the total is normalised against those.
declare -A CAU_PROGRESS_WEIGHTS=(
	[download]=30 [repo]=40 [aur]=15 [flatpak]=10 [appimage]=3 [cleanup]=2
)

CAU_PROGRESS_PLAN=()
CAU_PROGRESS_SCALE=0
CAU_PROGRESS_BASE=0
CAU_PROGRESS_SPAN=0
CAU_PROGRESS_TOTAL=0
CAU_PROGRESS_SHOWN=-1

# _cau_progress_send <line>
# The same instruction to every session. A session whose helper has exited is
# dropped rather than written to: the runner writes into a pipe, and a pipe
# nobody is draining fills up and would eventually block the update itself.
_cau_progress_send() {
	local i fd

	for i in "${!CAU_PROGRESS_FDS[@]}"; do
		fd="${CAU_PROGRESS_FDS[$i]}"
		[[ -n $fd ]] || continue

		if ! kill -0 "${CAU_PROGRESS_PIDS[$i]}" 2>/dev/null; then
			CAU_PROGRESS_FDS[$i]=''
			continue
		fi

		printf '%s\n' "$1" >&"$fd" 2>/dev/null || CAU_PROGRESS_FDS[$i]=''
	done
}

# _cau_progress_line <format> [printf args...]
# Assembled with printf -v rather than in a command substitution: this is on
# the per-package path of a large upgrade, and a fork per line is a fork too
# many for something whose entire job is to be unobtrusive.
_cau_progress_line() {
	local line
	# shellcheck disable=SC2059  # the format is ours; the arguments are numbers
	printf -v line "$@"
	_cau_progress_send "$line"
}

# cau_progress_begin <step-id...>
# Opens the progress entry in every graphical session, and records which steps
# this run is going to perform so the bar can be scaled to them.
cau_progress_begin() {
	local user uid fifo pid
	local fd=''

	CAU_PROGRESS_PLAN=("$@")
	CAU_PROGRESS_SCALE=0
	local step
	for step in "${CAU_PROGRESS_PLAN[@]}"; do
		CAU_PROGRESS_SCALE=$(( CAU_PROGRESS_SCALE + ${CAU_PROGRESS_WEIGHTS[$step]:-0} ))
	done
	(( CAU_PROGRESS_SCALE > 0 )) || return 0

	[[ $CFG_NOTIFICATIONS == yes ]] || return 0
	[[ -x $CAU_PROGRESS_HELPER ]] || return 0
	mkdir -p "$CAU_RUNDIR" 2>/dev/null || return 0

	while read -r user uid; do
		[[ -n $user ]] || continue

		# The helper speaks D-Bus through GLib's Python bindings. Checked here
		# rather than left to fail inside the helper, because a helper that
		# gave up immediately would leave nobody draining the pipe.
		cau_as_user "$user" "$uid" sh -c \
			'command -v python3 >/dev/null 2>&1 && python3 -c "import gi" 2>/dev/null' \
			|| continue

		fifo="${CAU_RUNDIR}/progress.${uid}"
		rm -f "$fifo" 2>/dev/null
		mkfifo -m 0600 "$fifo" 2>/dev/null || continue
		chown "$uid" "$fifo" 2>/dev/null || true

		cau_as_user "$user" "$uid" "$CAU_PROGRESS_HELPER" < "$fifo" > /dev/null 2>&1 &
		pid=$!

		# Read-write deliberately. Opening the writing end of a fifo blocks
		# until a reader shows up, so if the helper died on the way in, the
		# update would hang here for good. O_RDWR never blocks, and the helper
		# still sees end-of-file once this descriptor is closed.
		if ! exec {fd}<> "$fifo"; then
			kill "$pid" 2>/dev/null
			rm -f "$fifo" 2>/dev/null
			continue
		fi

		CAU_PROGRESS_FDS+=("$fd")
		CAU_PROGRESS_PIDS+=("$pid")
		CAU_PROGRESS_FIFOS+=("$fifo")
		CAU_PROGRESS_LOCALES+=("$(cau_user_locale "$user" "$uid")")
	done < <(cau_active_session_users)
}

# cau_progress_active
# Whether anybody is listening. For callers that would otherwise do work whose
# only purpose is to feed the bar.
cau_progress_active() {
	(( ${#CAU_PROGRESS_FDS[@]} ))
}

# cau_progress_step <step-id> <label-msgid> [item-count]
# Moves on to the next step. The bar jumps to where that step begins, so a step
# that reported fewer items than it promised still completes rather than
# leaving a gap.
cau_progress_step() {
	local id="$1" label="$2" total="${3:-0}"
	local step i fd base=0

	(( ${#CAU_PROGRESS_FDS[@]} )) || return 0

	for step in "${CAU_PROGRESS_PLAN[@]}"; do
		[[ $step == "$id" ]] && break
		base=$(( base + ${CAU_PROGRESS_WEIGHTS[$step]:-0} ))
	done

	CAU_PROGRESS_BASE=$base
	CAU_PROGRESS_SPAN=${CAU_PROGRESS_WEIGHTS[$id]:-0}
	CAU_PROGRESS_TOTAL=$total

	# The label is the one line a user actually reads, so it is rendered in
	# each session's own locale rather than the run's C locale.
	for i in "${!CAU_PROGRESS_FDS[@]}"; do
		fd="${CAU_PROGRESS_FDS[$i]}"
		[[ -n $fd ]] || continue
		cau_msg_into "${CAU_PROGRESS_LOCALES[$i]}" "$label"
		printf 'info\t%s\n' "$CAU_MSG_RESULT" >&"$fd" 2>/dev/null || true
	done

	# Unconditionally, including the zero case: a step with no item count of
	# its own would otherwise keep displaying the previous step's tally, and
	# "260 of 260 items" under the heading "Flatpaks" is worse than no count.
	_cau_progress_line 'total\t%s' "$total"
	_cau_progress_line 'done\t%s' 0

	cau_progress_item 0
}

# cau_progress_item <processed> [total]
# How far through the current step we are.
cau_progress_item() {
	local processed="$1" total="${2:-$CAU_PROGRESS_TOTAL}" pct scaled

	(( ${#CAU_PROGRESS_FDS[@]} )) || return 0
	[[ $processed =~ ^[0-9]+$ ]] || return 0

	if [[ $total =~ ^[0-9]+$ ]] && (( total > 0 )); then
		(( processed > total )) && processed=$total
		if (( total != CAU_PROGRESS_TOTAL )); then
			CAU_PROGRESS_TOTAL=$total
			_cau_progress_line 'total\t%s' "$total"
		fi
		_cau_progress_line 'done\t%s' "$processed"
		scaled=$(( CAU_PROGRESS_BASE * 100 + CAU_PROGRESS_SPAN * 100 * processed / total ))
	else
		scaled=$(( CAU_PROGRESS_BASE * 100 ))
	fi

	pct=$(( scaled / CAU_PROGRESS_SCALE ))
	(( pct > 100 )) && pct=100

	# Only when the whole number changes. Percent is the one field the runner
	# would otherwise rewrite for every package on a 500-package upgrade.
	(( pct == CAU_PROGRESS_SHOWN )) && return 0
	CAU_PROGRESS_SHOWN=$pct
	_cau_progress_line 'percent\t%s' "$pct"
}

# cau_progress_detail <label-msgid> <value>
# A labelled line under the entry's "Details" - which package is being unpacked
# right now, say.
cau_progress_detail() {
	local label="$1" value="$2" i fd

	(( ${#CAU_PROGRESS_FDS[@]} )) || return 0

	for i in "${!CAU_PROGRESS_FDS[@]}"; do
		fd="${CAU_PROGRESS_FDS[$i]}"
		[[ -n $fd ]] || continue
		cau_msg_into "${CAU_PROGRESS_LOCALES[$i]}" "$label"
		printf 'detail\t%s\t%s\n' "$CAU_MSG_RESULT" "$value" >&"$fd" 2>/dev/null || true
	done
}

# cau_progress_end [outcome: ok|failed] [failure-msgid]
# Closes the entry. Must run on every exit path, including a killed run: an
# entry whose owner merely vanishes is reported by the desktop as "the
# application closed unexpectedly", which would end every update with a failure
# notice. Safe to call twice, and safe to call when nothing was ever opened.
#
#   ok             the bar fills and the entry goes away
#   failed         the entry goes away from wherever the bar had got to
#   failed <msgid> and the desktop labels it as failed, with that text
#
# The distinction between the last two is which message the user ends up with.
# An ordinary failure already sends a notification that stays until dismissed,
# and two messages about one problem is one too many; a run that was killed
# sends nothing at all, so there the label is the only thing that explains why
# a bar that was at 40% is suddenly gone.
cau_progress_end() {
	local outcome="${1:-ok}" msgid="${2:-}"
	local i fd

	# The last step never consumes its own share - nothing reports items for
	# the cleanup - so the bar would stop a few percent short of the end and
	# vanish there. Only on the way out of a run that actually worked, though:
	# filling the bar for a failed update says the opposite of what happened.
	[[ $outcome == ok ]] && _cau_progress_line 'percent\t100'

	for i in "${!CAU_PROGRESS_FDS[@]}"; do
		fd="${CAU_PROGRESS_FDS[$i]}"
		[[ -n $fd ]] || continue

		CAU_MSG_RESULT=''
		[[ -n $msgid ]] && cau_msg_into "${CAU_PROGRESS_LOCALES[$i]}" "$msgid"

		printf 'end\t%s\n' "$CAU_MSG_RESULT" >&"$fd" 2>/dev/null || true
		exec {fd}>&-
	done

	for i in "${!CAU_PROGRESS_PIDS[@]}"; do
		wait "${CAU_PROGRESS_PIDS[$i]}" 2>/dev/null
	done

	for i in "${!CAU_PROGRESS_FIFOS[@]}"; do
		rm -f "${CAU_PROGRESS_FIFOS[$i]}" 2>/dev/null
	done

	CAU_PROGRESS_FDS=()
	CAU_PROGRESS_PIDS=()
	CAU_PROGRESS_FIFOS=()
	CAU_PROGRESS_LOCALES=()
	CAU_PROGRESS_SHOWN=-1
}
