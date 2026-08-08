# shellcheck shell=bash
#
# Desktop notifications from a root system service.
#
# Two paths exist:
#   * live   - somebody has a graphical session, so notify-send is run inside
#              it via runuser with the session bus address set;
#   * queued - nobody is logged in, so the message is appended to a spool that
#              the XDG autostart entry replays at the next login.
#
# Messages travel as a msgid plus printf arguments rather than as finished
# text, so a notification queued at 04:00 is still rendered in whatever locale
# the user's desktop turns out to be running in.

CAU_NOTIFY_ICON="system-software-update"
CAU_NOTIFY_QUEUE_MAX=20

# cau_notify <urgency> <title-msgid> <body-msgid> [body printf args...]
# Never fails: a machine without libnotify, or with nobody logged in, is a
# normal state, not an error.
cau_notify() {
	cau_notify_tagged '' yes "$@"
}

# cau_notify_tagged <tag> <queue: yes|no> <urgency> <title> <body> [args...]
#
# A tag makes this notification replace the previous one carrying the same tag
# rather than stacking a second bubble beside it - that is what turns
# "installing updates" into "system updated" in place instead of leaving two
# messages that contradict each other.
#
# queue=no is for messages that only mean anything while somebody is looking.
# Telling a user at next login that an update started an hour ago is noise.
cau_notify_tagged() {
	local tag="$1" queue="$2" urgency="$3" title="$4" body="$5"
	shift 5
	local -a args=("$@")
	local delivered=0 user uid locale t b prev newid

	[[ $CFG_NOTIFICATIONS == yes ]] || return 0

	while read -r user uid; do
		[[ -n $user ]] || continue
		cau_as_user "$user" "$uid" sh -c 'command -v notify-send >/dev/null' || continue

		locale="$(cau_user_locale "$user" "$uid")"
		t="$(cau_msg_in "$locale" "$title")"
		b="$(cau_msg_in "$locale" "$body" "${args[@]}")"

		prev=0
		if [[ -n $tag ]]; then
			prev="$(cau_state_read "notify_id_${tag}_${user}" 0)"
			[[ $prev =~ ^[0-9]+$ ]] || prev=0
		fi

		if newid="$(cau_as_user "$user" "$uid" notify-send \
			--app-name="$CAU_PRETTY" \
			--icon="$CAU_NOTIFY_ICON" \
			--urgency="$urgency" \
			--print-id --replace-id="$prev" \
			-- "$t" "$b" 2>/dev/null)"
		then
			delivered=1
			if [[ -n $tag && $newid =~ ^[0-9]+$ ]]; then
				cau_state_write "notify_id_${tag}_${user}" "$newid"
			fi
		fi
	done < <(cau_active_session_users)

	(( delivered )) && return 0
	[[ $queue == yes ]] || return 0

	cau_notify_enqueue "$urgency" "$title" "$body" "${args[@]}"
}

# cau_notify_enqueue <urgency> <title-msgid> <body-msgid> [args...]
# Tab-separated records, oldest first. The file is world-readable on purpose:
# the login-time delivery runs unprivileged and only ever reads it.
#
# The key is a nanosecond timestamp rather than a second one: delivery marks
# progress by "last key seen", so two records sharing a key could make the
# second one unreachable forever if a login landed between them.
cau_notify_enqueue() {
	local urgency="$1" title="$2" body="$3"
	shift 3
	local record tmp

	mkdir -p "$CAU_STATEDIR" 2>/dev/null || return 0

	record="$(date +%s%N)"$'\t'"$urgency"$'\t'"$title"$'\t'"$body"
	local arg
	for arg in "$@"; do
		record+=$'\t'"${arg//$'\t'/ }"
	done

	printf '%s\n' "$record" >> "$CAU_NOTIFY_QUEUE" 2>/dev/null || return 0

	# keep the spool bounded - nobody wants three weeks of backlog at login
	if (( $(wc -l < "$CAU_NOTIFY_QUEUE" 2>/dev/null || echo 0) > CAU_NOTIFY_QUEUE_MAX )); then
		tmp="$(mktemp "${CAU_NOTIFY_QUEUE}.XXXXXX")" || return 0
		tail -n "$CAU_NOTIFY_QUEUE_MAX" "$CAU_NOTIFY_QUEUE" > "$tmp"
		mv -f "$tmp" "$CAU_NOTIFY_QUEUE"
	fi
	chmod 0644 "$CAU_NOTIFY_QUEUE" 2>/dev/null || true
}

# cau_notify_deliver_queue
# Runs unprivileged, as the freshly logged-in user, from the XDG autostart
# entry. State about what has already been seen lives in the user's own home,
# so no write access to /var/lib is needed and each user is tracked separately.
cau_notify_deliver_queue() {
	local seen_file seen ts urgency title body
	local -a args

	[[ -r $CAU_NOTIFY_QUEUE ]] || return 0
	cau_have notify-send || return 0

	seen_file="${XDG_STATE_HOME:-$HOME/.local/state}/cachy-auto-update/notify-seen"
	mkdir -p "$(dirname "$seen_file")" 2>/dev/null || return 0

	seen=0
	[[ -r $seen_file ]] && seen="$(< "$seen_file")"
	[[ $seen =~ ^[0-9]+$ ]] || seen=0

	local newest="$seen"
	while IFS=$'\t' read -r ts urgency title body rest; do
		[[ $ts =~ ^[0-9]+$ ]] || continue
		(( ts > seen )) || continue

		# remaining tab-separated fields are the body's printf arguments
		args=()
		if [[ -n ${rest:-} ]]; then
			IFS=$'\t' read -r -a args <<< "$rest"
		fi

		notify-send \
			--app-name="$CAU_PRETTY" \
			--icon="$CAU_NOTIFY_ICON" \
			--urgency="${urgency:-normal}" \
			-- "$(cau_msg "$title")" "$(cau_msg "$body" "${args[@]}")" 2>/dev/null || true

		(( ts > newest )) && newest="$ts"
	done < "$CAU_NOTIFY_QUEUE"

	printf '%s\n' "$newest" > "$seen_file" 2>/dev/null || true
}
