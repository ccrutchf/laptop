# Standalone home-manager config for the Linux container (Crostini) on the Lenovo,
# which runs ChromeOS Flex. ChromeOS owns the OS, the desktop, the browser and
# updates; this is only the terminal layer, from the same ./common.nix every other
# host uses. Applied with `home-manager switch --flake .#chris@crostini`
# (see REBUILD-FLEX.md).
#
# Deliberately NOT ./linux.nix: that is the NixOS/GNOME layer (dconf, GTK,
# darkman) plus the `depend` hook, which would try to converge every
# `platform: linux` block of packages.yaml inside the container. GUI apps here
# (Zen) are a manual Flatpak install. Nix-built GUI apps need nixGL on a non-NixOS
# host, and Flatpak brings its own graphics stack.
{ config, lib, pkgs, inputs, ... }:

let
  # UCSD VPN (AnyConnect protocol; the same endpoint the NixOS hosts reach through
  # the NetworkManager openconnect plugin). Two ways in, because it is not yet known
  # whether this container gets a working /dev/net/tun:
  #   ucsd-vpn        kernel tunnel: covers everything in the container. Needs root.
  #                   The store path is spelled out because sudo's secure_path
  #                   does not include the Nix profile.
  #   ucsd-vpn-socks  user-space tunnel via ocproxy: no tun, no root. Exposes a
  #                   SOCKS5 proxy on localhost:1080 for Zen (and Chrome, if
  #                   ChromeOS forwards the port).
  ucsd-vpn = pkgs.writeShellScriptBin "ucsd-vpn" ''
    exec sudo ${pkgs.openconnect}/bin/openconnect --protocol=anyconnect vpn.ucsd.edu "$@"
  '';
  ucsd-vpn-socks = pkgs.writeShellScriptBin "ucsd-vpn-socks" ''
    exec ${pkgs.openconnect}/bin/openconnect --protocol=anyconnect \
      --script-tun --script "${pkgs.ocproxy}/bin/ocproxy -D 1080" \
      vpn.ucsd.edu "$@"
  '';
in
{
  imports = [
    ./common.nix
    # `comma` + command-not-found from the prebuilt index, as on the other hosts
    # (they get it from the system-level nixos/darwin module).
    inputs.nix-index-database.homeModules.nix-index
  ];

  # Crostini's username is chosen at "Turn on Linux" time; pick `chris` there so
  # this matches (home-manager refuses to switch when $HOME differs).
  home.homeDirectory = "/home/chris";

  # Non-NixOS integration: XDG_DATA_DIRS for the launcher, the Nix profile on PATH
  # in login shells, and so on.
  targets.genericLinux.enable = true;
  # ...minus the GPU driver shim, which exists for Nix-built GUI apps (none here;
  # Zen is a Flatpak) and needs a one-time `sudo non-nixos-gpu-setup`.
  targets.genericLinux.gpu.enable = false;

  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  home.packages = [
    pkgs.openconnect
    ucsd-vpn
    ucsd-vpn-socks
  ];
}
