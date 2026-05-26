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
  options.my.hibernation.enable =
    mkEnableOption "hibernation + suspend-then-hibernate";

  config = mkIf cfg.enable {
    # Resume from the swapfile on the unlocked LUKS btrfs.
    boot.resumeDevice = "/dev/mapper/cryptroot";

    # Resume offset of /swap/swapfile, from `btrfs inspect-internal map-swapfile`.
    # Without it, hibernation suspends fine but fails to RESUME (cold boot on wake).
    # Re-derive and update this if the swapfile is ever recreated.
    boot.kernelParams = [ "resume_offset=533760" ];

    # Lid-close behavior, by context:
    #   battery / AC (not docked) -> suspend-then-hibernate (sleep, then hibernate
    #     after HibernateDelaySec). AC uses this too so that closing the lid while
    #     plugged and THEN unplugging while asleep still hibernates instead of
    #     draining in S3 — the lid action fires once and isn't re-evaluated on a
    #     power-source change. Cost: hibernates ~45min after lid-close even if it
    #     stays plugged in.
    #   docked (>1 display) -> ignore (clamshell on the Thunderbolt dock).
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend-then-hibernate";              # on battery
      HandleLidSwitchExternalPower = "suspend-then-hibernate"; # on AC: same, so unplug-while-asleep still hibernates
      HandlePowerKey = "suspend-then-hibernate";
      # Docked = logind counts >1 connected display as docked -> ignore the lid, so
      # closing it on the Thunderbolt dock stays awake. (systemd default; explicit
      # here to document intent.)
      HandleLidSwitchDocked = "ignore";
    };
    systemd.sleep.settings.Sleep.HibernateDelaySec = "45min";
  };
}
