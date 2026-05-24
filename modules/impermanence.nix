# Impermanence ("erase your darlings") for a BTRFS root.
#
# Every boot the @ subvolume is deleted and recreated from an empty @blank
# snapshot, so / starts pristine. State survives only if it is (a) reproducible
# from the flake, (b) on a non-rolled-back subvolume (/nix, /persist, /home,
# /var/log, /var/lib/docker), or (c) listed below to be bind-mounted from
# /persist. ROOT-ONLY scope: /home is durable, so user/app state is untouched
# (~/.vscode, ~/.local, ~/.var ride along, dissolving the packages.yaml worry).
#
# GOTCHA — if it isn't reproducible and isn't listed here, IT IS GONE on reboot.
#
# GOTCHA — @blank must be captured EMPTY at INSTALL, after disko creates @ and
# BEFORE nixos-install populates it (see the runbook). This module assumes it
# exists; it does not create it.
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
    # Ensure btrfs-progs is in the initrd for the rollback service.
    boot.initrd.systemd.storePaths = [ "${pkgs.btrfs-progs}/bin/btrfs" ];

    # Roll @ back to a pristine @blank on every boot.
    #
    # GOTCHA — ORDER vs HIBERNATION. This is After= the resume service: on a
    # successful hibernate resume the kernel jumps back into the saved image
    # BEFORE this unit runs, so @ is never wiped from under a resumed session.
    # On a cold boot, resume is a no-op and the wipe proceeds.
    boot.initrd.systemd.services.rollback-root = {
      description = "Roll back btrfs @ to @blank (impermanence: blank / on boot)";
      wantedBy = [ "initrd.target" ];
      after = [
        "systemd-cryptsetup@cryptroot.service"
        "systemd-hibernate-resume.service"
      ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.btrfs-progs pkgs.util-linux ];
      script = ''
        mkdir -p /btrfs_tmp
        mount -t btrfs -o subvolid=5 ${cfg.device} /btrfs_tmp

        # Delete any nested subvolumes under @, then @ itself.
        if [ -e /btrfs_tmp/@ ]; then
          btrfs subvolume list -o /btrfs_tmp/@ | cut -f9 -d' ' | while read sub; do
            btrfs subvolume delete "/btrfs_tmp/$sub"
          done
          btrfs subvolume delete /btrfs_tmp/@
        fi

        btrfs subvolume snapshot /btrfs_tmp/@blank /btrfs_tmp/@
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
