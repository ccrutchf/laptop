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

    # GOTCHA — RESUME OFFSET. Hibernating to a btrfs swapfile needs the file's
    # physical offset, which isn't known until disko has created the file. Compute
    # it on the INSTALLED system and uncomment the line below, then rebuild:
    #     sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
    # (Until this is set, hibernation will SUSPEND fine but fail to RESUME.)
    # boot.kernelParams = [ "resume_offset=REPLACE_WITH_OFFSET" ];

    # Lid/idle -> suspend to RAM, then hibernate after the delay (fully off).
    services.logind.settings.Login = {
      HandleLidSwitch = "suspend-then-hibernate";
      HandleLidSwitchExternalPower = "suspend-then-hibernate";
      HandlePowerKey = "suspend-then-hibernate";
    };
    systemd.sleep.settings.Sleep.HibernateDelaySec = "45min";
  };
}
