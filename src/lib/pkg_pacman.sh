# shellcheck shell=bash
#
# Repository packages.
#
# The whole step is skipped when checkupdates reports nothing pending, which
# matters more than it looks: checkupdates works against a private temporary
# database, so on the common "nothing to do" day the real pacman lock is never
# taken at all and a human using pacman is never inconvenienced.

CAU_PACMAN_COUNT=0
CAU_PACMAN_PENDING=''

# Base flags for every unattended pacman invocation.
cau_pacman_flags() {
	printf '%s\n' --noconfirm --color never --noprogressbar --disable-download-timeout
	local pkg
	for pkg in $CFG_IGNORE_PKG; do
		printf '%s\n' --ignore "$pkg"
	done
}

# cau_pacman_pending
# Fills CAU_PACMAN_PENDING and returns 1 when there is nothing to do.
cau_pacman_pending() {
	local db

	cau_have checkupdates || {
		# Without pacman-contrib we cannot look ahead cheaply; assume work.
		CAU_PACMAN_PENDING=''
		return 0
	}

	# Kept out of CAU_CACHEDIR, which belongs to the unprivileged build
	# account; this one is written by root. pacman keeps its own sync
	# databases under /var/lib too.
	db="${CAU_STATEDIR}/checkupdates-db"
	mkdir -p "$db" 2>/dev/null || db="${TMPDIR:-/tmp}/cachy-auto-update-checkupdates"

	CAU_PACMAN_PENDING="$(CHECKUPDATES_DB="$db" checkupdates --nocolor 2>/dev/null)"
	local rc=$?

	# exit 2 means "no updates", anything else non-zero is a lookup failure and
	# is treated as "might have work" so a transient network hiccup does not
	# silently skip the whole run
	if (( rc == 2 )) || [[ -z $CAU_PACMAN_PENDING ]]; then
		return 1
	fi
	return 0
}

# _cau_pacman_classify <logfile>
# Which kind of unattended failure was this?
_cau_pacman_classify() {
	local log="$1"

	if grep -qiE 'are in conflict|unresolvable package conflicts' "$log"; then
		printf 'conflict\n'
	elif grep -qiE 'signature from .* is (unknown trust|marginal trust|invalid)|invalid or corrupted package \(PGP signature\)|key ".*" is unknown|keyring is not writable' "$log"; then
		printf 'keyring\n'
	elif grep -qiE 'exists in filesystem' "$log"; then
		printf 'filesystem\n'
	else
		printf 'other\n'
	fi
}

# cau_pacman_update
# Returns 0 on success (including "nothing to do"), 1 on a failure the user
# needs to hear about. CAU_PACMAN_COUNT holds how many packages moved.
cau_pacman_update() {
	local log kind
	local -a flags

	if ! cau_pacman_pending; then
		cau_info "No repository updates pending"
		return 0
	fi

	if [[ -n $CAU_PACMAN_PENDING ]]; then
		CAU_PACMAN_COUNT="$(grep -c . <<< "$CAU_PACMAN_PENDING")"
		[[ $CAU_PACMAN_COUNT =~ ^[0-9]+$ ]] || CAU_PACMAN_COUNT=0
		cau_info "Updating $CAU_PACMAN_COUNT repository package(s)"
	else
		# checkupdates is unavailable, so the list is unknown and pacman is
		# asked to work it out itself.
		CAU_PACMAN_COUNT=0
		cau_info "Running a full system upgrade (pending list unavailable)"
	fi

	mapfile -t flags < <(cau_pacman_flags)
	log="$(mktemp)" || return 1

	if pacman -Syu "${flags[@]}" > "$log" 2>&1; then
		cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
		rm -f "$log"
		return 0
	fi

	cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
	kind="$(_cau_pacman_classify "$log")"
	cau_warn "pacman -Syu failed ($kind)"

	case "$kind" in
		keyring)
			# A stale keyring is the one failure that is always safe to fix
			# automatically, and it blocks everything else until it is.
			cau_info "Refreshing keyrings and retrying"
			local -a keyrings=()
			pacman -Qq archlinux-keyring &> /dev/null && keyrings+=(archlinux-keyring)
			pacman -Qq cachyos-keyring   &> /dev/null && keyrings+=(cachyos-keyring)
			if (( ${#keyrings[@]} )); then
				cau_run_logged pacman -Sy --noconfirm --color never "${keyrings[@]}" || true
			fi
			if pacman -Syu "${flags[@]}" > "$log" 2>&1; then
				cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
				rm -f "$log"
				return 0
			fi
			cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
			;;

		conflict)
			# A package that has to replace another one. --noconfirm already
			# answers "Replace X with Y?" affirmatively; what it declines is
			# ":: X and Y are in conflict. Remove Y? [y/N]". --ask is pacman's
			# question bitmask: 4 = CONFLICT_PKG, 16 = REMOVE_PKGS.
			if [[ $CFG_RESOLVE_CONFLICTS != yes ]]; then
				cau_error "Package conflict requires a decision (AutoResolveConflicts is off)"
				rm -f "$log"
				return 1
			fi
			cau_info "Resolving package conflicts automatically and retrying"
			if pacman -Syu "${flags[@]}" --ask=20 > "$log" 2>&1; then
				cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
				grep -E '^(removing|replacing) ' "$log" 2>/dev/null \
					| while read -r line; do cau_info "  $line"; done
				rm -f "$log"
				return 0
			fi
			cat "$log" >> "$CAU_RUNLOG" 2>/dev/null
			;;

		filesystem)
			# Untracked files in the way. Forcing --overwrite here could
			# silently clobber something the user put there deliberately, so
			# this one stays a human decision.
			cau_error "Files on disk conflict with the update; manual review needed"
			rm -f "$log"
			return 1
			;;
	esac

	rm -f "$log"
	CAU_PACMAN_COUNT=0
	return 1
}

# cau_pacman_reboot_needed
# The running kernel's module tree no longer carries a vmlinuz, so the kernel
# package was replaced underneath us.
cau_pacman_reboot_needed() {
	[[ ! -f "/usr/lib/modules/$(uname -r)/vmlinuz" ]]
}

# cau_pacman_pacnew_count
# Purely informational; the files themselves are never touched.
cau_pacman_pacnew_count() {
	cau_have pacdiff || { printf '0\n'; return; }
	pacdiff -o 2>/dev/null | grep -c . || printf '0\n'
}

# cau_pacman_cleanup
# Optional and off by default.
cau_pacman_cleanup() {
	local -a orphans

	if [[ $CFG_REMOVE_ORPHANS == yes ]]; then
		mapfile -t orphans < <(pacman -Qtdq 2>/dev/null)
		if (( ${#orphans[@]} )); then
			cau_info "Removing ${#orphans[@]} orphaned package(s)"
			cau_run_logged pacman -Rns --noconfirm --color never "${orphans[@]}" \
				|| cau_warn "Removing orphans failed"
		fi
	fi

	if [[ $CFG_CLEAN_CACHE == yes ]] && cau_have paccache; then
		cau_info "Trimming the package cache"
		cau_run_logged paccache -r --nocolor -k"$CFG_KEEP_OLD"  || cau_warn "paccache -r failed"
		cau_run_logged paccache -ru --nocolor -k0               || cau_warn "paccache -ru failed"
	fi
}
