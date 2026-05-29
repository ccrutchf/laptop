{ config, lib, pkgs, inputs, ... }:

let
  # `depend` comes from the flake input now — builtins.getFlake of an arbitrary
  # URL is illegal in a flake's pure eval, so it must be a declared input
  # (flake.nix: inputs.dependency-manager).
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # VSCode launched with --no-sandbox. Plain (non-FHS) build: the FHS wrapper
  # runs VSCode inside bubblewrap, which sets no_new_privs and blocks sudo in
  # the integrated terminal. Extensions that fetch native binaries (e.g.
  # ms-dotnettools.csdevkit) rely on programs.nix-ld (configuration.nix) instead
  # of an FHS layout.
  vscode = pkgs.vscode.override { commandLineArgs = "--no-sandbox"; };
in
{
  home.username = "chris";
  home.homeDirectory = "/home/chris";

  # Should match system.stateVersion in configuration.nix on first install.
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  # Lets `depend` (run from the home-manager activation hook and ad-hoc) resolve
  # which flake+attr to operate against without passing --flake every time.
  home.sessionVariables.DEPEND_NIXOS_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#chris-laptop";

  home.packages = with pkgs; [
    yaru-theme
    gnomeExtensions.dash-to-dock
    gnomeExtensions.appindicator
    gnomeExtensions.user-themes
    gnomeExtensions.desktop-icons-ng-ding
    vscode
    (warp-terminal.override { waylandSupport = true; })  # else winit can't dlopen libwayland → falls back to laggy XWayland
    depend
    gh
    claude-code
    uv
    pipx
    android-studio
    keepass
    jetbrains-toolbox  # JetBrains IDE manager; IDEs it installs run via nix-ld
  ];

  programs.git = {
    enable = true;
    lfs.enable = true;   # large files: datasets / model checkpoints (HF, LFS repos)
    settings = {
      user = {
        name = "Christopher L. Crutchfield";
        email = "ccrutchf@ucsd.edu";
        # SSH commit signing with the Nextcloud-synced key. Absolute path — git does
        # NOT expand `~` in signingkey, so a literal `~/...` fails to find the key.
        signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
  };

  programs.vim.enable = true;

  # Per-project dev shells: auto-load each repo's flake / devShell on cd (you have
  # project flakes, e.g. junkyard-boot-img). nix-direnv caches the shell and keeps
  # a GC root — pairs with nix.settings.keep-outputs/keep-derivations.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Default browser = Zen (the Flatpak). Writes ~/.config/mimeapps.list, which GNOME
  # reads for default-app associations. (home-manager owns the file as a symlink, so
  # changing defaults via GNOME Settings later won't stick — edit it here instead.)
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/http" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/https" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/about" = "app.zen_browser.zen.desktop";
      "x-scheme-handler/unknown" = "app.zen_browser.zen.desktop";
    };
  };

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
      # GNOME shows only the close button by default; add minimize + maximize.
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
      export PATH="${lib.makeBinPath [ pkgs.flatpak vscode pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --config ${./packages.yaml}
    '';

}
