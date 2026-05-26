# Secure Boot via lanzaboote. Hardens the TPM2 LUKS auto-unlock by measuring the
# boot path — without it, an attacker can swap the initrd and the TPM still
# unlocks. On NixOS this is clean (Nix owns the signing chain): no shim/MOK dance.
#
# TWO-PHASE. Keep `my.secureBoot.enable = false` for the FIRST install (you boot
# with systemd-boot). Then, on the running system:
#   1. sudo sbctl create-keys
#   2. set my.secureBoot.enable = true; sudo nixos-rebuild switch --flake .#chris-laptop  (signs boot files)
#   3. reboot -> firmware -> put Secure Boot in "setup mode"
#   4. sudo sbctl enroll-keys --microsoft   # MS keys TOO, so WINDOWS still boots
#   5. enable Secure Boot in firmware
#   6. Windows prompts for the BitLocker key once (PCR 7 changed) — you have it
#   7. re-enroll the TPM2 LUKS keyslot now SB is measured (bind to PCRs incl. 7):
#        sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+2+7 \
#          /dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NJ0Y432453X-part2
#   verify: sudo sbctl status   (Secure Boot: enabled, your keys + MS enrolled)
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.secureBoot;
in {
  options.my.secureBoot.enable = mkEnableOption "Secure Boot via lanzaboote";

  config = mkIf cfg.enable {
    # lanzaboote REPLACES systemd-boot with a signed stub loader.
    boot.loader.systemd-boot.enable = mkForce false;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";  # sbctl key store (persisted via impermanence)
    };
  };
}
