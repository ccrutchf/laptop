# NixOS entry point for chris-lenovo — Lenovo ThinkPad X1 Carbon Gen 9
# (i7-1185G7 Tiger Lake UP3, 16GB, 512GB NVMe, Intel Iris Xe, no discrete GPU).
#
# Deliberately thin: everything machine-agnostic lives in the shared layers
# (modules/nixos/{common,desktop,overlays}.nix), so this file is hardware and
# this machine's quirks only. Compare hosts/chris-msi/default.nix, which is large
# because that machine has an NVIDIA dGPU, a dock, VR and gaming on top.
{ config, lib, pkgs, inputs, ... }:

{
  imports =
    [ ./hardware-configuration.nix
      ./disko-config.nix
      # shared layers (see each file)
      ../../modules/nixos/common.nix
      ../../modules/nixos/desktop.nix
      ../../modules/nixos/overlays.nix
      # opt-in features, toggled by the my.* flags below
      ../../modules/nixos/impermanence.nix
      ../../modules/nixos/hibernation.nix
      ../../modules/nixos/secure-boot.nix
      ../../modules/nixos/backups.nix
    ];

  # --- local feature toggles (see each module) ---
  my.impermanence.enable = true;   # ephemeral btrfs root + /persist
  # Hibernation is OFF here. The swapfile in disko-config.nix is still sized >= RAM,
  # so turning this on later is the flag plus deriving resumeOffset — no repartition.
  my.hibernation.enable  = false;
  my.secureBoot.enable   = false;  # PHASE 2: flip true AFTER `sbctl create-keys` (see module)
  my.backups.enable      = false;  # flip true AFTER the age key + secrets/secrets.yaml exist

  # LUKS device is created/declared by disko. Here we only add the TPM2 auto-unlock
  # opt; the keyslot is enrolled post-install with systemd-cryptenroll (and
  # re-enrolled once Secure Boot is on — see modules/nixos/secure-boot.nix).
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "tpm2-device=auto" ];

  networking.hostName = "chris-lenovo";

  # zswap: compressed RAM cache in front of the disk swap. Worth more here than on
  # chris-msi — 16G of RAM against that machine's larger complement.
  # NOTE: no mem_sleep_default=deep. The X1C9 ships s2idle-only (Modern Standby)
  # unless "Sleep State" is switched to Linux/S3 in BIOS; forcing deep on an
  # s2idle-only firmware gets you a machine that does not resume.
  boot.kernelParams = [
    "zswap.enabled=1" "zswap.compressor=zstd" "zswap.zpool=zsmalloc" "zswap.max_pool_percent=20"
  ];

  # Intel Iris Xe (Tiger Lake). No PRIME, no nvidia module, no container toolkit —
  # this machine has no discrete GPU. enable32Bit covers Steam/Proton and any
  # 32-bit GL should it ever be wanted.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    # VAAPI for hardware video decode: intel-media-driver is the modern (iHD)
    # driver, correct for Gen9+ / Tiger Lake. vpl-gpu-rt gives oneVPL offload.
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };

  # Intel AX201 Wi-Fi and the Bluetooth radio both need redistributable firmware.
  hardware.enableRedistributableFirmware = true;

  # Intel thermal management (fanless-ish 14" chassis, aggressive PL1/PL2 swings).
  services.thermald.enable = true;

  # Fingerprint reader (Synaptics). GNOME picks fprintd up automatically for login
  # and sudo prompts once a finger is enrolled: Settings -> Users -> Fingerprint.
  services.fprintd.enable = true;

  # Machine-specific packages. The generic tooling (pciutils, dnsutils, sops/age,
  # sbctl, ...) comes from modules/nixos/common.nix.
  environment.systemPackages = with pkgs; [
    powertop          # idle/power tuning on battery
  ];

  # Kept in sync with home.stateVersion in home/common.nix, which is shared by every
  # host — so this is 25.11 rather than the release current at install time. It is a
  # defaults marker, not a version pin, and consistency across hosts matters more.
  system.stateVersion = "25.11";
}
