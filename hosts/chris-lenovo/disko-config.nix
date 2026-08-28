# Declarative disk layout for chris-lenovo (via disko).
#
# GOTCHA — disko is DESTRUCTIVE and NOT idempotent. `disko --mode disko` WIPES and
# repartitions every device listed below, every run. Unlike chris-msi (dual-boot,
# where only one of two NVMes is ever named), this machine is NixOS-only: the
# single 512GB NVMe is wiped in full and the pre-installed Windows 11 goes with
# it. Run once at install; on later boots use `disko --mode mount`.
#
# GOTCHA — the device MUST be a /dev/disk/by-id/* path, not /dev/nvme0n1, which
# reshuffles across boots once a USB stick is attached.
#
# TODO(install): replace the placeholder below with the real id and re-confirm it
# immediately before running disko:
#   ls -l /dev/disk/by-id/ | grep -v part   # find the 512GB NVMe
#   lsblk -o NAME,SIZE,MODEL,SERIAL         # cross-check size + model
# The placeholder does not exist, so disko fails loudly rather than eating the
# wrong disk if this step is skipped.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/CHANGE-ME-see-REBUILD-LENOVO.md";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00"; # EFI System — firmware enumerates it as bootable
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };

          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot"; # -> /dev/mapper/cryptroot
              settings = {
                allowDiscards = true; # pass TRIM through LUKS to the SSD
                # TPM2 auto-unlock is enrolled POST-INSTALL with systemd-cryptenroll
                # (disko doesn't do TPM); default.nix carries the crypttab
                # `tpm2-device=auto` opt. The X1C9 has a discrete TPM 2.0.
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "nixos" ];
                subvolumes = {
                  # @ = EPHEMERAL root, reset to a fresh empty subvolume every boot by
                  # modules/nixos/impermanence.nix (previous root kept as @old).
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  # NoCoW: overlay2 is small-file churn and images are re-pullable.
                  "@docker" = {
                    mountpoint = "/var/lib/docker";
                    mountOptions = [ "noatime" "nodatacow" ];
                  };

                  # Swap. Hibernation is OFF on this host (my.hibernation.enable =
                  # false), so this is only for memory pressure behind zswap — but
                  # it is sized >= the 16G of RAM deliberately, so hibernation can
                  # be turned on later WITHOUT repartitioning. Enabling it then is
                  # just the flag plus deriving my.hibernation.resumeOffset.
                  "@swap" = {
                    mountpoint = "/swap";
                    swap.swapfile.size = "20G";
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
