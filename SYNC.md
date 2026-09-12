# Syncing repos across the three laptops

Nextcloud syncs everything else, but it must never touch `~/Repos`: its
non-atomic writes corrupt live `.git` trees, and it has no way to merge two
machines' edits. Git already *is* a sync protocol — the only missing piece was
something to drive it without being asked. That's `git-sync`.

## The model

A bare-repo hub on **`ogre01:/mnt/data/srv`**, mirroring the `~/Repos` layout:

```
~/Repos/personal/laptop   ->   ogre01:/mnt/data/srv/personal/laptop.git
~/Repos/work/foo          ->   ogre01:/mnt/data/srv/work/foo.git
```

Each bare repo holds, from all three laptops:

| ref | what it is |
| --- | --- |
| `refs/heads/*` | your real branches — fast-forward pushes only, never forced |
| `refs/wip/<host>/<branch>` | a snapshot of that machine's working tree, **including uncommitted and untracked files** |

Every 10 minutes each laptop pushes its snapshot, fast-forward-pushes its real
branches and tags, and fetches everything back. Other machines' work then exists
locally as `refs/remotes/hub/*` and `refs/remotes/wip/*`.

Repos are adopted automatically: anything under `~/Repos` with a `.git` gets a
`hub` remote and a bare repo created for it on first sight. There is nothing to
set up per repo, and a repo only has to exist on the machines you actually use it
on — the Visual Studio ones can live on Windows alone and still be synced and
backed up.

## What it will never do

- **It does not touch your working state.** The snapshot commit is built through
  a throwaway index (`GIT_INDEX_FILE`) with git plumbing, so `HEAD`, the real
  index, the stash and the working tree are never modified. `git status` looks
  identical before and after.
- **It never merges or checks anything out for you.** Fetching only moves
  remote-tracking refs. Pulling another machine's work in is always a command you
  type — a background job mutating a tree you might be mid-edit in is the exact
  surprise this design exists to avoid.
- **It never writes to `origin`.** WIP goes only to `hub`. If a repo's origin is a
  public GitHub repo, half-finished work cannot leak there.
- **It never force-pushes a branch.** Only `refs/wip/<this host>/…` is forced, and
  that namespace belongs to one machine, so machines cannot clobber each other.
  A diverged branch fails the push harmlessly and waits for you.

## Getting another machine's work

```
git wip list             # what snapshots exist, and how old
git wip diff <host>      # what that machine has that you don't
git wip log <host>       # commits it has that you don't
git wip take <host>      # check that snapshot out as a local branch
```

`take` refuses to run on a dirty tree and only ever creates a branch
(`wip/<host>/<branch>`), so it cannot eat uncommitted work.

## Safety rails

A repo that forgot to `.gitignore` its build output would otherwise ship
gigabytes to the hub every ten minutes, so a snapshot that would add more than
2000 files is skipped and logged, and any single file over 100 MiB is dropped
from the snapshot (the rest is still captured). A global ignore file covers the
usual regenerable junk (`.direnv/`, `result`, `__pycache__/`, `.venv/`, …).

If the hub is unreachable — you're travelling, the server is down — the run logs
one line and exits 0. Nothing is lost; the next tick that reaches it catches up.

## Setup

**Server** (once, on `ogre01`):

```sh
./server/setup-hub.sh          # creates /mnt/data/srv, enables a weekly gc timer
```

Then from each laptop, `ssh-copy-id chris@ogre01` so the hub accepts the
Nextcloud-synced key.

**NixOS and macOS**: nothing. `home/git-sync.nix` is imported by `home/common.nix`,
so `nixos-rebuild switch` / `darwin-rebuild switch` installs the timer, the
scripts and the `git wip` alias. Tunables live under `my.gitSync`
(`hub`, `hubPath`, `root`, `interval`, `sshOptions`).

**Windows** (once, non-admin PowerShell):

```powershell
cd $HOME\Repos\personal\laptop
powershell -ExecutionPolicy Bypass -File .\windows\bootstrap.ps1
```

That installs the scripts to `%LOCALAPPDATA%\git-sync`, registers the Scheduled
Task, and sets the git config that keeps repos portable (`core.autocrlf=true` so
the object store stays LF, `fileMode=false` because NTFS has no exec bit,
`longpaths=true`, `symlinks=true`). Re-run it after pulling this repo to update.

## Reaching the hub from outside the LAN

`ogre01` only resolves at home, so today sync pauses when you travel and resumes
when you get back — safe, but the trip itself has no off-machine copy. Once the
server is reachable from outside (it already fronts Nextcloud publicly), point
`my.gitSync.hub` — or just the `Host ogre01` block in `~/.ssh/config` — at the
public name. Use `my.gitSync.sshOptions` / `-SshOpts` for a non-standard port.
No other change is needed.

## Operating it

| | NixOS | macOS | Windows |
| --- | --- | --- | --- |
| force a run | `systemctl --user start git-sync` | `git-sync` | `powershell -File %LOCALAPPDATA%\git-sync\git-sync.ps1` |
| logs | `journalctl --user -u git-sync` | `~/Library/Logs/git-sync.log` | `%LOCALAPPDATA%\git-sync\git-sync.log` |
| schedule | `systemctl --user list-timers git-sync` | `launchctl list \| grep git-sync` | `Get-ScheduledTask git-sync` |

Sync is not backup: the hub is a single machine, and `~/Repos` on the NixOS host
is still backed up by restic (`modules/nixos/backups.nix`). Back up
`/mnt/data/srv` too — it is now the only place all three laptops' work meets.
