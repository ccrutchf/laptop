{ config, lib, pkgs, ... }:

let
  # Pull `depend` from upstream's flake. Tracks master (no lockfile here since
  # the surrounding config isn't a flake) — mirrors the home-manager fetchTarball
  # pattern in configuration.nix.
  depend = (builtins.getFlake "github:ccrutchf/dependency-manager")
    .packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  home.username = "chris";
  home.homeDirectory = "/home/chris";

  # Should match system.stateVersion in configuration.nix on first install.
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    yaru-theme
    gnomeExtensions.dash-to-dock
    gnomeExtensions.appindicator
    gnomeExtensions.user-themes
    gnomeExtensions.desktop-icons-ng-ding
    vscode-fhs
    (pkgs.callPackage ./warp-terminal.nix { })
    depend
    gh
    claude-code
    uv
    pipx
    android-studio
    keepass
  ];

  programs.git = {
    enable = true;
    settings.user = {
      name = "Christopher L. Crutchfield";
      email = "ccrutchf@ucsd.edu";
    };
  };

  programs.vim.enable = true;

  gtk = {
    enable = true;
    gtk4.theme = config.gtk.theme;
    theme = {
      name = "Yaru-dark";
      package = pkgs.yaru-theme;
    };
    iconTheme = {
      name = "Yaru";
      package = pkgs.yaru-theme;
    };
    cursorTheme = {
      name = "Yaru";
      package = pkgs.yaru-theme;
    };
  };

  dconf.settings = {
    # Fractional scaling (needed for 125% etc.). Takes effect on next login.
    "org/gnome/mutter" = {
      experimental-features = [ "scale-monitor-framebuffer" ];
    };

    # Don't auto-suspend while plugged into AC ("When Plugged In" off in
    # Settings → Power → Automatic Suspend). Battery behavior is unchanged.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-type = "nothing";
    };

    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      font-name = "Ubuntu 11";
      document-font-name = "Sans 11";
      monospace-font-name = "Ubuntu Mono 13";
      cursor-theme = "Yaru";
      icon-theme = "Yaru";
      gtk-theme = "Yaru-dark";
      clock-format = "12h";
    };

    "org/gnome/desktop/wm/preferences" = {
      titlebar-font = "Ubuntu Bold 11";
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
      name = "Yaru-dark";
    };

    "org/gnome/shell/extensions/dash-to-dock" = {
      dock-position = "LEFT";
      extend-height = true;
      dash-max-icon-size = 48;
      show-trash = true;
      show-mounts = true;
      click-action = "minimize-or-overview";
      transparency-mode = "FIXED";
    };
  };

  # Reconcile non-Nix packages (flatpaks, vscode extensions, etc.) via
  # dependency-manager on every `home-manager switch`. The systemd unit that
  # runs this has a stripped PATH, so explicitly add the provider binaries
  # depend shells out to.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.flatpak pkgs.vscode-fhs pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --config ${./packages.yaml}
    '';

}
