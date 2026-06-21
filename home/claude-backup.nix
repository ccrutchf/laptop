# One-way hourly snapshot of ~/.claude into the Nextcloud-synced Documents tree.
#
# Why: the Nextcloud desktop client two-way syncs live files, but Claude Code holds
# its `.jsonl` transcripts open and appends to them for the whole session — a direct
# sync uploads/overwrites them mid-write and corrupts them (the same non-atomic
# failure mode that makes Nextcloud corrupt live `.git` trees; see
# modules/nixos/backups.nix). Instead we rsync a STATIC snapshot into
# ~/Documents/ClaudeBackup/<host>/<os>/ and let Nextcloud sync only that copy; a
# torn read only ever dirties the throwaway snapshot, which the next run heals.
#
# Cross-platform: a systemd user timer on Linux, a launchd agent on macOS — both
# run the same rsync. Imported by home/common.nix, so every host gets it.
#
# REQUIRED companion step (client-side GUI state, not expressible in Nix): remove
# the live ~/.claude folder from the Nextcloud desktop client's sync list, or the
# live directory keeps being synced directly and this is pointless.
{ pkgs, lib, config, ... }:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  host = if isDarwin then "chris-macbook" else "chris-laptop";
  os   = if isDarwin then "osx" else "linux";
  home = config.home.homeDirectory;
  src  = "${home}/.claude/";
  dest = "${home}/Documents/ClaudeBackup/${host}/${os}";

  # --delete prunes deleted sessions from the mirror; the excludes are regenerable
  # churn that would otherwise re-upload on every run. The script mkdir's its own
  # destination so it works as both a oneshot service and a bare launchd program.
  backup = pkgs.writeShellScript "claude-backup" ''
    ${pkgs.coreutils}/bin/mkdir -p ${dest}
    ${pkgs.rsync}/bin/rsync -a --delete \
      --exclude=shell-snapshots/ --exclude=statsig/ \
      ${src} ${dest}/
  '';
in
# Platform split via mkIf, NOT optionalAttrs. optionalAttrs makes the SET of
# top-level option paths depend on `isDarwin` (= pkgs.stdenv…); since `pkgs` is
# resolved through config._module.args, that's an infinite recursion — the module
# fixpoint needs the option paths to build `pkgs`, but the paths need `pkgs`. mkIf
# keeps the paths static and defers only the VALUE, breaking the cycle. Both
# namespaces are declared on both platforms by home-manager (systemd.user.* and
# launchd.agents.* exist but stay inert off-platform — systemd.user.enable
# defaults to isLinux, launchd.enable to isDarwin), so naming the wrong-platform
# option here is harmless as long as we never enable it on that platform.
{
  systemd.user.services.claude-backup = lib.mkIf (!isDarwin) {
    Unit.Description = "Snapshot ~/.claude into the Nextcloud-synced Documents tree";
    Service = {
      Type = "oneshot";
      ExecStart = "${backup}";
    };
  };
  systemd.user.timers.claude-backup = lib.mkIf (!isDarwin) {
    Unit.Description = "Hourly snapshot of ~/.claude for Nextcloud";
    Timer = { OnCalendar = "hourly"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };

  # launchd has no ExecStartPre or Persistent catch-up; RunAtLoad re-runs at login
  # so a window missed while asleep/logged-out heals (closest to the timer's
  # Persistent=true).
  launchd.agents.claude-backup = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${backup}" ];
      StartCalendarInterval = [ { Minute = 0; } ];   # top of every hour
      RunAtLoad = true;
      StandardOutPath = "${home}/Library/Logs/claude-backup.log";
      StandardErrorPath = "${home}/Library/Logs/claude-backup.log";
    };
  };
}
