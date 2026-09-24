# git-wip: carry unfinished work between machines, automatically.
#
# Per repo, each machine snapshots its branches, index and working tree
# (untracked files included, over-50 MB ones skipped) into a commit, and publishes
# it as git bundles at ~/Documents/GitWip/<repo-key>/<host>.{base,snap}.bundle —
# a rarely-rewritten base plus a small layer of recent changes, so an edit costs
# a small upload; on a metered network only uploads up to 1 MB go out. Nextcloud
# carries the bundles; each is one file written by one machine and renamed into
# place, so it can't be torn the way a synced .git tree is (see
# modules/nixos/backups.nix). Only repos already cloned on a machine are synced —
# nothing is ever cloned.
#
# Another machine's snapshot is applied automatically — branches, the checked-out
# branch, index and working tree — when this clone hasn't changed since it last
# synced (the normal hand-off), or when applying it would lose nothing (a clean
# tree whose branches the snapshot already contains). Otherwise the two diverged:
# nothing is applied, the other side's work is kept under refs/wip/<host>/, and a
# notification says to run `git wip take <host>` or `git wip keep`. Every
# automatic overwrite first saves the local state under refs/wip/backup/
# (`git wip undo`).
#
# Built by both the home-manager module (timer, prompt marker) and the NixOS one
# (pre-sleep hook) with the same `host`, so they share one store path.
{ lib, stdenv, writeShellApplication, git, git-lfs, coreutils, findutils, gnused
, gnugrep, gawk, diffutils, flock, libnotify, openssh, dbus, host }:

writeShellApplication {
  name = "git-wip";
  runtimeInputs = [ git git-lfs coreutils findutils gnused gnugrep gawk diffutils flock ]
    # macOS notifies through /usr/bin/osascript and keeps Apple's ssh (keychain);
    # dbus-send asks NetworkManager whether the network is metered.
    ++ lib.optionals stdenv.hostPlatform.isLinux [ libnotify openssh dbus ];
  text = ''
    GIT_WIP_HOST=${lib.escapeShellArg host}
  '' + builtins.readFile ./git-wip.sh;
}
