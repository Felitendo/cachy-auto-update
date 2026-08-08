# shellcheck shell=bash
#
# The interactive front end.
#
# This is the part the machine's owner actually sees, so it stays deliberately
# small: two switches, a status block, and a way to look at what happened.

CAU_UNIT="cachy-auto-update.timer"

# _cau_row <label> <value>
# printf's %-28s pads by bytes, so a label containing "ü" comes out one column
# short. ${#s} counts characters in a UTF-8 locale, so the padding is computed
# here instead - and applied inline, because command substitution would eat the
# trailing spaces again.
_cau_row() {
	local label="$1" value="$2" pad
	pad=$(( 28 - ${#label} ))
	(( pad < 0 )) && pad=0
	printf '  %s%*s %s\n' "$label" "$pad" '' "$value"
}

_cau_onoff() {
	if [[ $1 == yes ]]; then
		printf '%s%s%s' "$CAU_C_GREEN" "$(cau_msg "ON")" "$CAU_C_RESET"
	else
		printf '%s%s%s' "$CAU_C_DIM" "$(cau_msg "OFF")" "$CAU_C_RESET"
	fi
}

# cau_timer_next
# When systemd will fire the timer next, in the user's locale.
cau_timer_next() {
	local raw

	cau_have systemctl || { cau_msg "unknown"; return; }
	systemctl is-enabled --quiet "$CAU_UNIT" 2>/dev/null || { cau_msg "not scheduled"; return; }

	raw="$(systemctl show "$CAU_UNIT" --property=NextElapseUSecRealtime --value 2>/dev/null)"

	if [[ $raw =~ ^[0-9]+$ ]] && (( raw > 0 )); then
		date -d "@$(( raw / 1000000 ))" '+%c'
	elif [[ -n $raw && $raw != 0 && $raw != n/a ]]; then
		printf '%s' "$raw"
	else
		cau_msg "unknown"
	fi
}

# cau_ui_status
# Shared by the `status` subcommand and the menu header.
cau_ui_status() {
	local last_run last_success result counts reboot
	local pac aur fp ai total

	last_run="$(cau_state_read last_run '')"
	last_success="$(cau_state_read last_success '')"
	result="$(cau_state_read last_result '')"
	counts="$(cau_state_read last_counts '0 0 0 0')"
	reboot="$(cau_state_read reboot_needed 0)"

	read -r pac aur fp ai <<< "$counts"
	pac=${pac:-0}; aur=${aur:-0}; fp=${fp:-0}; ai=${ai:-0}
	total=$(( pac + aur + fp + ai ))

	_cau_row "$(cau_msg "Automatic updates")" "$(_cau_onoff "$CFG_ENABLED")"
	_cau_row "$(cau_msg "Notifications")"     "$(_cau_onoff "$CFG_NOTIFICATIONS")"
	printf '\n'

	_cau_row "$(cau_msg "Last check")" "$(cau_time_ago "$last_run")"

	if [[ -n $last_success ]]; then
		_cau_row "$(cau_msg "Last successful update")" \
			"$(date -d "@$last_success" '+%c' 2>/dev/null || printf '%s' "$last_success") ($(cau_msg "%d packages" "$total"))"
	else
		_cau_row "$(cau_msg "Last successful update")" "$(cau_msg "never")"
	fi

	_cau_row "$(cau_msg "Next scheduled run")" "$(cau_timer_next)"

	if [[ $result == failed ]]; then
		printf '\n  %s%s%s\n' "$CAU_C_YELLOW" \
			"$(cau_msg "The last run reported a problem - see 'cachy-auto-update log'.")" \
			"$CAU_C_RESET"
	fi
	if [[ $reboot == 1 ]]; then
		printf '\n  %s%s%s\n' "$CAU_C_YELLOW" \
			"$(cau_msg "A restart is recommended to finish a kernel update.")" \
			"$CAU_C_RESET"
	fi

	local held
	held="$(cau_state_read held_back '')"
	if [[ -n $held ]]; then
		printf '\n  %s%s%s\n' "$CAU_C_YELLOW" \
			"$(cau_msg "Held back: %s" "$held")" "$CAU_C_RESET"
	fi
}

# cau_ui_status_conditions
# Evaluates every gate individually. Without this there is no way to explain
# why an enabled updater has not done anything on somebody else's machine.
cau_ui_status_conditions() {
	local pct

	printf '\n  %s\n' "$(cau_msg "Current conditions:")"

	if cau_on_ac; then
		printf '    %s %s\n' "${CAU_C_GREEN}✔${CAU_C_RESET}" "$(cau_msg "on AC power")"
	else
		pct="$(cau_battery_percent || true)"
		if [[ -n $pct ]]; then
			printf '    %s %s\n' "${CAU_C_DIM}•${CAU_C_RESET}" \
				"$(cau_msg "on battery (%d%%, threshold %d%%)" "$pct" "$CFG_MIN_BATTERY")"
		else
			printf '    %s %s\n' "${CAU_C_DIM}•${CAU_C_RESET}" "$(cau_msg "on battery")"
		fi
	fi

	CAU_SKIP_REASON=''
	if cau_busy; then
		printf '    %s %s\n' "${CAU_C_YELLOW}•${CAU_C_RESET}" "$CAU_SKIP_REASON"
	else
		printf '    %s %s\n' "${CAU_C_GREEN}✔${CAU_C_RESET}" "$(cau_msg "no game detected")"
	fi

	CAU_SKIP_REASON=''
	if cau_package_manager_busy; then
		printf '    %s %s\n' "${CAU_C_YELLOW}•${CAU_C_RESET}" "$CAU_SKIP_REASON"
	else
		printf '    %s %s\n' "${CAU_C_GREEN}✔${CAU_C_RESET}" "$(cau_msg "package system is free")"
	fi
}

# cau_ui_menu
# The default view. Reloads the config after every action so the toggles always
# reflect what is actually on disk.
cau_ui_menu() {
	local choice

	while true; do
		cau_config_load

		clear 2>/dev/null || true
		cau_head "  $CAU_PRETTY"
		cau_ui_status
		printf '\n'
		printf '  [1] %s\n' "$(cau_msg "Toggle automatic updates")"
		printf '  [2] %s\n' "$(cau_msg "Toggle notifications")"
		printf '  [3] %s\n' "$(cau_msg "Update now")"
		printf '  [4] %s\n' "$(cau_msg "Show log")"
		printf '  [5] %s\n' "$(cau_msg "Show current conditions")"
		printf '  [q] %s\n' "$(cau_msg "Quit")"
		printf '\n  > '

		# One keypress, no Enter. -s keeps the raw character out of the
		# display so the echo below is the only thing printed, and a failing
		# read means EOF (Ctrl-D, or a script piping input) - that quits.
		read -rsn1 choice || { printf '\n'; return 0; }
		printf '%s\n' "$choice"

		case "$choice" in
			# The two switches flip and return straight to the menu, where the
			# status block shows the result. Only a warning or an error holds
			# the screen (see CAU_UI_NEEDS_ACK).
			1)
				CAU_UI_NEEDS_ACK=''
				if [[ $CFG_ENABLED == yes ]]; then cau_do_disable; else cau_do_enable; fi
				if [[ -n $CAU_UI_NEEDS_ACK ]]; then cau_pause; fi
				;;
			2)
				CAU_UI_NEEDS_ACK=''
				if [[ $CFG_NOTIFICATIONS == yes ]]; then
					cau_do_notifications off
				else
					cau_do_notifications on
				fi
				if [[ -n $CAU_UI_NEEDS_ACK ]]; then cau_pause; fi
				;;
			3) cau_do_run --force; cau_pause ;;
			4) cau_do_log; cau_pause ;;
			5) cau_ui_status_conditions; cau_pause ;;
			q|Q) return 0 ;;
			$'\e')
				# Arrow keys and friends arrive as ESC [ X. Swallow the rest so
				# one keypress does not redraw the menu three times. Escape is
				# deliberately not a quit key: that would make a stray arrow
				# key close the menu.
				read -rsn2 -t 0.05 _ 2>/dev/null || true
				;;
			# Anything else, Enter included, just redraws.
			*) ;;
		esac
	done
}

cau_pause() {
	printf '\n  %s' "$(cau_msg "Press any key to continue...")"
	read -rsn1 _ || true
	printf '\n'
}
