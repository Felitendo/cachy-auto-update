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
  [6] Settings
  [q] Quit
```

Everything is configurable from **[6] Settings** — a cursor list covering all
eighteen options, so nothing needs a text editor. Arrow keys select, Space or
Right changes a value, `q` goes back; changes are written immediately.

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

- the battery is below 30 % (ignored on mains power; desktops without a battery
  are never affected),
- a game is running: GameMode, a known game process, or anything holding a
  blocking idle inhibitor,
- pacman's database is locked, or `pacman`/`yay`/`paru`/`pamac` is running.

`cachy-auto-update status` prints every one of these individually, which is the
fastest way to find out why nothing is happening.

The machine is **never** restarted on its own. A kernel update that needs a
restart is reported by `cachy-auto-update status`, not by a notification: the
running kernel loses its module tree the moment pacman unpacks the new one, so
a bubble would arrive while the run is still building AUR packages and pulling
Flatpaks — and reads as an invitation to restart in the middle of it.

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
withdrawn again when the result arrives, so it costs one bubble rather than
two. This exists because of what the next paragraph does *not* do.

**A progress bar sits in the notification area for the whole run**, the same
one Dolphin puts there while it copies files: which step is running, which
package is being unpacked, how far along the whole thing is. A twenty-minute
run that shows nothing looks indistinguishable from a hung one, and that is
what gets a machine switched off in the middle of a transaction. See
[The progress bar](#the-progress-bar).

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

## How long notifications stay

A message that means the machine still needs you — an update failed, the
package database is locked, packages had to be held back — **stays until you
dismiss it**. That kind of message is only worth sending if it is still there
when you come back to the machine.

Everything else times out on its own, a successful update included. Nothing
should have to be clicked away for having gone right.

Set per message rather than left to the notification daemon. Daemons do keep
critical-urgency messages up and the spec asks them to, but that is a *should*,
it says nothing about the normal-urgency messages here that still need somebody
to act, and urgency separately controls sound and do-not-disturb bypass — a
different question. Queued messages delivered at the next login keep the same
distinction.

## The progress bar

While a run is working, the notification area carries a live entry — headline,
item count, percentage, and the package currently being unpacked under
*Details*. It is not a notification but a **job**, the same mechanism Dolphin
uses for file copies, which is what gets you a bar rather than a line of text.

Two things about how it is put together:

- The desktop ties a job to the D-Bus connection that asked for it, and
  withdraws the job the moment that connection closes. One-shot bus clients —
  `gdbus`, `busctl`, `dbus-send` — therefore cannot drive one at all, since
  every invocation is a fresh connection that closes immediately. So a small
  helper (`cachy-auto-update-progress`) runs inside each graphical session for
  the length of the update, holding the connection open and taking instructions
  on stdin. It needs **python-gobject**; without it there is simply no bar and
  nothing else changes.
- Working out the upgrade, downloading it and unpacking it are three separate
  steps. The first is the one that used to look broken: between
  `:: Starting full system upgrade...` and the transaction it eventually
  prepares, pacman prints nothing at all, and on a large backlog that silence
  runs to minutes. A counter frozen at "0 of 161" reads as a stuck update, so
  that stretch carries a label and deliberately no counter. On a domestic line
  the download is then the longest of the three, and calling the whole thing
  "installing" would leave the bar at 4% for six minutes.
- A step that turns out to have no work is dropped from the bar rather than
  handed its share for nothing. Packages already in the cache are never
  announced, so a run that only has to unpack skips the download step outright
  instead of leaping 30% the moment unpacking starts — and likewise for AUR
  with nothing pending, or a machine with no Flatpaks. The weights only ever
  have to be right about the steps that actually run.
- pacman's output is line-buffered through `stdbuf`. Writing to a log rather
  than a terminal, libc would hand it over in 4 KB blocks instead, and 4 KB of
  `upgrading foo...` is on the order of a hundred and sixty packages arriving
  at once — which is how a bar comes to sit still and then jump to the end.
- Neither counted phase gets a counter from pacman on an unattended run, so
  both are counted a line at a time — `foo-1.2-1-x86_64 downloading...` and
  `upgrading foo...`. The database sync just before prints the same shape
  (` core downloading...`) with the suffix that would give it away already
  stripped, so counting starts only after pacman's `:: Retrieving packages...`
  header. pacman's other `(n/m)` sequences — checking keys, package integrity,
  loading files — each count to the same total, so only the transaction verbs
  are followed; otherwise the bar would reach the end three times before the
  first package was unpacked.

This is Plasma's job interface. On a desktop that does not implement it the
helper exits quietly and the ordinary notifications carry on as before.

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
- **Reboots** — `status` tells you one is due, never a surprise restart.

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

`make check` runs `bash -n` over every shell file, `py_compile` over the
progress helper, `shellcheck` when available, and validates the sudoers drop-in
with `visudo -c`.

Everything is optional at runtime and degrades to doing less rather than
failing: `pacman-contrib` for `checkupdates`, an AUR helper, `flatpak`, Gear
Lever, `libnotify` for notifications, and `python-gobject` for the progress bar.

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
