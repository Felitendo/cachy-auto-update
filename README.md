# cachy-auto-update

Unattended background updates for CachyOS — no password prompt, no terminal,
nothing to remember.

Built for the machine you set up for somebody else and would rather not have to
maintain: it updates pacman packages, AUR packages, Flatpaks and AppImages by
itself, stays out of the way while they are gaming or on battery, never touches
the package database while they are using `pacman` by hand, and only speaks up
when something actually needs a human.

```bash
sudo cachy-auto-update
```

That opens a menu with the two switches there are:

```
  CachyOS Auto-Update

  Automatic updates            ON
  Notifications                ON

  Last check                   3 hours ago
  Last successful update       Sat 08 Aug 2026 04:12:03 CEST (23 packages)
  Next scheduled run           Sat 08 Aug 2026 05:00:00 CEST

  [1] Toggle automatic updates
  [2] Toggle notifications
  [3] Update now
  [4] Show log
  [5] Show current conditions
  [q] Quit
```

The interface is fully translated; on a German system everything above appears
in German.

## Install

```bash
paru -S cachy-auto-update
sudo cachy-auto-update enable
```

Updates are **off** until you enable them — a freshly installed package has no
business rebuilding somebody's system before being asked.

## What it updates

| | |
|---|---|
| Repository packages | `pacman -Syu`, after `checkupdates` confirms there is work |
| AUR | `paru` or `yay`, whichever is installed |
| Flatpak | system and per-user installations |
| AppImages | via [Gear Lever](https://github.com/mijorus/gearlever), if installed |

It also trims the pacman package cache after each run (`paccache`, keeping the
3 most recent versions), because otherwise `/var/cache/pacman/pkg` grows
forever — tens of gigabytes on a machine with a few large packages. Set
`KeepOldPackages=1` if disk space matters more than the ability to downgrade.

`-git`/`-devel` AUR packages and orphan removal exist as options but are off by
default. Orphan removal deletes installed software, and "orphaned" only means
nothing else depends on it — which is also true of something installed
deliberately.

## When it holds back

A run is postponed — and retried an hour later — when:

- the battery is below 40 % (ignored on mains power; desktops without a battery
  are never affected),
- a game is running: GameMode, a known game process, or anything holding a
  blocking idle inhibitor,
- pacman's database is locked, or `pacman`/`yay`/`paru`/`pamac` is running.

`cachy-auto-update status` prints every one of these individually, which is the
fastest way to find out why nothing is happening.

The machine is **never** restarted on its own. When a kernel update needs a
restart, you get a notification saying so.

## About the password question

The obvious way to automate `yay`/`paru` is to store the user's password
somewhere. This does not do that, and deliberately so: anything the daemon can
decrypt is exactly what an attacker who reaches the daemon already has, so the
encryption would be decoration.

Instead:

- The updater is a **system service running as root**, so `pacman` needs no
  escalation at all.
- `makepkg`, `paru` and `yay` refuse to run as root, so the AUR step drops to a
  dedicated **locked system account** (`cachy-auto-update`, no password,
  `/usr/bin/nologin`, its own home under `/var/lib`). Only root can become it.
- That account gets one line in `/etc/sudoers.d/cachy-auto-update` allowing it
  to call `/usr/bin/pacman` without a password — which is what lets the helper
  install what it built.

No user password is stored, encrypted or otherwise.

If you would rather not have that sudoers rule on the machine, set
`UpdateAUR=no` in the config; everything else keeps working, and the rule
becomes inert.

## Coexisting with manual package management

Before touching anything, the updater checks for `/var/lib/pacman/db.lck` and
for a running `pacman`, `yay`, `paru`, `pamac`, `pikaur`, `octopi` or `makepkg`,
and postpones if it finds one. On a day with no pending repository updates the
real pacman lock is never taken at all, because `checkupdates` works against a
private temporary database.

The reverse direction has an honest limit: if you start `pacman` *while* an
update is already running, you will get the usual "unable to lock database"
message. Nothing outside pacman can prevent that. What the updater does do is
keep the window short, run at low priority, and hold a `systemd-inhibit` lock so
a suspend or shutdown cannot land in the middle of a transaction.

A leftover `db.lck` from a crashed transaction is never deleted automatically —
guessing wrong there corrupts a live transaction. After it has been seen
unheld on several consecutive runs, you get a notification instead.

## What if the machine is switched off mid-update

Three layers, in order of how much they can actually promise:

**A notification goes out before the transaction starts** — "Installing
updates, please leave the computer switched on until this is done" — and is
replaced in place by the result when the run finishes, so it costs one bubble
rather than two. This exists because of what the next paragraph does *not* do.

**Suspend and a normal shutdown are blocked.** The run holds a
`systemd-inhibit --what=sleep:shutdown --mode=block` lock, so closing the lid or
picking "Shut down" cannot interrupt a transaction. Be aware of what that looks
like, though: logind refuses the request and requires the polkit action
`org.freedesktop.login1.power-off-ignore-inhibit`, which is `auth_admin_keep`.
The desktop therefore answers a shutdown attempt with an **administrator
password prompt** reading *"Power off the system while an application is
inhibiting this"* — a string systemd ships untranslated, and one that never
mentions updates. No KDE dialog explains the situation. Only `systemctl
poweroff` in a terminal names the reason. That prompt is exactly why the
notification above is on by default.

**A hard power-off cannot be prevented by anything.** Holding the power button
or pulling the plug cuts power in firmware. What limits the damage is that
pacman's commit phase is short (about a minute even for a 200-package upgrade)
and that most of a run is downloading, where an interruption costs nothing but
a partial file.

**The next run repairs it.** A `db.lck` left behind is detected and removed —
but only when it is *provably* dead, meaning it is older than the current boot,
so no process that could hold it still exists. The interrupted upgrade is then
simply run again; pacman reinstalls anything that was caught half-written. A
lock that is merely unheld within the same boot is never removed, only
reported, because there the guess could be wrong.

This last part matters more than it sounds: without it, a single power cut
during an update would leave a lock file that makes every future run defer,
and the machine would stop updating silently and permanently.

On a Btrfs system with `snapper` and `snap-pac` — the CachyOS default — every
pacman transaction is bracketed by a pre and post snapshot, so a genuinely
broken upgrade can still be rolled back with `snapper rollback`.

## Configuration

`/etc/cachy-auto-update/cachy-auto-update.conf`, one `Key=Value` per line, every
option documented in the file. The file is parsed rather than sourced, so a
stray line cannot turn into code executed by root.

```ini
Enabled=yes
Notifications=yes
UpdateInterval=1d
MinBatteryPercent=40
SkipWhenGaming=yes
UpdateAUR=yes
UpdateFlatpak=yes
UpdateAppImages=yes
AutoResolveConflicts=yes
IgnorePkg=
```

## How package conflicts are handled

`pacman -Syu --noconfirm` already answers "Replace X with Y?" affirmatively, so
ordinary replacements happen silently — which is the point.

What `--noconfirm` declines is `:: X and Y are in conflict. Remove Y? [y/N]`,
and that aborts the whole transaction. With `AutoResolveConflicts=yes` (the
default) the transaction is retried once with that question answered too, and
everything removed is written to the log.

Two things are deliberately *not* automated:

- **File conflicts** (`exists in filesystem`) — forcing `--overwrite` could
  silently destroy something that was put there on purpose.
- **Reboots** — you get a notification, never a surprise restart.

Signature failures trigger one keyring refresh and one retry, since a stale
keyring blocks everything else until it is fixed.

## Logs

```bash
cachy-auto-update log        # the last run in full
cachy-auto-update log -a     # the rolling log
journalctl -u cachy-auto-update
```

Both work without root.

## Building from source

```bash
make && sudo make install
sudo systemd-sysusers && sudo systemd-tmpfiles --create
sudo cachy-auto-update enable
```

`make check` runs `bash -n` over everything, `shellcheck` when available, and
validates the sudoers drop-in with `visudo -c`.

## Relationship to cachy-update

[cachy-update](https://github.com/CachyOS/cachy-update) is CachyOS's interactive
updater; every one of its steps sits behind a prompt and its timer only ever
*checks* for updates and notifies. This tool is the unattended counterpart and
reimplements the same command sequence non-interactively, adding the battery,
gaming and lock awareness that unattended operation needs.

The two coexist. `cachy-auto-update enable` offers once to switch off
cachy-update's own "N updates available" notification, since it becomes noise
when updates install themselves.

## License

GPL-3.0-or-later.
