# shellcheck shell=bash
#
# Reading and writing /etc/cachy-auto-update/cachy-auto-update.conf.
#
# The file is deliberately *parsed* rather than sourced: it is edited by a
# root-run daemon, and sourcing it would turn a stray line into arbitrary code
# execution. The format is one "Key=Value" per line, '#' starts a comment.

# cau_config_get <Key> [default]
cau_config_get() {
	local key="$1" default="${2:-}" val

	[[ -r $CAU_CONFIG ]] || { printf '%s\n' "$default"; return; }

	val="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\\1/p" \
		"$CAU_CONFIG" 2>/dev/null | tail -n1)"

	# strip a trailing comment and surrounding whitespace/quotes
	val="${val%%#*}"
	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"
	val="${val%\"}"
	val="${val#\"}"

	if [[ -n $val ]]; then
		printf '%s\n' "$val"
	else
		printf '%s\n' "$default"
	fi
}

# cau_config_bool <Key> <default: yes|no>
# Succeeds when the key is truthy.
cau_config_bool() {
	local val
	val="$(cau_config_get "$1" "$2")"
	case "${val,,}" in
		yes|y|true|1|on|enabled) return 0 ;;
		*) return 1 ;;
	esac
}

# cau_config_int <Key> <default>
cau_config_int() {
	local val
	val="$(cau_config_get "$1" "$2")"
	[[ $val =~ ^-?[0-9]+$ ]] && printf '%s\n' "$val" || printf '%s\n' "$2"
}

# cau_config_set <Key> <Value>
# Replaces the key in place if present (including a commented-out template
# line), otherwise appends it. Requires write access to the config file.
cau_config_set() {
	local key="$1" value="$2" tmp

	if [[ ! -e $CAU_CONFIG ]]; then
		mkdir -p "$(dirname "$CAU_CONFIG")" || return 1
		printf '# %s configuration\n' "$CAU_NAME" > "$CAU_CONFIG" || return 1
	fi
	[[ -w $CAU_CONFIG ]] || return 1

	tmp="$(mktemp "${CAU_CONFIG}.XXXXXX")" || return 1
	# keep the original permissions rather than mktemp's 0600
	chmod --reference="$CAU_CONFIG" "$tmp" 2>/dev/null || chmod 0644 "$tmp"

	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$CAU_CONFIG"; then
		awk -v key="$key" -v value="$value" '
			!done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=" {
				print key "=" value; done = 1; next
			}
			# drop any further occurrences so the file cannot grow duplicates
			$0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
			{ print }
		' "$CAU_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
	else
		cat "$CAU_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
		printf '%s=%s\n' "$key" "$value" >> "$tmp"
	fi

	mv -f "$tmp" "$CAU_CONFIG"
}

# ---------------------------------------------------------------------------
# Resolved settings
# ---------------------------------------------------------------------------
# Loaded once per process into plain variables so the rest of the code does not
# re-parse the file for every lookup.

cau_config_load() {
	CFG_ENABLED=no;               cau_config_bool Enabled              no  && CFG_ENABLED=yes
	CFG_NOTIFICATIONS=no;         cau_config_bool Notifications        yes && CFG_NOTIFICATIONS=yes
	CFG_REQUIRE_AC=no;            cau_config_bool RequireAC            no  && CFG_REQUIRE_AC=yes
	CFG_SKIP_GAMING=no;           cau_config_bool SkipWhenGaming       yes && CFG_SKIP_GAMING=yes
	CFG_AUR=no;                   cau_config_bool UpdateAUR            yes && CFG_AUR=yes
	CFG_FLATPAK=no;               cau_config_bool UpdateFlatpak        yes && CFG_FLATPAK=yes
	CFG_APPIMAGE=no;              cau_config_bool UpdateAppImages      yes && CFG_APPIMAGE=yes
	CFG_DEVEL=no;                 cau_config_bool UpdateDevel          no  && CFG_DEVEL=yes
	CFG_RESOLVE_CONFLICTS=no;     cau_config_bool AutoResolveConflicts yes && CFG_RESOLVE_CONFLICTS=yes
	CFG_CLEAN_CACHE=no;           cau_config_bool CleanCache           no  && CFG_CLEAN_CACHE=yes
	CFG_REMOVE_ORPHANS=no;        cau_config_bool RemoveOrphans        no  && CFG_REMOVE_ORPHANS=yes
	CFG_NOTIFY_SUCCESS=no;        cau_config_bool NotifyOnSuccess      yes && CFG_NOTIFY_SUCCESS=yes
	CFG_NOTIFY_ERROR=no;          cau_config_bool NotifyOnError        yes && CFG_NOTIFY_ERROR=yes
	CFG_NOTIFY_REBOOT=no;         cau_config_bool NotifyReboot         yes && CFG_NOTIFY_REBOOT=yes

	CFG_INTERVAL="$(cau_config_get UpdateInterval 1d)"
	CFG_INTERVAL_SECONDS="$(cau_duration_to_seconds "$CFG_INTERVAL" 86400)"
	CFG_MIN_BATTERY="$(cau_config_int MinBatteryPercent 40)"
	CFG_KEEP_OLD="$(cau_config_int KeepOldPackages 3)"
	CFG_AUR_HELPER="$(cau_config_get AURHelper auto)"
	CFG_IGNORE_PKG="$(cau_config_get IgnorePkg '')"
}
