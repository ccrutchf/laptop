# One-way snapshot of ~/.claude into the Nextcloud-synced Documents tree.
#
# Why: the Nextcloud desktop client two-way syncs live files. Claude Code holds
# its `.jsonl` transcripts open and appends to them for the whole session, so a
# direct sync of ~/.claude uploads/overwrites them mid-write and corrupts them —
# the same non-atomic failure mode that makes Nextcloud corrupt live `.git`
# trees (see modules/backups.nix). Instead we rsync a static snapshot into
# ~/Documents/ClaudeBackup/<host>/<os>/ and let Nextcloud sync only that copy.
# The live transcripts are never touched; a torn read only ever dirties the
# throwaway snapshot, which the next run heals.
#
# REQUIRED companion step (client-side GUI state, not expressible in Nix): remove
# the /home/chris/.claude folder from the Nextcloud desktop client's sync list,
# or the live directory keeps being synced directly and this is pointless.
{ pkgs, ... }:
let
  src  = "/home/chris/.claude/";
  dest = "/home/chris/Documents/ClaudeBackup/chris-laptop/linux";
in {
  systemd.user.services.claude-backup = {
    Unit.Description = "Snapshot ~/.claude into the Nextcloud-synced Documents tree";
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${dest}";
      # --delete so deleted sessions are pruned from the mirror. Excludes are pure
      # regenerable churn that would otherwise re-upload on every run.
      ExecStart = "${pkgs.rsync}/bin/rsync -a --delete --exclude=shell-snapshots/ --exclude=statsig/ ${src} ${dest}/";
    };
  };

  systemd.user.timers.claude-backup = {
    Unit.Description = "Hourly snapshot of ~/.claude for Nextcloud";
    Timer = { OnCalendar = "hourly"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };
}
