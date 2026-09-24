# git-wip: unfinished work follows you between machines (see ../pkgs/git-wip).
#
# Every minute each machine applies newer work from the others and publishes its
# own, as git bundles in the Nextcloud-synced ~/Documents/GitWip. Only repos
# already cloned under ~/Repos take part. A systemd user timer on Linux (NixOS
# and Crostini), launchd agents on macOS. Publishing on suspend is separate:
# modules/nixos/common.nix on NixOS (a system unit, since only those can order
# before sleep.target), sleepwatcher here on macOS. Crostini has no sleep hook
# (ChromeOS freezes the container), so its work goes out on the timer alone.
#
# Imported by home/common.nix, so every host gets it.
{ pkgs, lib, config, osConfig ? null, ... }:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # Same host naming as ./claude-backup.nix; it names this machine's bundles.
  host =
    if isDarwin then "chris-macbook"
    else if osConfig == null then "chris-crostini"
    else osConfig.networking.hostName;
  git-wip = pkgs.callPackage ../pkgs/git-wip { inherit host; };
  logFile = "${config.home.homeDirectory}/Library/Logs/git-wip.log";
in
# mkIf, not optionalAttrs, for the platform split: see ./claude-backup.nix.
{
  home.packages = [ git-wip ];   # `git wip status|take|keep|undo`

  # "⚠ wip diverged" while a divergence waits on take/keep, and "⇄ <host>" for an
  # hour after another machine's work lands here. Prints nothing otherwise, which
  # hides the module.
  programs.starship.settings.custom.git_wip = {
    command = "git-wip prompt";
    when = true;
    require_repo = true;
    style = "bold yellow";
    format = "[$output]($style) ";
    description = "git-wip: work synced in from another machine, or a divergence";
  };

  systemd.user.services.git-wip = lib.mkIf (!isDarwin) {
    Unit.Description = "Sync unfinished git work with the other machines";
    Service = {
      Type = "oneshot";
      ExecStart = "${git-wip}/bin/git-wip sync --all";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
  # A realtime (OnCalendar) timer, unlike a monotonic one, fires straight after
  # resume if a tick was missed while asleep, so a lid-open picks up work at once.
  systemd.user.timers.git-wip = lib.mkIf (!isDarwin) {
    Unit.Description = "Sync unfinished git work every minute";
    Timer = { OnCalendar = "minutely"; AccuracySec = "10s"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };

  launchd.agents.git-wip = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${git-wip}/bin/git-wip" "sync" "--all" ];
      StartInterval = 60;
      RunAtLoad = true;
      ProcessType = "Background";
      LowPriorityIO = true;
      Nice = 19;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };
  # sleepwatcher runs the command when the Mac is about to sleep and holds the
  # sleep until it exits, which gives the pre-sleep settle time to upload.
  launchd.agents.git-wip-sleep = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${pkgs.sleepwatcher}/bin/sleepwatcher" "-s" "${git-wip}/bin/git-wip pre-sleep" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };
}
