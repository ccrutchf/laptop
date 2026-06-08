# Hyprland — a basic tiling-WM session, added ALONGSIDE GNOME (not replacing it).
#
# This module is the SYSTEM half: it enables programs.hyprland (which installs
# the package, the wayland-session .desktop so GDM lists "Hyprland" in the gear
# menu, xdg-desktop-portal-hyprland, polkit integration, and NIXOS_OZONE_WL).
# The USER half — keybinds, bar, launcher, autostarted helpers — lives in
# home-hyprland.nix (home-manager), launched via Hyprland `exec-once` so those
# daemons are scoped to the Hyprland session and never run under GNOME.
#
# GATED on `my.hyprland.enable` (configuration.nix). Flip it off to drop the
# whole session; GNOME is unaffected either way.
#
# HARDWARE: the Intel iGPU drives the display (PRIME offload, configuration.nix),
# so Hyprland renders on Intel — the simple Wayland path, no NVIDIA tuning needed
# up front. If cursor/flicker artifacts ever appear, fix at the Hyprland config
# level (cursor:no_hardware_cursors) rather than here.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.hyprland;
in {
  options.my.hyprland.enable =
    mkEnableOption "Hyprland Wayland session (selectable at GDM, alongside GNOME)";

  config = mkIf cfg.enable {
    programs.hyprland.enable = true;

    # GTK portal for file pickers / settings dialogs in GTK apps run under
    # Hyprland (xdg-desktop-portal-hyprland handles screenshare/screenshot).
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

    # Secret Service for the Hyprland session. GNOME used to provide this via
    # gnome-keyring; without it, Electron/libsecret apps (Slack, VSCode) can't
    # persist their auth tokens and silently fall back to a store they then
    # can't decrypt → logged out every launch. enableGnomeKeyring unlocks the
    # login keyring at the tuigreet login using the entered password (so the
    # keyring password must match the user's login password). The daemon's
    # `secrets` component registers org.freedesktop.secrets on the session bus,
    # which is what Slack looks for.
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.greetd.enableGnomeKeyring = true;

    # Glyph fonts for Waybar (the ubuntu fonts in configuration.nix have no
    # icon glyphs). fonts.packages merges with the existing list.
    fonts.packages = with pkgs; [ font-awesome nerd-fonts.jetbrains-mono ];
  };
}
