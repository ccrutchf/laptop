# Linux (NixOS) home-manager config, shared by every NixOS host. The cross-platform shell
# stack, git, and core CLIs live in ./common.nix (shared with the Mac); everything
# here is Linux/desktop-specific (GNOME, flatpak, dconf, GTK, darkman) plus the
# Linux `depend` activation.
{ config, lib, pkgs, inputs, osConfig, ... }:

let
  # `depend` for the activation hook below (also added to PATH via home-common.nix).
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # VSCode launched with --no-sandbox. Plain (non-FHS) build: the FHS wrapper runs
  # VSCode inside bubblewrap, which sets no_new_privs and blocks sudo in the
  # integrated terminal. Extensions that fetch native binaries rely on
  # programs.nix-ld (configuration.nix) instead of an FHS layout.
  vscode = pkgs.vscode.override { commandLineArgs = "--no-sandbox"; };

  # Adwaita look for Wine apps in Bottles (e.g. BrickLink Studio): system colors
  # ("R G B") from the libadwaita palette, the msstyles theme off (it would
  # override them), dialog fonts mapped to the GNOME UI font, and the DPI below.
  # Applied to every bottle by the darkman hooks below, so Wine follows light/dark.
  wineColors = {
    light = {
      window = "255 255 255"; bg = "250 250 250"; face = "235 235 235";
      light = "245 245 245"; hilight = "255 255 255"; shadow = "200 200 200";
      dkShadow = "160 160 160"; text = "50 50 50"; gray = "150 150 150";
      dimText = "130 130 130"; link = "28 113 216";
    };
    dark = {
      window = "29 29 32"; bg = "34 34 38"; face = "46 46 50";
      light = "58 58 62"; hilight = "70 70 74"; shadow = "24 24 26";
      dkShadow = "20 20 22"; text = "255 255 255"; gray = "128 128 132";
      dimText = "150 150 154"; link = "120 174 237";
    };
  };
  wineReg = mode: let c = wineColors.${mode}; accent = "53 132 228"; in
    pkgs.writeText "wine-adwaita-${mode}.reg" ''
      REGEDIT4

      [HKEY_CURRENT_USER\Control Panel\Colors]
      "ActiveBorder"="${c.face}"
      "ActiveTitle"="${c.face}"
      "AppWorkSpace"="${c.bg}"
      "Background"="${c.bg}"
      "ButtonAlternateFace"="${c.face}"
      "ButtonDkShadow"="${c.dkShadow}"
      "ButtonFace"="${c.face}"
      "ButtonHilight"="${c.hilight}"
      "ButtonLight"="${c.light}"
      "ButtonShadow"="${c.shadow}"
      "ButtonText"="${c.text}"
      "GradientActiveTitle"="${c.face}"
      "GradientInactiveTitle"="${c.bg}"
      "GrayText"="${c.gray}"
      "Hilight"="${accent}"
      "HilightText"="255 255 255"
      "HotTrackingColor"="${c.link}"
      "InactiveBorder"="${c.bg}"
      "InactiveTitle"="${c.bg}"
      "InactiveTitleText"="${c.dimText}"
      "InfoText"="${c.text}"
      "InfoWindow"="${c.face}"
      "Menu"="${c.window}"
      "MenuBar"="${c.bg}"
      "MenuHilight"="${accent}"
      "MenuText"="${c.text}"
      "Scrollbar"="${c.face}"
      "TitleText"="${c.text}"
      "Window"="${c.window}"
      "WindowFrame"="${c.shadow}"
      "WindowText"="${c.text}"

      [HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ThemeManager]
      "ThemeActive"="0"

      [HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize]
      "AppsUseLightTheme"=dword:0000000${if mode == "light" then "1" else "0"}
      "SystemUsesLightTheme"=dword:0000000${if mode == "light" then "1" else "0"}

      [HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]
      "MS Shell Dlg"="Ubuntu"
      "MS Shell Dlg 2"="Ubuntu"

      [HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
      "Segoe UI"="Ubuntu"

      [HKEY_CURRENT_USER\Control Panel\Desktop]
      "LogPixels"=dword:${wineDpiHex}

      [HKEY_CURRENT_USER\Software\Wine\Fonts]
      "LogPixels"=dword:${wineDpiHex}

      [HKEY_LOCAL_MACHINE\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts]
      "LogPixels"=dword:${wineDpiHex}
    '';
  # Wine DPI for bottles run through XWayland (Bottles' Wayland mode crashes Studio
  # and has no title bars on GNOME). With xwayland-native-scaling, mutter renders X11
  # at the max monitor scale rounded UP (133% → 2×; Xft.dpi = 192), so Wine must
  # match 96 × that. Assumes a >100% display is attached, which the laptop panel is.
  wineDpi = 192;
  wineDpiHex = lib.fixedWidthString 8 "0" (lib.toLower (lib.toHexString wineDpi));
  # The .reg is copied into the Bottles data dir: the sandbox can't see /nix/store.
  # Takes effect on each app's next launch.
  bottlesTheme = mode: ''
    data="$HOME/.var/app/com.usebottles.bottles/data"
    [ -d "$data/bottles/bottles" ] || exit 0
    ${pkgs.coreutils}/bin/install -m644 ${wineReg mode} "$data/wine-adwaita.reg"
    for dir in "$data"/bottles/bottles/*/; do
      name=$(${pkgs.gnused}/bin/sed -n 's/^Name: //p' "$dir/bottle.yml")
      # Keep Bottles' own record in step, so its UI doesn't reapply another DPI.
      ${pkgs.flatpak}/bin/flatpak run --command=bottles-cli com.usebottles.bottles \
        edit -b "$name" --params wayland:false,custom_dpi:${toString wineDpi} || true
      ${pkgs.flatpak}/bin/flatpak run --command=bottles-cli com.usebottles.bottles \
        run -b "$name" -e "$dir/drive_c/windows/regedit.exe" \
        /S "Z:''${data//\//\\}\\wine-adwaita.reg" || true
    done
  '';
in
{
  # Shared cross-platform layer (shell stack, git, core CLIs).
  imports = [ ./common.nix ];

  home.homeDirectory = "/home/chris";

  # Lets `depend` (run from the activation hook and ad-hoc) resolve which flake+attr
  # to operate against without passing --flake every time.
  home.sessionVariables.DEPEND_NIXOS_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#${osConfig.networking.hostName}";
  # This machine's tag in packages.yaml, for ad-hoc `depend plan`/`prune`. The
  # activation hook below passes `--tag` itself: it doesn't see session variables.
  home.sessionVariables.DEPEND_TAGS = "desktop";

  # Linux/desktop packages (the portable CLIs gh/claude-code/uv/depend are in
  # home-common.nix). pipx is Linux-only here (the data-tools block in packages.yaml).
  home.packages = with pkgs; [
    adwaita-icon-theme    # GNOME-default icons + the Adwaita cursor theme below
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

    # System monitor (CPU/GPU/RAM/disk/net). From Nix, NOT Flathub: the Flatpak runs
    # its `magpie` gatherer on the HOST via flatpak-spawn, where the glibc build cannot
    # find libgbm.so.1 and the musl fallback has no loader — it dies with "Failed to
    # connect to Gatherer socket". The Nix build links its gatherer natively. The Intel
    # iGPU tab stays blank (i915 PMU needs kernel.perf_event_paranoid < 2); NVIDIA is fine.
    mission-center

    file-roller        # GNOME archive manager: right-click Compress/Extract in Files
    unzip              # CLI zip extraction (unzip, zipinfo)
    zip                # CLI zip creation
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
    } // (
      # VLC (the org.videolan.VLC flatpak) as default video player, over the common
      # container MIME types. It also registers many audio types, but leave those to
      # a dedicated audio app.
      lib.genAttrs [
        "video/mp4"
        "video/x-matroska"     # .mkv
        "video/quicktime"      # .mov
        "video/webm"
        "video/x-msvideo"      # .avi
        "video/mpeg"
        "video/x-flv"
        "video/3gpp"
        "video/x-ms-wmv"       # .wmv
        "video/ogg"
      ] (_: "org.videolan.VLC.desktop")
    );
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

  # Bottles ships with no home access, so Wine apps (BrickLink Studio) could only
  # save inside the bottle. Grant ~/Documents (Nextcloud-synced); inside Wine it's
  # Z:\home\chris\Documents.
  xdg.dataFile."flatpak/overrides/com.usebottles.bottles".text = ''
    [Context]
    filesystems=xdg-documents;
  '';

  # Unified cursor: sets theme + size everywhere at once (GTK + XCURSOR_* for
  # Wayland and X11/XWayland). Adwaita, not Yaru: nixpkgs dropped yaru-theme (it
  # needed gtk-engine-murrine, removed as unmaintained GTK 2), and the GNOME
  # default cursor ships in adwaita-icon-theme, which is already the icon theme.
  home.pointerCursor = {
    enable = true;  # explicit: HM deprecated inferring this from the block existing
    name = "Adwaita";
    package = pkgs.adwaita-icon-theme;
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
    # Fractional scaling (needed for 125% etc.). xwayland-native-scaling renders X11
    # apps at native resolution instead of upscaling them blurry; they size
    # themselves from DPI (Wine bottles: see wineDpi). Takes effect on next login.
    "org/gnome/mutter" = {
      experimental-features = [ "scale-monitor-framebuffer" "xwayland-native-scaling" ];
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
      # GNOME's global extension kill switch. The Extensions app or a failed
      # session can flip this to true, which silently overrides
      # enabled-extensions and leaves every extension stuck at INITIALIZED.
      # dconf lives on persistent /home, so it survives rebuilds -- pin it.
      disable-user-extensions = false;
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
    lightModeScripts.bottles = bottlesTheme "light";
    darkModeScripts.bottles = bottlesTheme "dark";
  };

  # Reconcile non-Nix packages (flatpaks, vscode extensions, pipx) via
  # dependency-manager on every `home-manager switch`. The systemd unit that runs
  # this has a stripped PATH, so explicitly add the provider binaries depend shells
  # out to. --prune CONVERGES (same as the Mac): flatpak/vscode/pipx packages not in
  # packages.yaml are removed; the safety rail leaves a provider untouched if it
  # declares nothing on this platform. `--tag desktop` selects the NixOS blocks;
  # depend refuses to prune untagged while `tags:` blocks apply to Linux.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.flatpak vscode pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --tag desktop --config ${../packages.yaml}
    '';
}
