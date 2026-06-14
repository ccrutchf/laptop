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
in
{
  imports = [ ./common.nix ];

  home.homeDirectory = "/Users/chris";

  # Forward-looking: `depend update`'s macOS path will gain a `darwin-rebuild switch`
  # step (mirroring the nixos-rebuild step) keyed off this var. Not consumed yet —
  # set now so it's ready when that depend feature lands.
  home.sessionVariables.DEPEND_DARWIN_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#chris-macbook";

  # Mac-specific Nix packages. Start minimal — GUI apps + the iOS/dev toolchain
  # come from Homebrew via packages.yaml (the `platform: osx` block). Add genuinely
  # cross-platform CLIs to home-common.nix instead, so both machines share them.
  home.packages = with pkgs; [
  ];

  # Reconcile the non-Nix layer on every `darwin-rebuild switch`. Unlike the Linux
  # host this CONVERGES (--prune): brew/cask/mas packages not in packages.yaml's
  # osx block are removed, so the machine matches the manifest (nix-darwin `zap`
  # equivalent). brew/mas live in /opt/homebrew/bin; add it to PATH explicitly in
  # case the activation runs with a minimal environment.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="/opt/homebrew/bin:${lib.makeBinPath [ pkgs.git ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --config ${../packages.yaml}
    '';
}
