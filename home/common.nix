# Cross-platform home-manager config shared by every host (NixOS + nix-darwin).
#
# Anything here must evaluate on BOTH Linux and macOS — so no GNOME/Hyprland,
# flatpak, dconf, GTK, or X/Wayland bits (those live in the per-host files:
# home/linux.nix for Linux, home/darwin.nix for the Mac). This is the portable
# "shell experience + core CLIs + git" layer.
#
# home.homeDirectory is deliberately NOT set here (it differs: /home/chris vs
# /Users/chris) — each host file sets it.
{ config, lib, pkgs, inputs, ... }:

let
  # `depend` (the dependency-manager binary) is cross-platform now — the flake
  # exposes aarch64-darwin alongside the Linux systems — so it belongs on PATH on
  # every host. Each host's activation hook re-derives this same path to run it.
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  home.username = "chris";

  # Must match system.stateVersion (configuration.nix) / the darwin host on first
  # install. Same value works for home-manager on Linux and macOS.
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  # Let home-manager own bash so home.sessionVariables / shellAliases take effect
  # (HM's bashrc sources the system rc first, so the OS shell setup is preserved).
  # zsh is the interactive login shell; bash stays the scripting fallback.
  programs.bash.enable = true;

  # ── Interactive shell experience (the "Warp feel" without Warp) ──────────────
  # zsh stays POSIX (pasted bash snippets just work) while the two plugins add the
  # fish-style niceties: inline autosuggestions and syntax highlighting.
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    autocd = true;
    history = {
      size = 100000;
      save = 100000;
      ignoreDups = true;
      ignoreSpace = true;
      share = true;
    };
  };

  # atuin: full-screen fuzzy history on Ctrl-R. --disable-up-arrow keeps Up bound
  # to zsh's own line-history so muscle memory is intact; atuin owns Ctrl-R only.
  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    flags = [ "--disable-up-arrow" ];
    settings = {
      style = "compact";
      inline_height = 25;
      show_preview = true;
    };
  };

  # Prompt polish, smart cd, and fuzzy finding.
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
  };
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    options = [ "--cmd cd" ];   # `cd` becomes zoxide (jump to frecent dirs)
  };
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # Cross-platform CLIs (per the rebuild decision: these come from Nix on both
  # machines for one source of truth). Host-specific GUI/desktop packages live in
  # the per-host files. `depend` is the dependency-manager binary.
  home.packages = with pkgs; [
    gh
    claude-code
    uv
    depend
  ];

  programs.git = {
    enable = true;
    lfs.enable = true;   # large files: datasets / model checkpoints (HF, LFS repos)
    settings = {
      user = {
        name = "Christopher L. Crutchfield";
        email = "ccrutchf@ucsd.edu";
        # SSH commit signing with the Nextcloud-synced key — the same identity on
        # every personal machine. Absolute path (git does NOT expand ~); resolves
        # to /home/chris or /Users/chris via the per-host homeDirectory.
        signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
  };

  programs.vim.enable = true;

  # Per-project dev shells: auto-load each repo's flake / devShell on cd.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
