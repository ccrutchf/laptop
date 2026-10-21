# Unattended upgrades from GitHub main, without ever undoing local work.
#
# The weekly .github/workflows/update-flake-lock.yml bumps flake.lock and pushes
# it only after every host passes CI; this pulls `github:<repo>#<host>` daily and
# builds it as the NEXT BOOT's default (`operation = "boot"`): nothing restarts
# under a running session, the change lands at whatever reboot the user picks,
# and the previous generation stays in the boot menu.
#
# The catch with pulling from GitHub: a generation switched in from a local
# checkout (uncommitted, unpushed, or on a branch) would be silently replaced by
# main. So every build records the commit it came from (system.configurationRevision,
# set in flake.nix; "<rev>-dirty" for an uncommitted tree), and the guard below
# runs the upgrade only when both the running system AND the boot default were
# built from a commit already on main. Otherwise it skips, and says why in the
# journal (`journalctl -u nixos-upgrade`). Commit, push and switch from the clean
# tree, and upgrades resume.
#
# Also skipped: on battery (ConditionACPower) and on a metered network
# (NetworkManager's flag, as git-wip reads it), since a build can pull gigabytes.
#
# Notifications go to notifyUser's GNOME session, if one is open (and the first
# one also to readyUsers, who have nothing to act on in the other two):
#   - an update is ready (once per new generation): takes effect on restart;
#   - the upgrade failed (e.g. a nixpkgs bump broke a local patch at build time,
#     which CI's eval cannot catch);
#   - no new generation in staleDays, whether skipped or just not moving.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.autoUpgrade;
  profile = "/nix/var/nix/profiles/system";

  notify = pkgs.writeShellScript "auto-upgrade-notify" ''
    # $1 = user, $2 = title, $3 = body. A no-op when the user has no session bus.
    uid=$(${pkgs.coreutils}/bin/id -u "$1") || exit 0
    bus=/run/user/$uid/bus
    [ -S "$bus" ] || exit 0
    ${pkgs.util-linux}/bin/runuser -u "$1" -- \
      ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      ${pkgs.libnotify}/bin/notify-send --app-name="System update" \
        --icon=software-update-available "$2" "$3" || true
  '';

  # True (exit 0) when no generation has been created in staleDays.
  stale = pkgs.writeShellScript "auto-upgrade-stale" ''
    [ -n "$(${pkgs.findutils}/bin/find ${profile} -maxdepth 0 -mtime +${toString cfg.staleDays})" ]
  '';

  # ExecCondition: exit 0 runs the upgrade, 1 skips it (the unit is not failed).
  guard = pkgs.writeShellScript "auto-upgrade-guard" ''
    set -u
    skip() {
      echo "skipping: $1"
      if ${stale}; then
        ${notify} ${cfg.notifyUser} "No system update in ${toString cfg.staleDays} days" "$1"
      fi
      exit 1
    }

    metered=$(${pkgs.dbus}/bin/dbus-send --system --print-reply=literal \
      --dest=org.freedesktop.NetworkManager /org/freedesktop/NetworkManager \
      org.freedesktop.DBus.Properties.Get \
      string:org.freedesktop.NetworkManager string:Metered 2> /dev/null | ${pkgs.gawk}/bin/awk '{ print $NF }')
    case $metered in 1|3) skip "on a metered network" ;; esac   # NM_METERED_YES, _GUESS_YES

    for p in /run/current-system ${profile}; do
      what=$([ "$p" = /run/current-system ] && echo "the running system" || echo "the boot default")
      rev=$("$p/sw/bin/nixos-version" --configuration-revision 2> /dev/null) \
        || skip "$what records no source commit (built before my.autoUpgrade). Switch once from a clean, pushed checkout."
      case $rev in
        *-dirty) skip "$what was built from uncommitted changes (''${rev%-dirty}). Commit, push, and switch from the clean tree." ;;
      esac
      # compare/<rev>...<branch> is "ahead" or "identical" when rev is in the branch's history.
      body=$(${pkgs.curl}/bin/curl -sS --max-time 30 -w '\n%{http_code}' \
        "https://api.github.com/repos/${cfg.repo}/compare/$rev...${cfg.branch}") \
        || skip "GitHub unreachable"
      code=''${body##*$'\n'}
      [ "$code" = 404 ] && skip "$what was built from $rev, which is not on GitHub. Push it."
      [ "$code" = 200 ] || skip "GitHub answered HTTP $code"
      status=$(printf '%s' "''${body%$'\n'*}" | ${pkgs.jq}/bin/jq -r .status)
      case $status in
        ahead|identical) ;;
        *) skip "$what was built from $rev, which is not on ${cfg.branch} ($status). Merge or push it." ;;
      esac
    done
  '';

  # ExecStartPost (after a successful build).
  report = pkgs.writeShellScript "auto-upgrade-report" ''
    new=$(${pkgs.coreutils}/bin/readlink -f ${profile})
    if [ "$new" != "$(${pkgs.coreutils}/bin/readlink -f /run/booted-system)" ] \
       && [ "$new" != "$(${pkgs.coreutils}/bin/cat /run/auto-upgrade-notified 2> /dev/null)" ]; then
      for u in ${toString ([ cfg.notifyUser ] ++ cfg.readyUsers)}; do
        ${notify} "$u" "System update ready" "It takes effect the next time you restart."
      done
      echo "$new" > /run/auto-upgrade-notified
    elif ${stale}; then
      ${notify} ${cfg.notifyUser} "No system update in ${toString cfg.staleDays} days" \
        "Upgrades run, but ${cfg.branch} isn't moving. Check the update-flake-lock workflow on GitHub."
    fi
  '';
in {
  options.my.autoUpgrade = {
    enable = mkEnableOption "daily unattended upgrades from GitHub, guarded against local builds";
    repo = mkOption {
      type = types.str;
      default = "ccrutchf/laptop";
      description = "GitHub owner/repo the flake is pulled from.";
    };
    branch = mkOption {
      type = types.str;
      default = "main";
      description = "Branch upgrades follow; a local build not in its history pauses them.";
    };
    notifyUser = mkOption {
      type = types.str;
      default = "chris";
      description = "Whose GNOME session gets the update notifications.";
    };
    readyUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Other users told only that an update is ready to apply on restart, not
        about failures or stalls, which they can't act on.
      '';
    };
    staleDays = mkOption {
      type = types.int;
      default = 10;
      description = ''
        Warn when no new generation has appeared in this many days. Above the
        weekly lock update, so a single missed week doesn't nag.
      '';
    };
  };

  config = mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "github:${cfg.repo}/${cfg.branch}#${config.networking.hostName}";
      operation = "boot";
      dates = "daily";
      randomizedDelaySec = "45min";
      persistent = true;   # a day the laptop was asleep runs at the next wake
    };

    systemd.services.nixos-upgrade = {
      unitConfig.ConditionACPower = true;
      onFailure = [ "nixos-upgrade-failed.service" ];
      serviceConfig = {
        ExecCondition = "${guard}";
        ExecStartPost = "${report}";
      };
    };

    systemd.services.nixos-upgrade-failed = {
      description = "Notify that the unattended NixOS upgrade failed";
      serviceConfig.Type = "oneshot";
      script = ''
        ${notify} ${cfg.notifyUser} "System update failed" \
          "See: journalctl -u nixos-upgrade. The current system is unchanged."
      '';
    };
  };
}
