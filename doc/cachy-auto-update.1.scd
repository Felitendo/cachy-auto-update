cachy-auto-update(1)

# NAME

cachy-auto-update - unattended background updates for CachyOS

# SYNOPSIS

*cachy-auto-update* [_command_] [_options_]

# DESCRIPTION

*cachy-auto-update* keeps a CachyOS machine current without anybody having to
think about it: repository packages, AUR packages, Flatpaks and AppImages are
updated in the background, with no password prompt and no terminal.

Run without a command it opens a small interactive menu with the two switches
that matter - automatic updates on/off and notifications on/off - plus the
current status.

The actual work is done by a systemd system service. The timer ticks hourly;
whether a tick does anything is decided by _UpdateInterval_ (daily by default).
A run that is postponed - low battery, a game running, somebody else using
pacman - is simply retried at the next tick.

# COMMANDS

*enable*
	Turn automatic updates on and enable the systemd timer.

*disable*
	Turn automatic updates off and stop the timer.

*notifications* on|off
	Turn desktop notifications on or off.

*status*
	Show the current state plus an evaluation of every condition that can
	postpone a run. This is the first thing to look at when the updater
	appears to be doing nothing.

*run* [--force] [--dry-run]
	Update now. *--force* skips the interval, battery and gaming checks;
	*--dry-run* lists what would be updated and changes nothing. The check
	for another running package manager is never skipped.

*log* [-n _num_] [-f] [-a]
	Show the log of the last run. *-a* shows the rolling log instead, *-f*
	follows it.

*-h*, *--help*
	Show a short help text.

*-V*, *--version*
	Show the version.

# CONDITIONS

Before anything is installed, a run is postponed when:

- the battery is below _MinBatteryPercent_ (ignored on mains power, and on
  machines without a battery);
- _RequireAC_ is set and the machine is not plugged in;
- a game is running - detected via GameMode, a list of known game processes, or
  an application holding a blocking idle inhibitor;
- pacman's database is locked, or pacman, yay, paru, pamac or a similar tool is
  running.

The last check is what keeps *cachy-auto-update* out of the way of manual
package management. It cannot work in the other direction: if a manual pacman
run starts while an update is already in flight, that run will report the usual
locked-database error.

# HOW UPDATES ARE APPLIED

Repository packages are updated with *pacman -Syu --noconfirm*, but only after
*checkupdates*(8) has confirmed there is something to do, so on a quiet day
pacman's lock is never taken at all.

A package that has to replace another one is handled silently. If pacman would
stop to ask whether a conflicting package may be removed, the transaction is
retried once with that question answered affirmatively, unless
_AutoResolveConflicts_ is turned off. Files on disk that collide with a package
are *not* forced - that stays a human decision. A signature failure triggers one
keyring refresh and one retry.

AUR packages are built and installed as the locked *cachy-auto-update* system
account, because *makepkg*(8) refuses to run as root. That account has no
password and no shell, and is allowed - through _/etc/sudoers.d/cachy-auto-update_
- to invoke *pacman* without one. No user password is ever stored anywhere.

A failed AUR build is not reported the first time it happens; only a failure
that repeats is worth waking somebody up for.

Flatpak system installations are updated directly as root, user installations
inside each user's own account. AppImages are updated through Gear Lever, for
users with a graphical session, and AppImages whose application is currently
running are skipped.

The machine is never restarted automatically. When a kernel update makes a
restart necessary, a notification says so.

# INTERRUPTED UPDATES

While a transaction is running, *cachy-auto-update* holds a
*systemd-inhibit*(1) lock on _sleep_ and _shutdown_ in blocking mode, so a
suspend, a lid close or a normal shutdown request cannot cut it short.

A hard power-off - holding the power button, or losing mains power - is not
preventable. On the next run a leftover _/var/lib/pacman/db.lck_ is removed if
it is older than the current boot, since no process able to hold it can still
exist; the upgrade is then repeated and pacman reinstalls whatever was caught
half-written. A lock file that is unheld but was created during the current
boot is reported rather than removed, because there is no way to prove it is
abandoned.

Without that recovery a single power cut would leave a lock that makes every
subsequent run defer, silently stopping updates for good.

On Btrfs with *snapper*(8) and *snap-pac*, each pacman transaction is bracketed
by a pre and post snapshot, so a broken upgrade remains rollbackable.

# FILES

_/etc/cachy-auto-update/cachy-auto-update.conf_
	Configuration. See the comments in the file itself for every option.

_/etc/sudoers.d/cachy-auto-update_
	Lets the build account call pacman without a password.

_/var/log/cachy-auto-update/last-run.log_
	Full output of the most recent run.

_/var/log/cachy-auto-update/cachy-auto-update.log_
	Rolling log across runs.

_/var/lib/cachy-auto-update/_
	State: timestamps, counters, queued notifications.

# SEE ALSO

*pacman*(8), *checkupdates*(8), *paru*(8), *yay*(8), *flatpak*(1),
*systemd.timer*(5)

# AUTHOR

Felitendo. Source and bug reports:
https://github.com/Felitendo/cachy-auto-update
