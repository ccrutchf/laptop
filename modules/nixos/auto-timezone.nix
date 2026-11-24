# Time zone follows location: automatic-timezoned asks geoclue (Wi-Fi via
# beaconDB, see desktop.nix) where the laptop is and sets the zone through
# systemd-timedated, so landing abroad needs no rebuild.
#
# The catch is impermanence: /etc/localtime lives on the ephemeral root, so every
# boot would start in UTC until geoclue gets a fix, and stay there without one
# (no Wi-Fi yet, or Wi-Fi beaconDB doesn't know). So the last zone is kept in
# /persist/etc/timezone, saved whenever /etc/localtime changes and at shutdown,
# and put back early in boot, before anything reads the clock's zone.
#
# Manual override (e.g. if a full-tunnel VPN makes it guess the wrong place):
#   sudo systemctl stop automatic-timezoned && timedatectl set-timezone Asia/Shanghai
# It stays until the next boot, when detection runs again.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.autoTimezone;
  state = "/persist/etc/timezone";

  save = pkgs.writeShellScript "timezone-save" ''
    target=$(${pkgs.coreutils}/bin/readlink /etc/localtime) || exit 0
    tz=''${target#*/zoneinfo/}
    [ -n "$tz" ] && [ "$tz" != "$target" ] && [ -f "/etc/zoneinfo/$tz" ] || exit 0
    [ "$(${pkgs.coreutils}/bin/cat ${state} 2> /dev/null)" = "$tz" ] && exit 0
    ${pkgs.coreutils}/bin/mkdir -p ${dirOf state}
    echo "$tz" > ${state}.tmp && ${pkgs.coreutils}/bin/mv ${state}.tmp ${state}
  '';

  restore = pkgs.writeShellScript "timezone-restore" ''
    tz=$(${pkgs.coreutils}/bin/cat ${state} 2> /dev/null)
    [ -n "$tz" ] && [ -f "/etc/zoneinfo/$tz" ] || tz=${escapeShellArg cfg.fallback}
    ${pkgs.coreutils}/bin/ln -sfn "/etc/zoneinfo/$tz" /etc/localtime
  '';
in {
  options.my.autoTimezone = {
    enable = mkEnableOption "time zone set automatically from geoclue location";
    fallback = mkOption {
      type = types.str;
      default = "America/Los_Angeles";
      description = "Zone used at boot when no zone has been saved yet (impermanent root only).";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    { services.automatic-timezoned.enable = true; }

    (mkIf config.my.impermanence.enable {
      systemd.services.timezone-persist = {
        description = "Restore the last time zone at boot, save it at shutdown";
        unitConfig.DefaultDependencies = false;
        after = [ "local-fs.target" ];   # /persist is mounted; stops before it unmounts
        before = [ "sysinit.target" "automatic-timezoned.service" "shutdown.target" ];
        conflicts = [ "shutdown.target" ];
        wantedBy = [ "sysinit.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${restore}";
          ExecStop = "${save}";
        };
      };

      # Save as soon as the zone changes too, so a crash or power loss keeps it.
      systemd.paths.timezone-save = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "/etc/localtime";
      };
      systemd.services.timezone-save = {
        description = "Save the current time zone to /persist";
        serviceConfig = { Type = "oneshot"; ExecStart = "${save}"; };
      };
    })
  ]);
}
