# macOS (nix-darwin) home-manager config for chris-macbook. The cross-platform
# shell stack, git, and core CLIs come from ./common.nix; this file is the
# Mac-specific layer.
#
# The non-Nix package layer (Homebrew formulae/casks, Mac App Store) is NOT
# managed by nix-darwin's homebrew module — `depend` owns it via packages.yaml,
# so one manifest drives both machines. Homebrew itself is a prerequisite: install
# it once after the OS reinstall (depend shells out to `brew`/`mas`, never builds them).
{ config, lib, pkgs, inputs, ... }:

let
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;
  synology = inputs.synology-filestation.packages.${pkgs.stdenv.hostPlatform.system};

in
{
  imports = [ ./common.nix ];

  home.homeDirectory = "/Users/chris";

  # `depend update` reads this to run the nix-darwin system update on macOS —
  # `nix flake update` + `sudo darwin-rebuild switch --flake <ref>` — mirroring the
  # nixos-rebuild step (DEPEND_NIXOS_FLAKE) on the Linux host.
  home.sessionVariables.DEPEND_DARWIN_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#chris-macbook";

  # Mac-specific Nix packages. Start minimal — GUI apps + the iOS/dev toolchain
  # come from Homebrew via packages.yaml (the `platform: osx` block). Add genuinely
  # cross-platform CLIs to home-common.nix instead, so both machines share them.
  #
  # The exception to "GUI apps come from Homebrew": E4E's Synology FileStation
  # mounter, from the same flake input the NixOS host installs (see
  # hosts/chris-msi/default.nix). It is open-source and already packaged for
  # darwin, and there is no cask to install instead. synologyfuse-gui carries its
  # own SynologyFuse.app (Info.plist, icon, the CLI inside the bundle), which
  # home-manager copies into ~/Applications so it reaches Spotlight, Launchpad and
  # the Dock. macOS needs none of the FUSE wiring the Linux host does — the CLI
  # serves WebDAV on loopback and hands it to
  # Apple's own mount_webdav, so no kernel extension and no programs.fuse. The GUI
  # loads the Rust core through the FFI cdylib; the CLI is listed separately only so
  # it lands on the interactive PATH too (the GUI's own wrapper already has it).
  # Mount points must live under /Volumes.
  home.packages = [
    synology.synologyfuse-gui
    synology.synology-filestation-fuse
  ];

  # Reconcile the non-Nix layer on every `darwin-rebuild switch`. Unlike the Linux
  # host this CONVERGES (--prune): brew/cask/mas packages not in packages.yaml's
  # osx block are removed, so the machine matches the manifest (nix-darwin `zap`
  # equivalent). brew/mas live in /opt/homebrew/bin; pipx (the data-tools provider)
  # comes from Nix. Add both to PATH explicitly in case the activation runs with a
  # minimal environment.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="/opt/homebrew/bin:${lib.makeBinPath [ pkgs.git pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --config ${../packages.yaml}
    '';
}
