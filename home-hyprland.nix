# Hyprland — USER half (home-manager). Imported by home.nix; the SYSTEM half
# (programs.hyprland, GDM session entry, portals, fonts) is modules/hyprland.nix.
#
# COEXISTENCE WITH GNOME: this config is shared by the `chris` user across every
# session. So the helper daemons (bar/notifications/idle/wallpaper) are NOT run
# as global systemd user services — they'd also start under GNOME and fight its
# own daemons. Instead they're launched from Hyprland's `exec-once`, which scopes
# them to the Hyprland session. The HM modules below are used only to GENERATE
# config / install binaries (waybar has systemd.enable = false for this reason).
#
# Basic, first-time-tiling setup: kitty (terminal), wofi (launcher), Waybar
# (bar), mako (notifications), hyprpaper (wallpaper), hyprlock + hypridle
# (lock + idle). Swap the wallpaper by editing hyprpaper.conf below.
{ config, lib, pkgs, ... }:

let
  # nixos-artwork wallpapers expose a direct file path via .gnomeFilePath —
  # handy since hyprpaper wants an exact file, not a store dir. Swap this for any
  # image path (e.g. one in ~/Pictures) to change the wallpaper.
  wallpaper = pkgs.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath;

  # Battery readout for Waybar. We can't use Waybar's built-in `battery` module:
  # in 0.55.2 it scans all of /sys/class/power_supply and crashes ("Could not
  # watch events…") on the transient Logitech HID++ peripheral batteries
  # (hidpp_battery_*) that appear when the dock's wireless receiver connects —
  # taking the whole bar down. This polls the laptop battery (BAT1) directly, so
  # there's nothing for the HID batteries to break. (BAT1 is this machine's
  # battery node; ADP1 is the AC adapter.)
  batteryScript = pkgs.writeShellScript "waybar-battery" ''
    cap=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)
    [ -z "$cap" ] && exit 0
    status=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null)
    if [ "$status" = "Charging" ]; then icon=""
    elif [ "$cap" -ge 80 ]; then icon=""
    elif [ "$cap" -ge 60 ]; then icon=""
    elif [ "$cap" -ge 40 ]; then icon=""
    elif [ "$cap" -ge 20 ]; then icon=""
    else icon=""; fi
    printf '%s%% %s\n' "$cap" "$icon"
  '';

  # Lid-close handler. logind's own "docked" detection is unreliable under
  # Hyprland (it suspended on lid-close despite the dock), so logind is set to
  # IGNORE the lid (modules/hibernation.nix) and we decide here by reading the
  # DRM connectors directly: docked (any external display) -> clamshell (just
  # turn the internal panel off, stay awake); undocked -> suspend. Suspending
  # while docked wedges the Thunderbolt controller, so "docked = never sleep".
  lidClose = pkgs.writeShellScript "hypr-lid-close" ''
    for f in /sys/class/drm/card*-*/status; do
      case "$f" in *eDP*) continue ;; esac
      if [ "$(cat "$f" 2>/dev/null)" = connected ]; then
        hyprctl keyword monitor eDP-1,disable    # docked -> clamshell, stay awake
        exit 0
      fi
    done
    systemctl suspend-then-hibernate             # undocked -> portable, sleep
  '';

  # Idle-timeout handler: suspend ONLY when truly portable — undocked AND on
  # battery (matches the old GNOME power config; never sleeps while docked).
  idleSuspend = pkgs.writeShellScript "hypr-idle-suspend" ''
    for f in /sys/class/drm/card*-*/status; do
      case "$f" in *eDP*) continue ;; esac
      [ "$(cat "$f" 2>/dev/null)" = connected ] && exit 0   # docked -> never sleep
    done
    [ "$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)" = 1 ] && exit 0   # on AC -> don't sleep
    systemctl suspend-then-hibernate
  '';

  # Monitor setup: reassert clamshell + fix the 4K modeset race. Runs at startup
  # (exec-once) and on the $mod+SHIFT+M keybind for manual re-detection. NOT run
  # automatically on `hyprctl reload` — doing a disable→re-enable during a
  # reload's own re-modeset deadlocks the display. Targets the 4K by DESCRIPTION
  # since its connector name isn't stable.
  monitorSetup = pkgs.writeShellScript "hypr-monitor-setup" ''
    # Clamshell first (immediate): turn the internal panel off if the lid is shut.
    grep -qil closed /proc/acpi/button/lid/*/state && hyprctl keyword monitor eDP-1,disable
    # The Samsung 4K's initial modeset can hang ("page-flip awaiting") and leave
    # it black; a clean disable→re-enable after the modeset settles fixes it.
    # Guarded so it's a no-op when the 4K isn't connected (undocked).
    sleep 3
    if hyprctl monitors 2>/dev/null | grep -q LU28R55; then
      hyprctl keyword monitor "desc:Samsung Electric Company LU28R55 HCJW902122,disable"
      hyprctl keyword monitor "desc:Samsung Electric Company LU28R55 HCJW902122,preferred,0x0,1.25"
    fi
    # Toggling a monitor leaves Waybar's bar on it dead (Waybar doesn't re-place
    # itself), so restart Waybar to redraw bars on the current outputs.
    pkill waybar 2>/dev/null; sleep 0.3; hyprctl dispatch exec waybar >/dev/null 2>&1
  '';
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    # Pin the legacy hyprlang generator: the `settings` below are written in
    # hyprland.conf (hyprlang) form, not Lua. home-manager flips this default to
    # "lua" at stateVersion 26.05; pinning keeps this config valid across that
    # bump and silences the deprecation warning.
    configType = "hyprlang";
    # Defer the package + portal to the NixOS programs.hyprland module
    # (modules/hyprland.nix) so the system and HM Hyprland versions can't diverge.
    package = null;
    portalPackage = null;

    settings = {
      "$mod" = "SUPER";

      # Per-monitor layout + HiDPI scaling, keyed by monitor DESCRIPTION, NOT the
      # connector (DP-1/DP-2). The DP-x name each external lands on is NOT stable
      # across boots — they swapped, which applied the 4K's scale to the 1080p and
      # the 1080p's to the 4K. desc: binds each setting to the physical panel.
      # Format: desc:<description>, RESOLUTION, POSITION (logical px), SCALE.
      #   Samsung 28" 4K  @1.25x -> logical 3072x1728, at the origin (left)
      #   Dell 23" 1080p  @1x    -> placed right of it (x = 3072)
      #   eDP-1 internal 15" 4K @1.5x -> undocked use (eDP-1 name IS stable)
      monitor = [
        "desc:Samsung Electric Company LU28R55 HCJW902122, preferred, 0x0, 1.25"
        "desc:Dell Inc. DELL E2318HR 5JDGK74BAJFL, preferred, 3072x0, 1"
        "eDP-1, preferred, auto, 1.5"
        ", preferred, auto, 1"
      ];

      # Workspace pinning (by monitor description, like the layout above):
      #   ws 1 -> 4K, ws 2 -> 1080p (each is that monitor's default workspace).
      #   ws 3-10 are unbound and float to whatever monitor they're opened on.
      # On undock the bound workspaces collapse onto the remaining display
      # (laptop) and snap back to their monitors automatically on re-dock.
      workspace = [
        "1, monitor:desc:Samsung Electric Company LU28R55 HCJW902122, default:true"
        "2, monitor:desc:Dell Inc. DELL E2318HR 5JDGK74BAJFL, default:true"
      ];

      # Session helpers — scoped to Hyprland (see header note). polkit agent first
      # so privilege prompts (e.g. the Synology FUSE GUI) have an authenticator.
      exec-once = [
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
        # Bring up the gnome-keyring Secret Service (org.freedesktop.secrets).
        # PAM (pam_gnome_keyring, auto_start) starts the daemon in --login mode
        # and unlocks the login keyring with the tuigreet password, but under a
        # bare WM nothing starts the secrets component the way gnome-session did.
        # This connects to the already-unlocked daemon via its control socket and
        # registers the Secret Service so Electron/libsecret apps (Slack, VSCode)
        # can persist their auth tokens. Without it the login keyring stays
        # inaccessible and Slack logs out on every launch.
        "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets"
        "waybar"
        "mako"
        "hyprpaper"
        "hypridle"
        # Startup monitor setup (clamshell + 4K modeset fix). Also on $mod+SHIFT+M.
        "${monitorSetup}"
      ];

      input = {
        kb_layout = "us";
        follow_mouse = 1;
        touchpad = {
          natural_scroll = false;
          tap-to-click = true;
        };
      };

      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        layout = "dwindle";
      };

      decoration = {
        rounding = 6;
        shadow.enabled = true;
      };

      # Render the cursor in software. The external monitors are driven by the
      # NVIDIA GPU, whose hardware cursor plane leaves a stuck "ghost" cursor
      # under Hyprland. Software cursors cost a hair of GPU but kill the ghost.
      cursor.no_hardware_cursors = true;

      # Chat apps live on a SPECIAL (scratchpad) workspace, NOT the tiled
      # workspaces — toggle them in/out as an overlay with $mod+S (bind below).
      # `silent` stops focus from jumping to the scratchpad when one launches in
      # the background at login.
      # SYNTAX (Hyprland 0.55.2, the "v3" rule grammar): each comma-separated
      # field is `<key> <value>` (split on the FIRST space). MATCH PROPS take a
      # `match:` prefix — so it's `match:class ^(…)$`, NOT the old v2
      # `class:^(…)$` (which now errors "field class missing a value") and NOT
      # `windowrulev2` (hard-deprecated → config error). Effects like `workspace`
      # are bare; the trailing ` silent` is part of the workspace value.
      # NOTE: the `^(…)$` match each window's `class`. These Flatpaks set their
      # class to the FLATPAK APP ID (verified via `hyprctl clients`: Slack ->
      # com.slack.Slack, Signal -> org.signal.Signal), not a short name — so match
      # on the app id. Discord/Teams accept either the app id or the short name
      # (alternation) since their Electron class wasn't verified here. If one still
      # tiles, run `hyprctl clients` while it's open and copy its exact `class`.
      # Zoom is intentionally left out (video calls usually want a real tile).
      windowrule = [
        "workspace special:chat silent, match:class ^(com.slack.Slack)$"
        "workspace special:chat silent, match:class ^(com.discordapp.Discord|discord)$"
        "workspace special:chat silent, match:class ^(org.signal.Signal)$"
        "workspace special:chat silent, match:class ^(com.github.IsmaelMartinez.teams_for_linux|teams-for-linux)$"

        # Picture-in-Picture video pop-outs. Match on TITLE: the PiP child
        # shares the browser's class (verified Zen -> app.zen_browser.zen, same
        # as the main window), so only the title tells them apart. The (-| )
        # alternation also covers Chromium's "Picture in Picture" (spaces).
        # GRAMMAR (Hyprland 0.55.2): boolean effects take an explicit `on` value
        # and use the underscore token names from the rule enum — bare `float` or
        # camelCase `keepaspectratio`/`noinitialfocus` error as "invalid field".
        # `size`/`move` carry their own coords, so they need no `on`.
        #   float on .............. pin only works while floating (no-op if tiled)
        #   pin on ................ render on EVERY workspace so the video follows
        #   keep_aspect_ratio on .. corner-resize won't letterbox the video
        #   no_initial_focus on ... don't steal the keyboard when it spawns
        #   size/move ............. fixed 480x270, parked bottom-right of focus mon
        "float on, match:title ^(Picture(-| )in(-| )Picture)$"
        "pin on, match:title ^(Picture(-| )in(-| )Picture)$"
        "keep_aspect_ratio on, match:title ^(Picture(-| )in(-| )Picture)$"
        "no_initial_focus on, match:title ^(Picture(-| )in(-| )Picture)$"
        "size 480 270, match:title ^(Picture(-| )in(-| )Picture)$"
        "move 100%-500 100%-290, match:title ^(Picture(-| )in(-| )Picture)$"
      ];

      # --- Keybinds (see the cheat-sheet comment at the end of this file) ---
      bind = [
        "$mod, Return, exec, kitty"
        "ALT, space, exec, wofi --show drun"
        "$mod, D, exec, wofi --show drun"
        "$mod, W, killactive,"
        "$mod, M, exit,"
        "$mod, V, togglefloating,"
        "$mod, F, fullscreen,"
        "$mod, L, exec, hyprlock"
        "$mod SHIFT, M, exec, ${monitorSetup}"
        "$mod, P, pseudo,"
        "$mod, J, layoutmsg, togglesplit"
        "$mod, S, togglespecialworkspace, chat"

        # Move focus
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"

        # Move the focused window within the layout
        "$mod SHIFT, left, movewindow, l"
        "$mod SHIFT, right, movewindow, r"
        "$mod SHIFT, up, movewindow, u"
        "$mod SHIFT, down, movewindow, d"

        # Move the whole focused workspace to the monitor in that direction
        "$mod CTRL, left, movecurrentworkspacetomonitor, l"
        "$mod CTRL, right, movecurrentworkspacetomonitor, r"
        "$mod CTRL, up, movecurrentworkspacetomonitor, u"
        "$mod CTRL, down, movecurrentworkspacetomonitor, d"

        # Region screenshot -> clipboard
        '', Print, exec, grim -g "$(slurp)" - | wl-copy''
      ]
      # Workspaces: $mod+1..9,0 switch; $mod+SHIFT+1..9,0 send window there.
      ++ (builtins.concatLists (builtins.genList (i:
        let
          ws = toString (i + 1);
          key = toString (if i == 9 then 0 else i + 1);
        in [
          "$mod, ${key}, workspace, ${ws}"
          "$mod SHIFT, ${key}, movetoworkspace, ${ws}"
        ]) 10));

      # Drag to move/resize: $mod + left/right mouse button.
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

      # Repeatable while held: volume + brightness.
      binde = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
      ];

      # Works even on the lock screen (bindl) — mute + lid handling.
      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        # Clamshell: turn the internal panel off when the lid closes so it
        # drops out of the monitor layout, and bring it back on open. Hyprland
        # otherwise keeps eDP-1 active with the lid shut. (Fires on lid-switch
        # *events*; if you boot already-closed, toggle the lid once.)
        ", switch:on:Lid Switch, exec, ${lidClose}"
        ", switch:off:Lid Switch, exec, hyprctl keyword monitor eDP-1,preferred,auto,1.5"
      ];
    };
  };

  # Terminal launched by $mod+Return (config-only; no daemon).
  programs.kitty.enable = true;

  # Status bar. systemd.enable = false on purpose — started from exec-once so it
  # only runs under Hyprland, not GNOME.
  programs.waybar = {
    enable = true;
    systemd.enable = false;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 30;
      modules-left = [ "hyprland/workspaces" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "network" "custom/battery" "tray" ];

      "hyprland/workspaces".format = "{id}";
      clock.format = "{:%a %d %b  %H:%M}";
      "custom/battery" = {
        exec = "${batteryScript}";
        interval = 30;
        tooltip = false;
      };
      network = {
        format-wifi = " {signalStrength}%";
        format-ethernet = "󰈀 wired";
        format-disconnected = "⚠ offline";
      };
      pulseaudio = {
        format = "{volume}% {icon}";
        format-muted = " muted";
        format-icons.default = [ "" "" "" ];
      };
      tray.spacing = 10;
    };
    style = ''
      * { font-family: "JetBrainsMono Nerd Font", "Font Awesome 6 Free"; font-size: 13px; }
      window#waybar { background: rgba(30,30,46,0.85); color: #cdd6f4; }
      #workspaces button { padding: 0 8px; color: #cdd6f4; }
      #workspaces button.active { background: #585b70; }
      #clock, #custom-battery, #network, #pulseaudio, #tray { padding: 0 10px; }
      /* Font Awesome battery glyphs are wide and clip on the right edge; the
         module is custom-named (#custom-battery, not #battery) and sits last,
         so give it extra right padding. */
      #custom-battery { padding-right: 14px; }
    '';
  };

  # Lock screen (invoked by $mod+L and by hypridle on idle / before sleep).
  programs.hyprlock = {
    enable = true;
    settings = {
      background = [{
        path = wallpaper;
        blur_passes = 2;
      }];
      input-field = [{
        size = "250, 50";
        position = "0, -80";
        halign = "center";
        valign = "center";
      }];
    };
  };

  # Wallpaper config (started via exec-once, not the HM service module).
  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
    splash = false
  '';

  # Idle behavior: lock at 5 min, screen off at 6 min, and suspend-then-hibernate
  # at 20 min ON BATTERY ONLY — matching the old GNOME power config (auto-suspend
  # on battery idle, "nothing" on AC). Lid/power-key suspend stays owned by the
  # logind matrix in modules/hibernation.nix; this just adds the idle path.
  xdg.configFile."hypr/hypridle.conf".text = ''
    general {
        lock_cmd = pidof hyprlock || hyprlock
        before_sleep_cmd = loginctl lock-session
        after_sleep_cmd = hyprctl dispatch dpms on
    }
    listener {
        timeout = 300
        on-timeout = loginctl lock-session
    }
    listener {
        timeout = 360
        on-timeout = hyprctl dispatch dpms off
        on-resume = hyprctl dispatch dpms on
    }
    # Idle suspend, but only when undocked AND on battery (see idleSuspend; never
    # sleeps while docked, nothing on AC). Script avoids any config-parse quoting
    # ambiguity in the on-timeout command.
    listener {
        timeout = 1200
        on-timeout = ${idleSuspend}
    }
  '';

  # Minimal notification daemon config (started via exec-once).
  xdg.configFile."mako/config".text = ''
    default-timeout=5000
    background-color=#1e1e2e
    text-color=#cdd6f4
    border-color=#585b70
    border-radius=6
  '';

  # Hyprland-session tooling. (kitty/waybar/hyprlock come from their HM modules
  # above; wpctl ships with the system PipeWire/WirePlumber.)
  home.packages = with pkgs; [
    wofi            # app launcher ($mod+D / $mod+R)
    mako            # notifications (exec-once)
    hyprpaper       # wallpaper (exec-once)
    hypridle        # idle -> lock/dpms (exec-once)
    grim slurp      # screenshots (Print)
    wl-clipboard    # wl-copy / wl-paste
    brightnessctl   # backlight keys
  ];

  # ──────────────────────────────────────────────────────────────────────────
  # KEYBIND CHEAT-SHEET ($mod = Super/Windows key)
  # Apps & session
  #   $mod+Return ............ terminal (kitty)
  #   Alt+Space (or $mod+D) .. app launcher (wofi, Spotlight-style)
  #   $mod+W ................. close focused window
  #   $mod+L ................. lock screen (hyprlock)
  #   $mod+M ................. EXIT Hyprland (back to the tuigreet login)
  # Window control
  #   $mod+V ................. toggle floating
  #   $mod+F ................. fullscreen
  #   $mod+P ................. pseudo-tile
  #   $mod+J ................. toggle split direction (dwindle)
  #   $mod+arrows ............ move focus
  #   $mod+Shift+arrows ...... move window within the layout
  #   $mod+drag (L/R mouse) .. move / resize window
  # Workspaces & monitors
  #   $mod+1..0 .............. switch to workspace 1..10
  #   $mod+Shift+1..0 ........ send window to workspace 1..10
  #   $mod+Ctrl+arrows ....... move current workspace to the monitor that way
  #   $mod+S ................. toggle chat scratchpad (Slack/Discord/Signal/Teams)
  #   $mod+Shift+M ........... re-run monitor setup (4K modeset fix + clamshell)
  # Media / capture
  #   Print .................. region screenshot -> clipboard
  #   Volume / Brightness .... wpctl / brightnessctl (hardware keys)
  # ──────────────────────────────────────────────────────────────────────────
}
