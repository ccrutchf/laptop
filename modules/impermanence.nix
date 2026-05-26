# Impermanence ("erase your darlings") for a BTRFS root.
#
# Every boot the @ subvolume is moved aside (kept as @old, recoverable for one
# boot) and recreated EMPTY, so / starts pristine. State survives only if it is (a) reproducible
# from the flake, (b) on a non-rolled-back subvolume (/nix, /persist, /home,
# /var/log, /var/lib/docker), or (c) listed below to be bind-mounted from
# /persist. ROOT-ONLY scope: /home is durable, so user/app state is untouched
# (~/.vscode, ~/.local, ~/.var ride along, dissolving the packages.yaml worry).
#
# GOTCHA — if it isn't reproducible and isn't listed here, IT IS GONE on reboot.
#
# NOTE — the root is recreated EMPTY with `btrfs subvolume create` each boot, so it
# does NOT depend on an install-time @blank snapshot. (The original
# snapshot-from-@blank approach failed: systemd's nested subvolumes under @ —
# var/lib/{machines,portables}, /srv, /tmp, /var/tmp — blocked `btrfs subvolume
# delete @`. @blank is now vestigial and can be removed.)
{ config, lib, pkgs, inputs, ... }:
with lib;
let
  cfg = config.my.impermanence;
in {
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  options.my.impermanence = {
    enable = mkEnableOption "btrfs root rollback to @blank + /persist state";
    device = mkOption {
      type = types.str;
      default = "/dev/mapper/cryptroot";
      description = "The unlocked btrfs device holding @ and @blank.";
    };
  };

  config = mkIf cfg.enable {
    boot.initrd.systemd.enable = true;
    # Put the rollback service's binaries IN the initrd image. The service `path`
    # only sets PATH — without these actually present, `mount` was "command not
    # found" (systemd-initrd mounts via syscalls, so it ships no mount(8)). This was
    # the real cause of every failed rollback: the script died at `mount` on line 1.
    boot.initrd.systemd.storePaths = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils ];

    # Reset @ to an empty subvolume on every boot (impermanence).
    #
    # GOTCHA — ORDER vs HIBERNATION. This is After= the resume service: on a
    # successful hibernate resume the kernel jumps back into the saved image
    # BEFORE this unit runs, so @ is never wiped from under a resumed session.
    # On a cold boot, resume is a no-op and the wipe proceeds.
    boot.initrd.systemd.services.rollback-root = {
      description = "Reset btrfs @ to empty (impermanence: blank / on boot)";
      wantedBy = [ "initrd.target" ];
      # Order after the LUKS device is open and after a hibernate-resume attempt,
      # before the root mounts. The .device unit is already in the boot transaction
      # (sysroot.mount needs it), so ordering after it makes us wait for it.
      after = [
        "dev-mapper-cryptroot.device"
        "systemd-cryptsetup@cryptroot.service"
        "systemd-hibernate-resume.service"
      ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.btrfs-progs pkgs.util-linux pkgs.coreutils ];
      script = ''
        # Debugging in initrd (its journal isn't forwarded on this host): prepend
        # `exec > /dev/kmsg 2>&1`, add `echo` markers, then read them back via `dmesg`.
        mkdir -p /btrfs_tmp
        mount -t btrfs -o subvolid=5 ${cfg.device} /btrfs_tmp

        # systemd creates var/lib/{machines,portables}, /srv, /tmp, /var/tmp as
        # subvolumes INSIDE @, so deleting @ needs those gone first. Recurse,
        # tolerant of either path format `btrfs subvolume list -o` may emit.
        delete_subvolume_recursively() {
          local target="$1" child IFS
          IFS=$'\n'
          for child in $(btrfs subvolume list -o "$target" | cut -f9- -d' '); do
            if btrfs subvolume show "/btrfs_tmp/$child" >/dev/null 2>&1; then
              delete_subvolume_recursively "/btrfs_tmp/$child"
            elif btrfs subvolume show "$target/$child" >/dev/null 2>&1; then
              delete_subvolume_recursively "$target/$child"
            fi
          done
          btrfs subvolume delete "$target"
        }

        # Keep the PREVIOUS root as @old (recoverable for one boot), then boot empty.
        if btrfs subvolume show /btrfs_tmp/@old >/dev/null 2>&1; then
          delete_subvolume_recursively /btrfs_tmp/@old
        fi
        if btrfs subvolume show /btrfs_tmp/@ >/dev/null 2>&1; then
          mv /btrfs_tmp/@ /btrfs_tmp/@old
        fi
        btrfs subvolume create /btrfs_tmp/@

        umount /btrfs_tmp
      '';
    };

    # GOTCHA — systemd >=258 PID1 FREEZES if /usr is empty ("Refusing to run in
    # unsupported environment where /usr/ is not populated"). On NixOS the only
    # thing in /usr is /usr/bin/env, created by tmpfiles AFTER PID1 — so a freshly
    # rolled-back-to-empty-@blank root hangs at switch-root. Reseed it here (after
    # sysroot is mounted, before switch-root); stage-2 tmpfiles then replaces it
    # with the canonical link. (Same fix krg-infra needed on waiter, 2026-05.)
    boot.initrd.systemd.services.populate-usr-bin-env = {
      description = "Seed /usr/bin/env in the rolled-back root (systemd 258 /usr check)";
      wantedBy = [ "initrd.target" ];
      after = [ "sysroot.mount" ];
      before = [ "initrd-switch-root.target" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils ];
      script = ''
        mkdir -p /sysroot/usr/bin
        ln -sfn ${pkgs.coreutils}/bin/env /sysroot/usr/bin/env
      '';
    };

    # /persist must mount in stage-1 before the binds that pull state from it.
    fileSystems."/persist".neededForBoot = true;

    environment.persistence."/persist" = {
      enable = true;
      hideMounts = true;

      directories = [
        "/var/lib/nixos"       # uid/gid allocation map — non-negotiable.
        "/var/lib/systemd"     # random-seed, timer stamps, coredumps, clock.
        "/var/lib/bluetooth"   # paired-device keys.
        "/var/lib/fwupd"       # firmware update state.
        "/var/lib/sbctl"       # Secure Boot keys (lanzaboote pkiBundle).
        "/var/lib/flatpak"     # system-wide flatpak installs (if depend uses them).
        "/etc/NetworkManager/system-connections"  # saved Wi-Fi + the UCSD VPN.
        # NOTE: /var/lib/docker and /var/log are their OWN durable subvolumes,
        # NOT persist binds — intentionally absent.
      ];

      files = [
        "/etc/machine-id"      # stable host identity (journald continuity).
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
      ];
    };
  };
}
