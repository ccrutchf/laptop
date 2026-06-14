# Hibernation + suspend-then-hibernate.
#
# Use case: laptop goes in a bag for a weekend — suspend to RAM for instant
# resume on a quick reopen, but transition to full hibernation after a delay so
# it can't spuriously wake or drain. Swap is the 64G NoCoW swapfile from
# disko-config.nix; zswap + mem_sleep_default=deep are set in configuration.nix.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.hibernation;
in {
  options.my.hibernation = {
    enable = mkEnableOption "hibernation + suspend-then-hibernate";
    resumeOffset = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Physical offset of /swap/swapfile (`btrfs inspect-internal map-swapfile`).
        INSTALL-SPECIFIC — re-derive on reinstall. The resume_offset kernel param is
        only set when non-null; without it hibernation suspends but won't RESUME.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Resume from the swapfile on the unlocked LUKS btrfs.
    boot.resumeDevice = "/dev/mapper/cryptroot";

    # resume_offset comes from the install-specific my.hibernation.resumeOffset
    # (set in configuration.nix). Only appended when non-null.
    boot.kernelParams = optional (cfg.resumeOffset != null)
      "resume_offset=${toString cfg.resumeOffset}";

    # Lid-close behavior, by context:
    #   battery / AC (not docked) -> suspend-then-hibernate (sleep, then hibernate
    #     after HibernateDelaySec). AC uses this too so that closing the lid while
    #     plugged and THEN unplugging while asleep still hibernates instead of
    #     draining in S3 — the lid action fires once and isn't re-evaluated on a
    #     power-source change. Cost: hibernates ~45min after lid-close even if it
    #     stays plugged in.
    #   docked (>1 display) -> ignore (clamshell on the Thunderbolt dock).
    services.logind.settings.Login = {
      # Lid handling is delegated to the compositor (home-hyprland.nix: lidClose),
      # NOT logind. logind's "docked" detection is unreliable under Hyprland — it
      # fired suspend-then-hibernate on lid-close while docked (despite
      # HandleLidSwitchDocked = ignore), which wedges the Thunderbolt controller.
      # Hyprland reads the DRM connectors directly and only suspends when undocked.
      # (If GNOME is ever restored, GNOME handles the lid via its own inhibitor, so
      # "ignore" here is fine for both.)
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
      # Power key remains an explicit, deliberate sleep request.
      HandlePowerKey = "suspend-then-hibernate";
    };
    systemd.sleep.settings.Sleep.HibernateDelaySec = "45min";
  };
}
