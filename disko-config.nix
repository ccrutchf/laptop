# Declarative disk layout for chris-laptop (via disko).
#
# GOTCHA — disko is DESTRUCTIVE and NOT idempotent. `disko --mode disko` (or
# nixos-anywhere) WIPES and repartitions every device listed below, every run.
# Only the 2TB Samsung 990 is listed here. Windows lives on the SEPARATE 1TB
# Samsung 980 (by-id nvme-eui.002538d121415869, BitLocker) and is NEVER
# referenced — that is what makes this safe to run on a dual-boot machine. Run
# once at install; on later boots use `disko --mode mount` (import + mount only).
#
# GOTCHA — the device is a /dev/disk/by-id/* path on purpose. /dev/nvme0n1
# reshuffles across boots (two NVMes + USB mass-storage enumerate in any order).
# PRE-FLIGHT before `disko --mode disko`, re-confirm this id is still the 2TB drive:
#   ls -l /dev/disk/by-id/ | grep -i 990_EVO     # must point at the Samsung 990, NOT the 980
{
  disko.devices = {
    disk.main = {
      type = "disk";
      # Samsung SSD 990 EVO Plus 2TB — the Linux disk. (NOT the *_1 partition alias.)
      device = "/dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NJ0Y432453X";
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
                # NOTE: TPM2 auto-unlock is enrolled POST-INSTALL with
                # `systemd-cryptenroll` (disko doesn't do TPM). configuration.nix
                # carries the crypttab `tpm2-device=auto` opt. Re-enroll AFTER
                # Secure Boot is on so the keyslot binds to the measured PCRs.
              };
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "nixos" ];
                subvolumes = {
                  # @ = EPHEMERAL root. Reset to a fresh empty subvolume every boot
                  # by modules/impermanence.nix (previous root kept as @old). Anything
                  # here not in /persist or reproducible from the flake is GONE on reboot.
                  "@" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };

                  # /nix — durable, never rolled back (store is reproducible).
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };

                  # /persist — durable OS state, bind-mounted back into the live
                  # root by modules/impermanence.nix.
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };

                  # /home — durable. Root-only impermanence: your work + GNOME/app
                  # state (~/.vscode, ~/.local, ~/.var) survive the rollback.
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };

                  # /var/log — durable, so journald history survives the rollback.
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };

                  # /var/lib/docker — own subvolume, NoCoW (nodatacow): overlay2 is
                  # small-file churn and images are re-pullable, so no CoW/snapshots
                  # wanted. Durable as a real mount (NOT a /persist bind), so it
                  # survives the rollback on its own.
                  "@docker" = {
                    mountpoint = "/var/lib/docker";
                    mountOptions = [ "noatime" "nodatacow" ];
                  };

                  # /swap — NoCoW swapfile for HIBERNATION (>= RAM, 62.5G -> 64G).
                  # disko creates the file NoCoW + populates swapDevices. The
                  # hibernation resume_offset is computed POST-INSTALL — see
                  # modules/hibernation.nix.
                  "@swap" = {
                    mountpoint = "/swap";
                    swap.swapfile.size = "64G";
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
