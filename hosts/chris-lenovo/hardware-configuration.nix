# Hardware scan results (machine-generated bits only) — Lenovo ThinkPad X1 Carbon
# Gen 9 (i7-1185G7, Tiger Lake UP3).
#
# The disk layout — fileSystems, LUKS, swap — is owned by disko-config.nix, NOT
# here. disko generates the `fileSystems.*`, `boot.initrd.luks.devices.*`, and
# `swapDevices` entries from that file, so they MUST NOT be duplicated here.
#
# TODO(install): re-run `nixos-generate-config --no-filesystems --root /mnt` on the
# machine and reconcile the module lists below with what it reports. The values
# here are the standard X1C9 set (NVMe root, Thunderbolt 4, Intel VT-x) and should
# be correct, but the scan is authoritative — take only the kernel module /
# microcode lines from it and leave every disk entry to disko.
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
