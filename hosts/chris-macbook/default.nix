# nix-darwin host module for chris-macbook (MacBook Air, Apple Silicon).
#
# Scope is deliberately narrow: macOS itself is not declaratively installed (no
# disko equivalent), so this owns system defaults, the user, zsh registration,
# and the home-manager wiring — NOT the OS. The non-Nix package layer (Homebrew
# formulae/casks, Mac App Store) is managed by `depend` from packages.yaml (the
# `platform: osx` block), so there is intentionally NO `homebrew { }` block here.
#
# PREREQUISITES on a fresh machine (see REBUILD-MAC.md):
#   1. Determinate Systems Nix installer (it owns the nix daemon — nix.enable=false).
#   2. Homebrew installed (depend shells out to `brew`/`mas`; it does not build them).
#   3. ~/.ssh/id_ed25519 restored from Nextcloud (git signing; shared sops identity).
{ config, lib, pkgs, inputs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  # Determinate Systems owns the Nix installation and daemon, so nix-darwin must
  # NOT manage it. Determinate enables flakes + nix-command by default, so the
  # nix.settings normally set here are managed in /etc/nix/nix.custom.conf instead.
  nix.enable = false;

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
