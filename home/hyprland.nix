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
# Basic, first-time-tiling setup: ghostty (terminal), walker (launcher), Waybar
# (bar), swaync (notifications + quick-settings), hyprpaper (wallpaper), hyprlock + hypridle
# (lock + idle). Swap the wallpaper by editing hyprpaper.conf below.
{ config, lib, pkgs, ... }:

let
  # nixos-artwork wallpapers expose a direct file path via .gnomeFilePath —
  # handy since this wants an exact file, not a store dir. Used only for the
  # hyprlock lock-screen background now; the DESKTOP wallpaper is the swww
  # slideshow below.
  wallpaper = pkgs.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath;

  # Desktop wallpaper slideshow (GNOME-style). hyprpaper is static and can't
  # cycle, so we use swww — a daemon with crossfade transitions — and rotate it
  # from this loop. Drop .jpg/.jpeg/.png files into wallpaperDir; one is picked
  # at random every slideshowInterval seconds. Scoped to Hyprland via exec-once
  # (see header note); the script starts the daemon itself and waits for it, so
  # there's no startup ordering race with a separate exec-once entry.
  #
  # NOTE ON NAMES: upstream renamed this project swww -> awww ("An Answer to your
  # Wayland Wallpaper Woes"); in nixpkgs `pkgs.swww` is now a deprecation alias
  # for `pkgs.awww`, and the binaries are `awww`/`awww-daemon` (no `swww` on
  # PATH). We use the canonical `pkgs.awww` attr to avoid the rename warning.
  wallpaperDir = "${config.home.homeDirectory}/Pictures/wallpapers_4k/ffmpeg_target";
  slideshowInterval = 1800;   # 30 min
  wallpaperSlideshow = pkgs.writeShellScript "hypr-wallpaper-slideshow" ''
    dir="${wallpaperDir}"
    # Start the daemon if not already up, then block until it answers IPC.
    ${pkgs.awww}/bin/awww query >/dev/null 2>&1 || ${pkgs.awww}/bin/awww-daemon &
    until ${pkgs.awww}/bin/awww query >/dev/null 2>&1; do sleep 0.2; done
    while true; do
      img=$(${pkgs.findutils}/bin/find "$dir" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
        | ${pkgs.coreutils}/bin/shuf -n1)
      [ -n "$img" ] && ${pkgs.awww}/bin/awww img \
        --transition-type fade --transition-duration 2 "$img"
      sleep ${toString slideshowInterval}
    done
  '';

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

  # Pre-lock "idle dim" warning (mirrors the old GNOME fade): ~30s before the
  # lock fires, fade the screen down to 30% as a heads-up. Uses a SOFTWARE gamma
  # dim (wl-gammarelay-rs, started from exec-once) rather than the sysfs backlight
  # so it covers EVERY output. brightnessctl only drives the laptop's eDP sysfs
  # backlight; external monitors over DP have no sysfs backlight, so the old fade
  # was a silent no-op on them when docked — and clamshell-docked (eDP disabled)
  # gave no warning at all. Gamma applies to all wl_outputs uniformly. The current
  # Brightness is saved to a runtime file so on-resume restores whatever it was.
  idleDim = pkgs.writeShellScript "hypr-idle-dim" ''
    saved="$XDG_RUNTIME_DIR/hypr-idle-dim.brightness"
    get() { busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Brightness 2>/dev/null | awk '{print $2}'; }
    setb() { busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Brightness d "$1"; }
    cur=$(get); [ -z "$cur" ] && cur=1.0       # default if the daemon's not up yet
    printf '%s\n' "$cur" > "$saved"            # remember it for on-resume
    pct=$(awk -v c="$cur" 'BEGIN { printf "%d", c * 100 }')
    target=30
    [ "$pct" -le "$target" ] && exit 0
    while [ "$pct" -gt "$target" ]; do         # fade over ~0.8s
      pct=$(( pct - 5 ))
      [ "$pct" -lt "$target" ] && pct=$target
      setb "$(awk -v p="$pct" 'BEGIN { printf "%.2f", p / 100 }')"
      sleep 0.05
    done
  '';

  # on-resume companion: snap the saved brightness back the instant there's any
  # activity (or it's restored after unlock if the dim proceeded to a full lock).
  idleUndim = pkgs.writeShellScript "hypr-idle-undim" ''
    saved="$XDG_RUNTIME_DIR/hypr-idle-dim.brightness"
    b=$(cat "$saved" 2>/dev/null); [ -z "$b" ] && b=1.0
    busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Brightness d "$b"
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
    # ASUS-desk eDP scale. The 15" 4K internal panel at the default 1.5x is too
    # small at this desk, so bump eDP-1 to 2.0x (logical 1920x1080) whenever the
    # ASUS VS238 is present — direct or via its dock, the monitor enumerates the
    # same either way. Reset to 1.5x when it's absent so re-running this on
    # undock ($mod+SHIFT+M) restores the default. Skipped while clamshell-docked
    # (lid shut -> eDP disabled above): only re-scale a panel that's in use, and
    # don't fight the Samsung clamshell case. eDP's logical width shrinks
    # 2560->1920 at 2.0x, so re-place the ASUS to its right (it sits right of the
    # laptop, as the catch-all rule placed it at 1.5x).
    if ! grep -qil closed /proc/acpi/button/lid/*/state; then
      if hyprctl monitors 2>/dev/null | grep -q 'ASUS VS238'; then
        hyprctl keyword monitor "eDP-1,preferred,0x0,2.0"
        hyprctl keyword monitor "desc:Ancor Communications Inc ASUS VS238 G6LMTF140248,preferred,1920x0,1"
      else
        hyprctl keyword monitor "eDP-1,preferred,auto,1.5"
      fi
    fi
    # Default audio sink follows the desk. Match sinks by the EDID monitor name
    # PipeWire stamps into node.nick ("Samsung LU28R55", "ASUS VS238") or by the
    # stable node.name for the laptop Speaker — NOT the HDMI1/2/3 index, which can
    # swap across boots like the DP-x video connectors. Rule: at the Samsung 4K
    # desk route to the monitor's audio; everywhere else (ASUS desk, undocked) use
    # the laptop speakers. wpctl is on the session PATH (the volume keybinds use it
    # too). If the Samsung match ever misses, run `wpctl inspect <sink>` at that
    # desk and widen the LU28R55 pattern below.
    sink_for() {
      # Retry for ~5s: the Samsung disable->re-enable above tears down and
      # recreates the DP link, so its HDMI audio sink vanishes from PipeWire and
      # re-registers a beat later. Without the wait, sink_for runs in that gap,
      # finds nothing, and the caller leaves the default on the laptop Speaker
      # (the bug). The laptop Speaker never disappears, so its lookup returns on
      # the first pass — only a genuinely-absent sink actually spins here.
      for _ in $(seq 1 10); do
        for id in $(wpctl status | sed -n '/Sinks:/,/Sources:/p' | sed -nE 's/^[^0-9]*([0-9]+)[.].*/\1/p'); do
          if wpctl inspect "$id" 2>/dev/null | grep -qiE "node[.](name|nick) = \".*($1).*\""; then
            printf '%s\n' "$id"; return 0
          fi
        done
        sleep 0.5
      done
    }
    if hyprctl monitors 2>/dev/null | grep -q LU28R55; then
      sink=$(sink_for 'LU28R55')          # Samsung 4K desk -> the monitor's audio
    else
      sink=$(sink_for 'Speaker')          # ASUS desk + undocked -> laptop speakers
    fi
    [ -n "$sink" ] && wpctl set-default "$sink"
    # Toggling a monitor leaves Waybar's bar on it dead (Waybar doesn't re-place
    # itself), so restart Waybar to redraw bars on the current outputs.
    pkill waybar 2>/dev/null; sleep 0.3; hyprctl dispatch exec waybar >/dev/null 2>&1
  '';

  # Quick audio-output picker — the GNOME "pick an output device" submenu, as a
  # tofi list. Lists sinks by the human description wpctl prints, sets the chosen
  # one as default; WirePlumber migrates active streams to the new default on its
  # own (no per-stream move needed). Bound to $mod+O and the swaync "Output"
  # button. Pairs with the desk-following default in monitorSetup above — this is
  # the MANUAL override for when you want headphones/speakers mid-session.
  audioSwitcher = pkgs.writeShellScript "hypr-audio-switcher" ''
    sinks=$(wpctl status | sed -n '/Sinks:/,/Sources:/p' \
      | sed -nE 's/^[^0-9]*([0-9]+)\. +(.+) \[vol.*/\1\t\2/p')
    [ -z "$sinks" ] && exit 0
    choice=$(printf '%s\n' "$sinks" | cut -f2- | ${pkgs.tofi}/bin/tofi --prompt-text "Output: ")
    [ -z "$choice" ] && exit 0
    id=$(printf '%s\n' "$sinks" | ${pkgs.gawk}/bin/awk -F'\t' -v c="$choice" '$2==c{print $1; exit}')
    [ -n "$id" ] && wpctl set-default "$id"
  '';

  # Secret Service handoff to the PAM-unlocked keyring. pam_gnome_keyring (the
  # greetd PAM stack) starts a gnome-keyring-daemon at login and UNLOCKS the
  # login keyring (journal: "gnome-keyring-daemon started properly and unlocked
  # keyring"), leaving it on the control socket at $XDG_RUNTIME_DIR/keyring. But
  # greetd does NOT propagate that daemon's GNOME_KEYRING_CONTROL into the D-Bus
  # activation / systemd-user environment. So when anything requests
  # org.freedesktop.secrets (gh, Slack, VSCode), D-Bus auto-activates a SEPARATE
  # gnome-keyring-daemon (org.freedesktop.secrets.service) that, without
  # GNOME_KEYRING_CONTROL, can't attach to the unlocked instance and opens the
  # login keyring LOCKED -> gcr password prompt. (gnome-session used to avoid
  # this by running dbus-update-activation-environment; bare Hyprland doesn't.)
  #
  # Fix: pin GNOME_KEYRING_CONTROL to the known socket dir, push it into the
  # D-Bus + systemd-user activation env (so any later activation attaches to the
  # unlocked daemon), then register the secrets component IN that unlocked daemon
  # right away. `--start` with the control socket present attaches rather than
  # spawning a fresh (locked) daemon. Runs at session start while the PAM daemon
  # is still fresh, before any secrets consumer can trigger a competing activation.
  keyringInit = pkgs.writeShellScript "hypr-keyring-init" ''
    export GNOME_KEYRING_CONTROL="$XDG_RUNTIME_DIR/keyring"
    ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd GNOME_KEYRING_CONTROL
    ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1
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
      # eDP-1's 1.5x here is the DEFAULT; at the ASUS VS238 desk monitorSetup
      # overrides it to 2.0x (the 4K panel is too small at 1.5x there). The ASUS
      # itself isn't pinned below — it lands on the catch-all and monitorSetup
      # owns its geometry, so workspaces float onto it (no default-workspace bind).
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

      # --- XWayland HiDPI: kill the fractional-scaling blur ---
      # XWayland apps with no native Wayland backend (e.g. the Synology FUSE GUI,
      # an Avalonia/.NET app — Avalonia's Wayland backend is private-preview only
      # as of v12) render at the monitor's LOGICAL size and let the compositor
      # bitmap-upscale to native pixels → blurry text/UI on any fractionally
      # scaled output (the 4K @1.25 and eDP @1.5; the 1080p @1.0 is 1:1 so it
      # always looked sharp). force_zero_scaling makes XWayland render at NATIVE
      # pixel density instead, and each toolkit applies its own scale from env.
      # TRADEOFF: this is session-wide — other XWayland apps that DON'T self-scale
      # (Java/Swing IDEs like Android Studio / JetBrains) may now render small on
      # the HiDPI panels and need their own scale hint (e.g. _JAVA_OPTIONS with
      # -Dsun.java2d.uiScale). Most GTK/Qt/Electron apps run native Wayland here
      # and are unaffected.
      xwayland.force_zero_scaling = true;

      # Per-output scale for Avalonia/.NET apps under XWayland, keyed by XRANDR
      # OUTPUT NAME (Avalonia can't read Hyprland's desc:). Without this, with
      # force_zero_scaling on, the GUI would render native-tiny on the HiDPI
      # panels. eDP-1's name is stable; the two DP-x externals CAN swap across
      # boots (see the monitor list) — if the 4K ever comes up tiny, swap the two
      # DP-x factors. Only Avalonia reads this var; other toolkits ignore it.
      env = [
        "AVALONIA_SCREEN_SCALE_FACTORS,eDP-1=1.5;DP-1=1.25;DP-2=1"
      ];

      # Session helpers — scoped to Hyprland (see header note). polkit agent first
      # so privilege prompts (e.g. the Synology FUSE GUI) have an authenticator.
      exec-once = [
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
        # Hand the Secret Service off to the PAM-unlocked keyring daemon and push
        # GNOME_KEYRING_CONTROL into the D-Bus/systemd activation env (see the
        # keyringInit definition above). Without this, gh/Slack/VSCode trigger a
        # fresh, LOCKED keyring daemon and get a gcr password prompt every time.
        "${keyringInit}"
        "waybar"
        # Notifications AND the quick-settings panel (volume/brightness sliders,
        # media, DND, toggle grid). Replaces mako — one daemon does both. Toggle
        # the panel with $mod+N or the Waybar bell. Config: xdg.configFile below.
        "swaync"
        # Tray status menus (GNOME-style): Bluetooth + network. The Waybar
        # network module shows inline signal %; nm-applet adds the click-to-pick
        # Wi-Fi menu the bar module can't. blueman-applet is the only BT indicator.
        "blueman-applet"
        "nm-applet --indicator"
        "${wallpaperSlideshow}"
        # Software gamma/brightness daemon (DBus rs.wl-gammarelay). Drives the
        # pre-lock idle dim across ALL outputs, including external monitors that
        # have no sysfs backlight. Must be up before hypridle's first dim fires.
        "${pkgs.wl-gammarelay-rs}/bin/wl-gammarelay-rs"
        "hypridle"
        # Startup monitor setup (clamshell + 4K modeset fix). Also on $mod+SHIFT+M.
        "${monitorSetup}"
        # Launcher: walker (2.x) is only the GTK frontend — it talks to elephant,
        # a separate backend daemon that supplies every provider (apps, calc,
        # files, clipboard, websearch…). Both must run for ALT+Space / $mod+D to
        # work; elephant first so it's listening before walker connects. Bare
        # `walker` only signals the already-running service, so the keybinds need
        # walker --gapplication-service up.
        "${pkgs.elephant}/bin/elephant"
        "${pkgs.walker}/bin/walker --gapplication-service"
        # Auto-launch the scratchpad apps at login. The windowrules below park
        # them on their special workspaces with `silent`, so focus doesn't jump
        # to a scratchpad as they come up in the background. Discord -> chat,
        # Spotify -> media. (flatpak is on the session PATH here — exec-once runs
        # with the login env, not the stripped home.activation PATH.)
        "flatpak run com.discordapp.Discord"
        "flatpak run com.spotify.Client"
        # Nextcloud sync client — uploads the hourly ~/.claude snapshot (and the
        # rest of the synced tree) offsite. --background starts it straight to the
        # waybar tray instead of popping the main window at every login.
        "flatpak run com.nextcloud.desktopclient.nextcloud --background"
      ];

      input = {
        kb_layout = "us";
        numlock_by_default = true;
        # 2 (not the default 1): hovering a window does NOT move keyboard focus,
        # but the hovered window still receives mouse events (scroll/click). With
        # 1, focus follows the cursor, so moving the mouse over another window
        # mid-gesture (e.g. while reaching for Ctrl+C after selecting text)
        # hijacks the keystroke into the hovered window and the copy targets the
        # wrong window. 2 keeps keyboard focus put while preserving scroll-on-hover.
        follow_mouse = 2;
        touchpad = {
          natural_scroll = true;   # content tracks finger direction (macOS-style)
          tap-to-click = true;
        };
      };

      # Three-finger horizontal swipe moves between workspaces. Hyprland 0.49+
      # replaced the old `gestures { workspace_swipe = … }` block with this
      # `gesture = <fingers>, <direction>, <action>` keyword. Direction tracks the
      # natural_scroll setting above, so swipe-left/right feels consistent with
      # two-finger scrolling.
      gesture = "3, horizontal, workspace";

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

      # Scratchpad apps live on SPECIAL workspaces, NOT the tiled ones — toggle
      # them in/out as an overlay. Two scratchpads here: `chat` (Slack/Discord/
      # Signal/Teams, $mod+S) and `media` (Spotify, $mod+A). `silent` stops focus
      # from jumping to the scratchpad when one launches in the background at
      # login (both Discord and Spotify auto-launch from exec-once above).
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

        # Spotify -> its own `media` scratchpad ($mod+A). Verified class is the
        # short `spotify` (XWayland/CEF WM_CLASS); the app id is matched too in
        # case a future flatpak build reports it instead.
        "workspace special:media silent, match:class ^(spotify|com.spotify.Client)$"

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

        # Zoom screen-share annotation toolbar. When you click "Annotate" while
        # WATCHING a share, Zoom spawns a separate overlay window (class `zoom`,
        # title `annotate_toolbar`, XWayland). By default Hyprland TILES it — that
        # geometry fight makes Zoom open it and immediately abandon it, so it
        # flickers open/closed in a loop. Float it (and pin it above the share) so
        # Zoom can place it as the free-floating palette it expects. Match on TITLE:
        # class `zoom` is shared with the main "Meeting" window, so only the title
        # distinguishes the toolbar.
        "float on, match:title ^(annotate_toolbar)$"
        "pin on, match:title ^(annotate_toolbar)$"

        # Bitwarden passkey / unlock popup. Bitwarden is an EXTENSION inside Zen,
        # so the popup it spawns for passkey auth (and autofill-unlock) is a Zen
        # browser window — same `class` (app.zen_browser.zen) as a normal tab, so
        # like the PiP rule above we can only tell it apart by TITLE. Firefox/Zen
        # title extension popup windows `Extension: (<name>) …`; the
        # `Bitwarden Password Manager` prefix is stable across the passkey/unlock
        # flows. Left TILED, Hyprland and the popup fight over geometry — the popup
        # keeps requesting its own size while dwindle re-tiles it — so the window
        # visibly ALTERNATES between a half tile and full screen. Float it (Bitwarden
        # expects a free-floating dialog) and center it at a dialog size to end the
        # fight. `\(` matches the literal paren in the title.
        "float on, match:title ^(Extension: \\(Bitwarden Password Manager\\).*)$"
        "center on, match:title ^(Extension: \\(Bitwarden Password Manager\\).*)$"
        "size 480 640, match:title ^(Extension: \\(Bitwarden Password Manager\\).*)$"

        # GNOME-replacement settings dialogs (the quick-settings stack above):
        # transient config windows, not tiling clients — float + center them like
        # the dialogs above. Classes verified via `hyprctl clients`:
        # nm-connection-editor, pwvucontrol (reverse-DNS id), blueman-manager
        # (wrapped → leading dot, so match loosely).
        "float on, match:class ^(nm-connection-editor)$"
        "center on, match:class ^(nm-connection-editor)$"
        "float on, match:class ^(com.saivert.pwvucontrol)$"
        "center on, match:class ^(com.saivert.pwvucontrol)$"
        "float on, match:class ^(.*blueman-manager.*)$"
        "center on, match:class ^(.*blueman-manager.*)$"
      ];

      # --- Keybinds (see the cheat-sheet comment at the end of this file) ---
      bind = [
        "$mod, Return, exec, ghostty"
        "ALT, space, exec, walker"
        "$mod, D, exec, walker"
        "$mod, W, killactive,"
        "$mod, M, exit,"
        "$mod, V, togglefloating,"
        "$mod, F, fullscreen,"
        "$mod, L, exec, hyprlock"
        "$mod SHIFT, M, exec, ${monitorSetup}"
        # Quick-settings / notification panel (swaync) and manual audio-output picker.
        "$mod, N, exec, swaync-client -t -sw"
        "$mod, O, exec, ${audioSwitcher}"
        "$mod, P, pseudo,"
        "$mod, J, layoutmsg, togglesplit"
        "$mod, S, togglespecialworkspace, chat"
        "$mod, A, togglespecialworkspace, media"

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
      # The numpad mirrors the top row. Bound by KEYCODE (not the KP_n keysym)
      # so it works regardless of NumLock — NumLock-off the numpad emits
      # Home/End/arrows, but the physical keycode is constant. xkb keycodes
      # (evdev+8) in workspace order 1..9,0: KP_1=87 KP_2=88 KP_3=89 KP_4=83
      # KP_5=84 KP_6=85 KP_7=79 KP_8=80 KP_9=81 KP_0=90.
      ++ (builtins.concatLists (builtins.genList (i:
        let
          ws = toString (i + 1);
          key = toString (if i == 9 then 0 else i + 1);
          kp = toString (builtins.elemAt [ 87 88 89 83 84 85 79 80 81 90 ] i);
        in [
          "$mod, ${key}, workspace, ${ws}"
          "$mod SHIFT, ${key}, movetoworkspace, ${ws}"
          "$mod, code:${kp}, workspace, ${ws}"
          "$mod SHIFT, code:${kp}, movetoworkspace, ${ws}"
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

  # Terminal launched by $mod+Return (config-only; no daemon). Ghostty: GPU-native
  # (GTK4/OpenGL on the iGPU — no nvidia-offload needed), replaces the bare kitty.
  # Theme is pinned dark (Catppuccin Mocha) regardless of the desktop's darkman
  # light/dark state — to follow the system instead, use
  # `theme = "light:Catppuccin Latte,dark:Catppuccin Mocha"`.
  programs.ghostty = {
    enable = true;
    settings = {
      theme = "Catppuccin Mocha";   # always dark, regardless of the desktop's
                                    # darkman light/dark state (matches Waybar/swaync)
      font-family = "JetBrainsMono Nerd Font";                 # already in fonts.packages
      font-size = 12;
      background-opacity = 0.95;        # subtle; Hyprland blurs it if blur is on
      cursor-style = "block";
      mouse-hide-while-typing = true;
      window-padding-x = 8;
      window-padding-y = 8;
      copy-on-select = "clipboard";
      confirm-close-surface = false;
      # Shell integration marks each prompt — required for jump_to_prompt below —
      # and drives cursor shape + window title. Auto-detected for zsh; pinned.
      shell-integration = "zsh";
      # ssh-terminfo: auto-install Ghostty's terminfo on remotes over ssh so tmux /
      # ncurses apps work (else "missing or unsuitable terminal: xterm-ghostty").
      # ssh-env: fallback that exports TERM=xterm-256color where terminfo can't be
      # installed (read-only host, no tic). Both = best coverage for SSH-heavy work.
      shell-integration-features = "cursor,sudo,title,ssh-env,ssh-terminfo";
      keybind = [
        # Closest non-Warp analogue to "blocks": hop the viewport prompt-to-prompt.
        "ctrl+shift+up=jump_to_prompt:-1"
        "ctrl+shift+down=jump_to_prompt:1"
        # Warp-style panes.
        "ctrl+shift+enter=new_split:right"
        "ctrl+shift+backslash=new_split:down"
      ];
    };
  };

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
      modules-right = [ "pulseaudio" "network" "custom/battery" "tray" "custom/notification" ];

      "hyprland/workspaces".format = "{id}";
      clock.format = "{:%a %d %b  %I:%M %p}";
      "custom/battery" = {
        exec = "${batteryScript}";
        interval = 30;
        tooltip = false;
      };
      network = {
        on-click = "nm-connection-editor";   # GNOME "Network settings"
        format-wifi = " {signalStrength}%";
        format-ethernet = "󰈀 wired";
        format-disconnected = "⚠ offline";
      };
      pulseaudio = {
        format = "{volume}% {icon}";
        scroll-step = 5;
        on-click = "pwvucontrol";             # full Sound settings (device/profiles/per-app)
        on-click-right = "${audioSwitcher}";  # quick output picker (tofi)
        on-click-middle = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        format-muted = " muted";
        format-icons.default = [ "" "" "" ];
      };
      tray.spacing = 10;
      # swaync bell: notification count + DND state; click opens the quick-settings
      # panel, right-click toggles Do-Not-Disturb. The GNOME quick-settings entry
      # point on the bar. (Glyphs are Nerd Font bell icons.)
      "custom/notification" = {
        tooltip = false;
        format = "{icon}";
        format-icons = {
          notification = "󰂚";
          none = "󰂜";
          dnd-notification = "󰂛";
          dnd-none = "󰪑";
          inhibited-notification = "󰂚";
          inhibited-none = "󰂜";
          dnd-inhibited-notification = "󰂛";
          dnd-inhibited-none = "󰪑";
        };
        return-type = "json";
        exec = "swaync-client -swb";
        on-click = "swaync-client -t -sw";
        on-click-right = "swaync-client -d -sw";
        escape = true;
      };
    };
    style = ''
      * { font-family: "JetBrainsMono Nerd Font", "Font Awesome 6 Free"; font-size: 13px; }
      window#waybar { background: rgba(30,30,46,0.85); color: #cdd6f4; }
      #workspaces button { padding: 0 8px; color: #cdd6f4; }
      #workspaces button.active { background: #585b70; }
      #clock, #custom-battery, #network, #pulseaudio, #tray, #custom-notification { padding: 0 10px; }
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

  # (Wallpaper is now the swww slideshow — see wallpaperSlideshow in the let
  # block and the exec-once list. No hyprpaper.conf needed.)

  # Idle behavior: dim warning at 4.5 min, lock at 5 min, screen off at 6 min, and suspend-then-hibernate
  # at 20 min ON BATTERY ONLY — matching the old GNOME power config (auto-suspend
  # on battery idle, "nothing" on AC). Lid/power-key suspend stays owned by the
  # logind matrix in modules/hibernation.nix; this just adds the idle path.
  xdg.configFile."hypr/hypridle.conf".text = ''
    general {
        lock_cmd = pidof hyprlock || hyprlock
        before_sleep_cmd = loginctl lock-session
        after_sleep_cmd = hyprctl dispatch dpms on
    }
    # Dim warning ~30s before the lock (GNOME-style idle fade). on-resume
    # restores the saved brightness the moment there's activity.
    listener {
        timeout = 270
        on-timeout = ${idleDim}
        on-resume = ${idleUndim}
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

  # swaync — notifications + the quick-settings panel (started via exec-once;
  # NOT the services.swaync systemd unit, since this session launches its daemons
  # from Hyprland exec-once, see the header comment). Built as a Nix attrset via
  # toJSON so the JSON can't drift out of syntax and the Output button can splice
  # in the audioSwitcher store path. Widgets, top→bottom: title (Clear-All),
  # DND toggle, media (MPRIS), master+per-app volume slider, brightness slider,
  # the toggle/launch grid, then the notification list. backlight device is
  # intel_backlight (the only /sys/class/backlight entry on this laptop).
  xdg.configFile."swaync/config.json".text = builtins.toJSON {
    "$schema" = "/etc/xdg/swaync/configSchema.json";
    positionX = "right";
    positionY = "top";
    control-center-width = 400;
    control-center-height = 740;
    control-center-margin-top = 8;
    control-center-margin-bottom = 8;
    control-center-margin-right = 8;
    notification-window-width = 400;
    fit-to-screen = true;
    keyboard-shortcuts = true;
    image-visibility = "when-available";
    transition-time = 200;
    hide-on-clear = false;
    hide-on-action = true;
    widgets = [ "title" "mpris" "volume" "backlight" "buttons-grid" "notifications" ];
    widget-config = {
      title = { text = "Quick Settings"; clear-all-button = true; button-text = "Clear All"; };
      mpris = { image-size = 88; image-radius = 12; };
      volume = { label = "󰕾"; show-per-app = true; show-per-app-label = true; };
      backlight = { label = "󰃟"; device = "intel_backlight"; };
      # GNOME-style quick-settings tiles. TOP ROW = live ON/OFF toggles: state is
      # refreshed each time the panel opens via update-command (which MUST echo
      # `true`/`false`); on click the command sees the NEW desired state in
      # $SWAYNC_TOGGLE_STATE and the tile gets the `.active` CSS class (accent
      # fill — see style.css). BOTTOM ROW opens the full apps for the one thing
      # swaync can't draw inline: the device/network LISTS (pick a Wi-Fi, pair a
      # headset, choose an output — pwvucontrol IS the audio output picker).
      # Backends: nmcli (NetworkManager), bluetoothctl (bluez), swaync-client (DND).
      "buttons-grid" = {
        buttons-per-row = 3;
        actions = [
          { label = "󰖩  Wi-Fi"; type = "toggle";
            command = "sh -c '[ \"$SWAYNC_TOGGLE_STATE\" = true ] && nmcli radio wifi on || nmcli radio wifi off'";
            update-command = "sh -c '[ \"$(nmcli radio wifi)\" = enabled ] && echo true || echo false'"; }
          { label = "󰂯  Bluetooth"; type = "toggle";
            command = "sh -c '[ \"$SWAYNC_TOGGLE_STATE\" = true ] && bluetoothctl power on || bluetoothctl power off'";
            update-command = "sh -c 'bluetoothctl show | grep -q \"Powered: yes\" && echo true || echo false'"; }
          { label = "󰂛  Do Not Disturb"; type = "toggle";
            command = "swaync-client -d -sw";
            update-command = "swaync-client -D"; }
          { label = "󰖟  Network";  command = "nm-connection-editor"; }
          { label = "󰓃  Sound";    command = "pwvucontrol"; }
          { label = "󰂲  Devices";  command = "blueman-manager"; }
        ];
      };
      notifications = { vexpand = true; };
    };
  };
  # Catppuccin Mocha to match Waybar (bg #1e1e2e, text #cdd6f4, accent #585b70,
  # blue #89b4fa). cssPriority stays default ("application") so this overrides
  # the package's shipped theme.
  xdg.configFile."swaync/style.css".text = ''
    @define-color base   #1e1e2e;
    @define-color mantle #181825;
    @define-color surface #313244;
    @define-color overlay #585b70;
    @define-color text   #cdd6f4;
    @define-color blue   #89b4fa;

    * { font-family: "JetBrainsMono Nerd Font"; font-size: 13px; }

    .notification-row .notification-background,
    .notification-row .notification-background .notification {
      background: @base; color: @text;
      border: 1px solid @overlay; border-radius: 8px; margin: 4px 8px;
    }
    .notification-row .notification-background .notification .notification-content { padding: 6px; }
    .close-button { background: transparent; color: @text; border-radius: 6px; }
    .close-button:hover { background: @blue; color: @base; }

    .control-center {
      background: @mantle; color: @text;
      border: 1px solid @overlay; border-radius: 12px; padding: 12px;
    }
    .control-center .widget-title { color: @text; font-size: 16px; margin: 4px 4px 8px 4px; }
    .control-center .widget-title > button {
      background: @surface; color: @text; border-radius: 8px; padding: 4px 10px;
    }
    .control-center .widget-title > button:hover { background: @blue; color: @base; }

    /* Sliders (volume + brightness) */
    .widget-volume, .widget-backlight {
      background: @base; border-radius: 10px; padding: 8px; margin: 4px 0;
    }
    trough { background: @surface; border-radius: 8px; }
    trough highlight, highlight { background: @blue; border-radius: 8px; }
    slider { background: @text; border-radius: 50%; }

    /* Toggle / launch grid */
    .widget-buttons-grid { background: @base; border-radius: 10px; padding: 8px; margin: 4px 0; }
    .widget-buttons-grid > flowbox > flowboxchild > button {
      background: @surface; color: @text; border-radius: 8px; padding: 10px; margin: 4px;
    }
    .widget-buttons-grid > flowbox > flowboxchild > button:hover { background: @overlay; color: @text; }
    /* Active toggle tile (Wi-Fi/BT/DND on) — accent fill, like a lit GNOME tile. */
    .widget-buttons-grid > flowbox > flowboxchild > button.active { background: @blue; color: @base; }

    .widget-mpris { background: @base; border-radius: 10px; padding: 6px; margin: 4px 0; }
    .widget-dnd { color: @text; margin: 4px; }
    .widget-dnd > switch { background: @surface; border-radius: 12px; }
    .widget-dnd > switch:checked { background: @blue; }
  '';
  # tofi theme for the audio-output picker (audioSwitcher). Centered, Catppuccin.
  xdg.configFile."tofi/config".text = ''
    width = 420
    height = 260
    border-width = 2
    outline-width = 0
    corner-radius = 10
    padding-top = 12
    padding-bottom = 12
    padding-left = 16
    padding-right = 16
    font = JetBrainsMono Nerd Font
    background-color = #1e1e2e
    border-color = #585b70
    text-color = #cdd6f4
    prompt-color = #89b4fa
    selection-color = #89b4fa
    result-spacing = 6
    num-results = 6
  '';

  # Hyprland-session tooling. (ghostty/waybar/hyprlock come from their HM modules
  # above; wpctl ships with the system PipeWire/WirePlumber.)
  home.packages = with pkgs; [
    walker          # Spotlight-style launcher FRONTEND (ALT+Space / $mod+D). Runs
                    # as a GApplication service from exec-once; the keybinds just
                    # message the running service.
    elephant        # walker's BACKEND daemon — supplies all providers (apps, calc,
                    # files, clipboard, websearch…). walker 2.x is useless without
                    # it; also started from exec-once (see the launcher block above).
    swaynotificationcenter # notifications + quick-settings panel (exec-once; was mako)
    pwvucontrol     # native PipeWire mixer — full Sound settings (volume on-click)
    blueman         # Bluetooth manager + tray applet (blueman-applet, exec-once)
    networkmanagerapplet # nm-applet (tray, exec-once) + nm-connection-editor (clicks)
    tofi            # dmenu for the audio-output picker (audioSwitcher)
    awww            # wallpaper slideshow daemon (exec-once; was swww)
    hypridle        # idle -> lock/dpms (exec-once)
    wl-gammarelay-rs # software gamma/brightness daemon for the idle dim (exec-once)
    grim slurp      # screenshots (Print)
    wl-clipboard    # wl-copy / wl-paste
    brightnessctl   # backlight keys
  ];

  # ──────────────────────────────────────────────────────────────────────────
  # KEYBIND CHEAT-SHEET ($mod = Super/Windows key)
  # Apps & session
  #   $mod+Return ............ terminal (ghostty)
  #   Alt+Space (or $mod+D) .. launcher (walker — apps, calc, files, clipboard, web)
  #   $mod+W ................. close focused window
  #   $mod+L ................. lock screen (hyprlock)
  #   $mod+N ................. quick-settings / notification panel (swaync)
  #   $mod+O ................. pick audio output device (tofi)
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
  #   $mod+1..0 .............. switch to workspace 1..10 (numpad mirrors this)
  #   $mod+Shift+1..0 ........ send window to workspace 1..10 (numpad too)
  #   $mod+Ctrl+arrows ....... move current workspace to the monitor that way
  #   $mod+S ................. toggle chat scratchpad (Slack/Discord/Signal/Teams)
  #   $mod+A ................. toggle media scratchpad (Spotify)
  #   $mod+Shift+M ........... re-run monitor setup (4K modeset fix + clamshell)
  # Media / capture
  #   Print .................. region screenshot -> clipboard
  #   Volume / Brightness .... wpctl / brightnessctl (hardware keys; sliders in $mod+N)
  #   Audio: click volume .... pwvucontrol (full Sound); right-click .. output picker
  # ──────────────────────────────────────────────────────────────────────────
}
