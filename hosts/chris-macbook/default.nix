# nix-darwin host module for chris-macbook (MacBook Air, Apple Silicon).
#
# Scope is deliberately narrow: macOS itself is not declaratively installed (no
# disko equivalent), so this owns system defaults, the user, zsh registration,
# and the home-manager wiring — NOT the OS. The non-Nix package layer (Homebrew
# formulae/casks, Mac App Store) is managed by `depend` from packages.yaml (the
# `platform: osx` block), so there is intentionally NO `homebrew { }` block here.
#
# PREREQUISITES on a fresh machine (see REBUILD-MAC.md):
#   1. The official upstream multi-user Nix installer (org.nixos.nix-daemon). Unlike
#      Determinate, it does NOT manage flakes/daemon config for us, so nix-darwin
#      owns the Nix installation here (nix.enable = true, below).
#   2. Homebrew installed (depend shells out to `brew`/`mas`; it does not build them).
#   3. ~/.ssh/id_ed25519 restored from Nextcloud (git signing; shared sops identity).
{ config, lib, pkgs, inputs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  # Nix was installed with the official upstream multi-user installer (not
  # Determinate), so nix-darwin manages the Nix installation and daemon. Because
  # the upstream installer's /etc/nix/nix.conf does NOT enable flakes, we must turn
  # on the experimental features here or flake commands break after the switch.
  #
  # NOTE (first switch only): nix-darwin refuses to clobber a pre-existing,
  # unmanaged /etc/nix/nix.conf. Move it aside once before the first switch:
  #   sudo mv /etc/nix/nix.conf /etc/nix/nix.conf.before-nix-darwin
  nix.enable = true;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Dedupe identical store paths via hardlinks (mirrors the laptop).
    auto-optimise-store = true;
  };

  # Weekly garbage collection, keep the last 30 days — mirrors the laptop's nix.gc.
  # nix-darwin schedules this as a launchd job, so `interval` is a calendar spec
  # (StartCalendarInterval) rather than NixOS's `dates` string. Weekday 0 = Sunday.
  nix.gc = {
    automatic = true;
    interval = { Weekday = 0; Hour = 3; Minute = 15; };
    options = "--delete-older-than 30d";
  };

  # `comma`: run any nixpkgs binary on demand (`, <tool>`) + command-not-found
  # suggestions, using the prebuilt nix-index database (the nix-index-database flake
  # input, wired in as a darwinModule in flake.nix). Mirrors the laptop.
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  # nix-darwin state version. Integer (unlike NixOS's "25.11"); bump only when the
  # release notes say to. Safe to set on a fresh install — it only gates the
  # preservation of older default behaviors. `darwin-rebuild` warns if it's wrong.
  system.stateVersion = 6;

  # Required by recent nix-darwin: which user owns user-scoped activation
  # (home-manager, user defaults). Matches the macOS account created at setup.
  system.primaryUser = "chris";

  users.users.chris = {
    name = "chris";
    home = "/Users/chris";
  };

  # Pin the machine name so it never drifts back to a "...-2" collision. All three
  # are set: scutil HostName, the Sharing "Computer Name", and the local mDNS name.
  networking.hostName = "chris-macbook";
  networking.computerName = "chris-macbook";
  networking.localHostName = "chris-macbook";

  # Register zsh as a login shell (the per-user zsh config is in home-common.nix),
  # mirroring programs.zsh.enable on the NixOS host.
  programs.zsh.enable = true;

  # macOS system defaults are personal preference — left mostly unset on purpose.
  # Uncomment/extend as you decide what you want pinned declaratively, e.g.:
  # system.defaults = {
  #   NSGlobalDomain.InitialKeyRepeat = 15;
  #   NSGlobalDomain.KeyRepeat = 2;
  #   NSGlobalDomain.AppleShowAllExtensions = true;
  #   dock.autohide = true;
  #   finder.AppleShowAllFiles = true;
  # };
}
