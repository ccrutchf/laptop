# restic backups of the git repos -> Nextcloud over rclone WebDAV.
#
# Why: Nextcloud handles everything else but corrupts live `.git` trees (non-atomic
# file-by-file sync). restic stores only opaque, deduplicated, encrypted chunks, so
# Nextcloud never sees a .git directory. Secrets come from sops-nix.
#
# GATED. Keep `my.backups.enable = false` until the age key + secrets/secrets.yaml
# exist (see .sops.yaml and the runbook), or eval will fail on the missing secrets.
# To turn on:
#   1. ensure the Nextcloud-synced SSH key is at ~/.ssh/id_ed25519
#   2. populate secrets/secrets.yaml (restic password + the rclone.conf) — see .sops.yaml
#   3. set my.backups.enable = true; sudo nixos-rebuild switch --flake .#chris-laptop
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.backups;
in {
  options.my.backups.enable =
    mkEnableOption "restic -> Nextcloud backups of ~/Repos";

  config = mkIf cfg.enable {
    # age identity = ssh-to-age of the Nextcloud-synced user key. It must be
    # present at activation (restore it from Nextcloud post-install) or sops can't
    # decrypt and the restic secrets won't appear.
    sops.defaultSopsFile = ../secrets/secrets.yaml;
    sops.age.sshKeyPaths = [ "/home/chris/.ssh/id_ed25519" ];

    sops.secrets."restic/password" = { };       # encrypts the restic repo
    sops.secrets."restic/rclone-conf" = { };     # full rclone.conf incl. the Nextcloud app password

    services.restic.backups.repos = {
      paths = [ "/home/chris/Repos" ];
      repository = "rclone:nextcloud:Backups/chris-laptop-repos";
      passwordFile = config.sops.secrets."restic/password".path;
      rcloneConfigFile = config.sops.secrets."restic/rclone-conf".path;

      # Don't ship regenerable build junk to Nextcloud.
      exclude = [
        "**/target"
        "**/node_modules"
        "**/.direnv"
        "**/result"
        "**/boot/*.img"   # junkyard-boot-img (and any other image-build) artifacts
      ];

      initialize = true;   # restic init on first run
      timerConfig = { OnCalendar = "daily"; Persistent = true; };
      pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
    };
  };
}
