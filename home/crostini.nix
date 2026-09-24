# Standalone home-manager config for the Linux container (Crostini) on the Lenovo,
# which runs ChromeOS Flex. ChromeOS owns the OS, the desktop, the browser and
# updates; this is only the terminal layer, from the same ./common.nix every other
# host uses. Applied with `home-manager switch --flake .#chris@crostini`
# (see REBUILD-FLEX.md).
#
# Deliberately NOT ./linux.nix: that is the NixOS/GNOME layer (dconf, GTK,
# darkman). GUI apps here (Zen, Nextcloud) are Flatpaks from packages.yaml, selected
# by `--tag crostini` in the depend hook below. Nix-built GUI apps need nixGL on a
# non-NixOS host, and Flatpak brings its own graphics stack.
{ config, lib, pkgs, inputs, ... }:

let
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;

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

  # This machine's tag in packages.yaml, for ad-hoc `depend plan`/`prune`.
  home.sessionVariables.DEPEND_TAGS = "crostini";

  # Reconcile packages.yaml on every switch, as the other hosts do: `apt: flatpak`
  # first, then the shared Flathub apps; everything else is tagged `desktop`. Here the
  # providers are Debian's, not Nix's, so the stripped activation PATH gets /usr/bin
  # (flatpak, sudo; depend finds apt-get by absolute path). Crostini's default user
  # has passwordless sudo, so the apt step doesn't prompt. --prune only touches
  # flatpak here: apt is never pruned.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="$PATH:/usr/bin:/usr/sbin:/bin"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --tag crostini --config ${../packages.yaml}
    '';
}
