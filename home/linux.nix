# Linux (NixOS) home-manager config for chris-laptop. The cross-platform shell
# stack, git, and core CLIs live in ./common.nix (shared with the Mac); everything
# here is Linux/desktop-specific (GNOME, Hyprland, flatpak, dconf, GTK, darkman)
# plus the Linux `depend` activation.
{ config, lib, pkgs, inputs, ... }:

let
  # `depend` for the activation hook below (also added to PATH via home-common.nix).
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # VSCode launched with --no-sandbox. Plain (non-FHS) build: the FHS wrapper runs
  # VSCode inside bubblewrap, which sets no_new_privs and blocks sudo in the
  # integrated terminal. Extensions that fetch native binaries rely on
  # programs.nix-ld (configuration.nix) instead of an FHS layout.
  vscode = pkgs.vscode.override { commandLineArgs = "--no-sandbox"; };
in
{
  # Shared cross-platform layer + the Hyprland session config (keybinds, bar,
  # launcher, autostarted helpers — see home-hyprland.nix).
  imports = [ ./common.nix ./hyprland.nix ];

  home.homeDirectory = "/home/chris";

  # Lets `depend` (run from the activation hook and ad-hoc) resolve which flake+attr
  # to operate against without passing --flake every time.
  home.sessionVariables.DEPEND_NIXOS_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#chris-laptop";

  # Linux/desktop packages (the portable CLIs gh/claude-code/uv/depend are in
  # home-common.nix). pipx is Linux-only here (the data-tools block in packages.yaml).
  home.packages = with pkgs; [
    yaru-theme            # still used for the cursor theme below
    adwaita-icon-theme    # GNOME-default icons (reverted from Yaru)
    gnome-themes-extra    # ships the Adwaita-dark GTK3 variant darkman switches to
    gnomeExtensions.dash-to-dock
    gnomeExtensions.appindicator
    gnomeExtensions.user-themes
    gnomeExtensions.desktop-icons-ng-ding
    vscode
    (warp-terminal.override { waylandSupport = true; })  # else winit can't dlopen libwayland → laggy XWayland
    pipx
    android-studio
    keepass
    jetbrains-toolbox  # JetBrains IDE manager; IDEs it installs run via nix-ld
    papers             # GNOME Document Viewer (ex-Evince) — PDF reader
  ];

  # Default browser = Zen (the Flatpak). Writes ~/.config/mimeapps.list, which GNOME
  # reads for default-app associations.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/http" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/https" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/about" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/unknown" = "app.zen_browser.zen.desktop";
      "application/pdf" = "org.gnome.Papers.desktop";
    };
  };

  # synologyfuse-gui (configuration.nix systemPackages) ships no .desktop file, so
  # GNOME's app grid wouldn't list it. Add one; `SynologyFuse.Gui` is on the system
  # PATH (/run/current-system/sw/bin), and folder-remote is an Adwaita icon name.
  xdg.desktopEntries.synologyfuse-gui = {
    name = "Synology FileStation";
    genericName = "NAS File Mounter";
    comment = "Mount Synology NAS FileStation shares over FUSE";
    exec = "SynologyFuse.Gui";
    icon = "folder-remote";
    terminal = false;
    categories = [ "Utility" "Network" "FileTools" ];
  };

  # Flatpak (1.16.x) can't parse NixOS's /etc/localtime symlink chain and NixOS
  # ships no /etc/timezone fallback, so every sandbox defaults to UTC and Electron
  # apps render timestamps in UTC. Inject the zone into all *user* flatpaks via a
  # global override. Keep in sync with time.timeZone (configuration.nix).
  xdg.dataFile."flatpak/overrides/global".text = ''
    [Environment]
    TZ=America/Los_Angeles
  '';

  # Unified cursor: sets theme + size everywhere at once (GTK, XCURSOR_* for
  # Wayland and X11/XWayland, and hyprcursor).
  home.pointerCursor = {
    name = "Yaru";
    package = pkgs.yaru-theme;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  gtk = {
    enable = true;
    # No static `theme` here: darkman owns gtk-theme + color-scheme at runtime
    # (Adwaita ⇄ Adwaita-dark). Letting the gtk module pin gtk-theme would fight
    # darkman's gsettings writes on every switch.
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  dconf.settings = {
    # Fractional scaling (needed for 125% etc.). Takes effect on next login.
    "org/gnome/mutter" = {
      experimental-features = [ "scale-monitor-framebuffer" ];
    };

    # Don't auto-suspend while plugged into AC.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-type = "nothing";
    };

    "org/gnome/desktop/interface" = {
      # color-scheme + gtk-theme owned by darkman; icon/cursor by the gtk module.
      font-name = "Ubuntu 11";
      document-font-name = "Sans 11";
      monospace-font-name = "Ubuntu Mono 13";
      clock-format = "12h";
    };

    "org/gnome/desktop/wm/preferences" = {
      titlebar-font = "Ubuntu Bold 11";
      button-layout = "appmenu:minimize,maximize,close";
    };

    "org/gnome/shell" = {
      enabled-extensions = [
        "dash-to-dock@micxgx.gmail.com"
        "appindicatorsupport@rgcjonas.gmail.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "ding@rastersoft.com"
      ];
    };

    "org/gnome/shell/extensions/user-theme" = {
      name = "";   # default GNOME Shell theme
    };

    "org/gnome/shell/extensions/dash-to-dock" = {
      dock-position = "LEFT";
      extend-height = true;
      dash-max-icon-size = 48;
      show-trash = true;
      show-mounts = true;
      dock-fixed = true;
      autohide = false;
      intellihide = false;
      # Clicking an app spreads THAT app's windows macOS Exposé–style.
      click-action = "focus-or-appspread";
      transparency-mode = "FIXED";
    };
  };

  # Automatic light/dark at sunrise/sunset. darkman gets location from geoclue
  # (services.geoclue2 in configuration.nix) and owns color-scheme + gtk-theme.
  services.darkman = {
    enable = true;
    settings.usegeoclue = true;
    lightModeScripts.gnome = ''
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'
    '';
    darkModeScripts.gnome = ''
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
    '';
  };

  # Reconcile non-Nix packages (flatpaks, vscode extensions, pipx) via
  # dependency-manager on every `home-manager switch`. The systemd unit that runs
  # this has a stripped PATH, so explicitly add the provider binaries depend shells
  # out to. --prune CONVERGES (same as the Mac): flatpak/vscode/pipx packages not in
  # packages.yaml are removed; the safety rail leaves a provider untouched if it
  # declares nothing on this platform.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.flatpak vscode pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --config ${../packages.yaml}
    '';
}
