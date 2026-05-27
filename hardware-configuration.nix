# Hardware scan results (machine-generated bits only).
#
# The disk layout — fileSystems, LUKS, swap — is owned by disko-config.nix, NOT
# here. disko generates the `fileSystems.*`, `boot.initrd.luks.devices.*`, and
# `swapDevices` entries from that file, so they MUST NOT be duplicated here (the
# old hand-written ext2/cryptroot entries were removed for the btrfs rebuild).
#
# If you re-run `nixos-generate-config` on the target, take only the kernel
# module / microcode lines below and leave the disk entries to disko.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
