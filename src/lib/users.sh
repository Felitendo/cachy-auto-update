# shellcheck shell=bash
#
# Finding the humans on this machine and running things on their behalf.
#
# The updater runs as a root system service, but a fair amount of the work
# (per-user Flatpak installations, AppImages, desktop notifications) only makes
# sense inside a user's own session.

# Lowest uid considered a human account. Matches /etc/login.defs on Arch.
CAU_UID_MIN=1000
CAU_UID_MAX=60000

# cau_human_users
# Prints "user uid home" for every non-system account with a real shell.
cau_human_users() {
	local name uid home shell
	while IFS=: read -r name _ uid _ _ home shell; do
		(( uid >= CAU_UID_MIN && uid <= CAU_UID_MAX )) || continue
		case "$shell" in
			*/nologin|*/false|'') continue ;;
		esac
		printf '%s %s %s\n' "$name" "$uid" "$home"
	done < <(getent passwd)
}

# cau_active_sessions
# Prints "user uid session_id" for every seated, graphical, non-closing
# session. These are the sessions a notification can actually reach.
cau_active_sessions() {
	local ids id props name uid class type state

	cau_have loginctl || return 0

	ids="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')"
	[[ -n $ids ]] || return 0

	for id in $ids; do
		props="$(loginctl show-session "$id" \
			--property=Name --property=User --property=Class \
			--property=Type --property=State 2>/dev/null)" || continue

		name=''; uid=''; class=''; type=''; state=''
		while IFS='=' read -r k v; do
			case "$k" in
				Name)  name="$v" ;;
				User)  uid="$v" ;;
				Class) class="$v" ;;
				Type)  type="$v" ;;
				State) state="$v" ;;
			esac
		done <<< "$props"

		[[ $class == user ]] || continue
		[[ $state == active || $state == online ]] || continue
		case "$type" in
			wayland|x11|mir) ;;
			*) continue ;;
		esac
		[[ -n $name && -n $uid ]] || continue

		printf '%s %s %s\n' "$name" "$uid" "$id"
	done
}

# cau_active_session_users
# Deduplicated "user uid" for everyone with a reachable graphical session.
cau_active_session_users() {
	cau_active_sessions | awk '{print $1, $2}' | sort -u
}

# cau_user_locale <user> <uid>
# Best effort at the locale that user's desktop is running in, so a
# notification does not arrive in English on a German machine.
cau_user_locale() {
	local user="$1" uid="$2" locale=''

	if [[ -d "/run/user/$uid" ]]; then
		locale="$(cau_as_user "$user" "$uid" systemctl --user show-environment 2>/dev/null \
			| sed -n 's/^LANG=//p' | head -n1)"
	fi

	if [[ -z $locale && -r /etc/locale.conf ]]; then
		locale="$(sed -n 's/^LANG=//p' /etc/locale.conf | tr -d '"' | head -n1)"
	fi

	printf '%s\n' "${locale:-C}"
}

# cau_as_user <user> <uid> <command> [args...]
# Runs a command as that user with a session-shaped environment. LC_ALL is
# explicitly cleared: the service sets LC_ALL=C for parseable tool output, but
# anything user-facing should follow the user's own locale.
cau_as_user() {
	local user="$1" uid="$2"
	shift 2
	local home
	home="$(getent passwd "$user" | cut -d: -f6)"

	local -a env_args=(
		"HOME=${home:-/home/$user}"
		"USER=$user"
		"LOGNAME=$user"
		"XDG_RUNTIME_DIR=/run/user/$uid"
	)
	[[ -S "/run/user/$uid/bus" ]] && \
		env_args+=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus")

	runuser -u "$user" -- env --unset=LC_ALL "${env_args[@]}" "$@"
}
