# NixOS entry point for chris-laptop. Now a flake (see flake.nix); home-manager,
# disko, impermanence, lanzaboote and sops-nix come in as flake inputs/modules,
# not via fetchTarball. The disk layout lives in disko-config.nix.
{ config, lib, pkgs, inputs, ... }:

{
  imports =
    [ ./hardware-configuration.nix
      ./disko-config.nix
      ./modules/impermanence.nix
      ./modules/hibernation.nix
      ./modules/secure-boot.nix
      ./modules/backups.nix
      ./modules/hyprland.nix
    ];

  # --- local feature toggles (see each module) ---
  my.impermanence.enable = true;   # ephemeral btrfs root + /persist
  my.hibernation.enable  = true;
  my.hibernation.resumeOffset = 533760;  # /swap/swapfile offset (btrfs inspect-internal map-swapfile); re-derive on reinstall
  my.secureBoot.enable   = false;  # PHASE 2: flip true AFTER `sbctl create-keys` (see module)
  my.backups.enable      = false;  # flip true AFTER the age key + secrets/secrets.yaml exist
  my.hyprland.enable     = true;   # Hyprland session selectable at GDM (GNOME stays the default)

  # Boot loader. systemd-boot by default; modules/secure-boot.nix replaces it with
  # lanzaboote (signed) once my.secureBoot.enable = true.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd-stage1 initrd: TPM2 auto-unlock + the impermanence rollback both need it.
  boot.initrd.systemd.enable = true;

  # LUKS device is created/declared by disko (disko-config.nix). Here we only add
  # the TPM2 auto-unlock opt; the keyslot is enrolled post-install with
  # systemd-cryptenroll (and re-enrolled once Secure Boot is on — see secure-boot.nix).
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "tpm2-device=auto" ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # zswap: compressed RAM cache in front of the disk swap (hibernation-compatible,
  # unlike zram). mem_sleep_default=deep: prefer S3 over drain-prone s2idle for the
  # pre-hibernate window (machine exposes `[s2idle] deep`).
  boot.kernelParams = [
    "zswap.enabled=1" "zswap.compressor=zstd" "zswap.zpool=zsmalloc" "zswap.max_pool_percent=20"
    "mem_sleep_default=deep"
  ];

  # Disable HDA audio power-saving: the SOF codec/controller suspending on idle
  # clips the onset of playback (first syllable dropped when audio resumes).
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=0 power_save_controller=N
  '';

  # Transparent aarch64 emulation via qemu-user + binfmt_misc — required to run
  # arm64 Debian inside systemd-nspawn for the felix/kleaf rootfs build (the
  # debootstrap second-stage executes aarch64 binaries on this x86_64 host).
  # Registers /proc/sys/fs/binfmt_misc/qemu-aarch64.
  boot.binfmt = {
    emulatedSystems = [ "aarch64-linux" ];
    # Without fixBinary, qemu's interpreter path is resolved at exec time, but
    # inside systemd-nspawn containers that /run/binfmt path doesn't exist.
    registrations.aarch64-linux.fixBinary = true;
  };

  networking.hostName = "chris-laptop";
  networking.networkmanager.enable = true;
  # openconnect plugin: AnyConnect VPN type in GNOME Settings (UCSD vpn.ucsd.edu).
  networking.networkmanager.plugins = with pkgs; [ networkmanager-openconnect ];

  time.timeZone = "America/Los_Angeles";
  # Dual-boot with Windows: Windows treats the RTC as local time, so match it here
  # instead of fighting it (otherwise the clock is off by the UTC offset after
  # switching OSes). The cleaner alternative is making Windows use UTC (the
  # `RealTimeIsUniversal` registry DWORD), but this matches your usual approach.
  time.hardwareClockInLocalTime = true;
  # Was commented out (defaulting to the C locale). Set it explicitly.
  i18n.defaultLocale = "en_US.UTF-8";

  # X infrastructure kept for the NVIDIA driver config (videoDrivers below) and
  # XWayland. No X *session* is used — the desktop is Hyprland on Wayland.
  services.xserver.enable = true;

  # GNOME + GDM removed for now (going Hyprland-only). GDM's Wayland greeter on
  # NVIDIA left a stuck cursor that Hyprland couldn't clear, and GNOME 50 no
  # longer allows an X11 greeter — so we drop GDM entirely. Re-enable these two
  # lines to bring GNOME back.
  # services.displayManager.gdm.enable = true;
  # services.desktopManager.gnome.enable = true;

  # File manager: Thunar (XFCE). Replaces GNOME Files now that GNOME is gone.
  # The NixOS module wires up the D-Bus side Thunar needs to be fully featured:
  #   - gvfs    -> trash, network shares, and auto-mounting removable drives
  #   - tumbler -> thumbnails for images/PDFs/video
  #   - plugins -> archive extract/create (right-click) + removable-media handling
  programs.thunar = {
    enable = true;
    plugins = with pkgs.xfce; [ thunar-archive-plugin thunar-volman ];
  };
  services.gvfs.enable = true;
  services.tumbler.enable = true;

  # Login greeter: greetd + ReGreet, run INSIDE a dedicated Hyprland instance.
  #
  # History: the earlier graphical attempts failed for compositor-specific
  # reasons — GDM left a stuck cursor handed off to Hyprland (NVIDIA), and
  # ReGreet-in-cage hit cage's multi-monitor limits (greeter on the wrong screen,
  # cut off). We fell back to tuigreet (no compositor, so neither bug applies).
  # This setup keeps the graphical greeter but uses HYPRLAND as ReGreet's host
  # compositor instead of cage: monitor placement/scaling is controlled by the
  # same `monitor =` config the user session uses (fixing the cut-off/wrong-screen
  # problem), and the stuck-cursor bug was GDM-specific — it can't occur when the
  # greeter compositor IS Hyprland (Hyprland renders on the Intel iGPU).
  #
  # The greeter Hyprland runs `regreet` and exits (`hyprctl dispatch exit`) when
  # ReGreet hands control to greetd; greetd then starts the chosen session
  # (start-hyprland, from the wayland-sessions entry registered below). ReGreet
  # itself (theme/background/sessions) is configured via programs.regreet.
  services.greetd = let
    hypr = config.programs.hyprland.package;   # same Hyprland as the user session
    regreetExe = lib.getExe config.programs.regreet.package;
    # Greeter compositor config. Mirrors the user session's per-monitor layout
    # (home-hyprland.nix) so ReGreet lands on the 4K at the right scale when
    # docked; falls through to the laptop panel when undocked. Kept minimal —
    # no bar/wallpaper daemons, just place monitors and run ReGreet.
    greeterConfig = pkgs.writeText "greetd-hyprland.conf" ''
      monitor = desc:Samsung Electric Company LU28R55 HCJW902122, preferred, 0x0, 1.25
      monitor = desc:Dell Inc. DELL E2318HR 5JDGK74BAJFL, preferred, 3072x0, 1
      monitor = eDP-1, preferred, auto, 1.5
      monitor = , preferred, auto, 1

      input { numlock_by_default = true }
      cursor { no_hardware_cursors = true }
      animations { enabled = false }
      misc {
        disable_hyprland_logo = true
        disable_splash_rendering = true
      }

      # Clamshell (don't draw the greeter on a closed internal panel), prefer the
      # 4K when docked, run ReGreet, then exit Hyprland so greetd starts the
      # selected session. Each step is a no-op if its monitor is absent (undocked).
      exec-once = ${pkgs.bash}/bin/sh -c '${pkgs.gnugrep}/bin/grep -qil closed /proc/acpi/button/lid/*/state && ${hypr}/bin/hyprctl keyword monitor eDP-1,disable; ${hypr}/bin/hyprctl dispatch focusmonitor "desc:Samsung Electric Company LU28R55 HCJW902122"; ${regreetExe}; ${hypr}/bin/hyprctl dispatch exit'
    '';
  in {
    enable = true;
    # Launch via the `start-hyprland` watchdog wrapper, NOT the raw `Hyprland`
    # binary — Hyprland 0.55 refuses to start when invoked directly. Args after
    # `--` are forwarded to Hyprland (`--config FILE`).
    settings.default_session = {
      command = "${pkgs.dbus}/bin/dbus-run-session ${hypr}/bin/start-hyprland -- --config ${greeterConfig}";
      user = "greeter";
    };
  };

  # Graphical greeter (ReGreet). The greetd command above launches it inside
  # Hyprland (overriding the module's default cage command). theme/font default
  # to Adwaita/Cantarell; background matches the desktop wallpaper for continuity.
  programs.regreet = {
    enable = true;
    settings = {
      background = {
        path = pkgs.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath;
        fit = "Cover";
      };
      GTK.application_prefer_dark_theme = true;
    };
  };

  # ReGreet lists sessions from the wayland-sessions desktop files in XDG_DATA_DIRS.
  # Dropping GDM removed the display manager that used to register them, leaving the
  # list empty — so register Hyprland's session entry (Exec=start-hyprland) here.
  services.displayManager.sessionPackages = [ pkgs.hyprland ];

  services.flatpak.enable = true;

  # Location service for darkman's geoclue-based sunrise/sunset (home.nix). The
  # demo agent (enabled by default) authorizes per-user apps against appConfig
  # below — darkman's desktop ID must be allowlisted or it gets no fix. Mozilla
  # Location Service shut down in 2024, so point the WiFi geolocation backend at
  # beaconDB (its community successor); without it geoclue has no network source.
  # If geoclue ever proves flaky, drop to fixed coords: set lat/lng + usegeoclue
  # = false in services.darkman.settings (home.nix) and disable this.
  services.geoclue2 = {
    enable = true;
    geoProviderUrl = "https://beacondb.net/v1/geolocate";
    appConfig.darkman = {
      isAllowed = true;
      isSystem = false;
      users = [ "1000" ];   # chris (id -u); geoclue keys its allowlist by uid string
    };
  };

  # CUPS for campus/network printers.
  services.printing.enable = true;

  # Bluetooth (controller present). Pinned explicitly so the flake owns it.
  hardware.bluetooth.enable = true;

  # Intel thermal management (Tiger Lake-H + RTX 3060 in a 15" chassis).
  services.thermald.enable = true;

  # Thunderbolt dock fix. The Tiger Lake-H TB4 NHI (8086:9a21) has buggy
  # firmware: ~15s after the controller goes idle the kernel runtime-suspends
  # it, the firmware times out (nhi_runtime_suspend -> -110), and the device
  # drops into PM "error" — after which it can no longer enumerate a dock, even
  # on a fresh boot before anything is plugged in (the controller wedges itself
  # from idle, NOT from system sleep). Symptom: dock/external displays/USB hub
  # simply never appear; dmesg shows "failed to send driver ready to ICM" and
  # "Cannot enable. Maybe the USB cable is bad?". Pin the NHI always-on so it
  # never attempts the broken runtime-suspend. (System suspend/hibernate WHILE
  # docked is a separate path — the logind lid matrix in hibernation.nix already
  # avoids sleeping when docked.)
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x9a21", ATTR{power/control}="on"
  '';

  # Firmware updates via LVFS (SSD/Thunderbolt/peripherals; MSI BIOS coverage is thin).
  services.fwupd.enable = true;

  # Periodic SSD TRIM (carried forward, now explicit) + btrfs scrub (bit-rot scan).
  services.fstrim.enable = true;
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/" ];   # one btrfs fs; scrubbing any subvol scrubs the device
  };

  nixpkgs.config.allowUnfree = true;

  # Workaround: pipx 1.8.0's test suite fails on this nixpkgs pin — cosmetic
  # package-spec normalization drift (`pkg@url` vs `pkg @ url`) in
  # test_package_specifier.py, not a functional break — which otherwise fails the
  # whole build. `depend` needs the pipx binary (packages.yaml data-tools block), so
  # skip its checkPhase rather than dropping it. Remove once nixpkgs ships a fixed
  # pipx — or migrate that block to `uv tool` (uv is already installed).
  nixpkgs.overlays = [
    (final: prev: {
      pipx = prev.pipx.overridePythonAttrs (old: { doCheck = false; });

      # envfs 1.2.0 — nixpkgs still ships 1.1.0, whose single-threaded FUSE daemon
      # DEADLOCKS whenever a caller's PATH contains /bin or /usr/bin: it re-enters its
      # own mount and every exec through /bin·/usr/bin then hangs in D-state
      # (Mic92/envfs#145/#196). That froze the GNOME desktop on every wipe-enabled gen.
      # 1.2.0 fixes it ("Avoid FUSE deadlocks by resolving paths with O_PATH fds").
      # This is exactly nixpkgs PR #500707 (package-only bump) applied as an overlay;
      # it stays on nixpkgs' fetchCargoVendor, which pulls crates from the
      # static.crates.io CDN — NOT the upstream flake's importCargoLock, which 403s on
      # crates.io's legacy /api/v1/download endpoint. Drop this once #500707 lands.
      envfs = prev.envfs.overrideAttrs (old: rec {
        version = "1.2.0";
        src = final.fetchFromGitHub {
          owner = "Mic92";
          repo = "envfs";
          rev = version;
          hash = "sha256-hj/6zS9ebF0IDqgc1Dne59nWx80nk6jn2gj8BzQUFIQ=";
        };
        cargoDeps = final.rustPlatform.fetchCargoVendor {
          inherit src;
          name = "envfs-${version}-vendor";
          hash = "sha256-dz3gpE464jnmSDsAsmJHcxUsEKeUURNoUjgGU2214Xg=";
        };
      });
    })
  ];

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store   = true;
    # Trust wheel so per-project devshell / cachix substituters (rust-overlay, the
    # CUDA cache, project caches) are honored instead of silently ignored. Safe
    # here — single-user box, and chris already has sudo.
    trusted-users = [ "root" "@wheel" ];
    # Keep dev-shell build inputs from being GC'd (pairs with direnv/nix-direnv).
    keep-outputs     = true;
    keep-derivations = true;
    # CUDA binary cache: download CUDA-enabled packages instead of compiling them.
    extra-substituters       = [ "https://cuda-maintainers.cachix.org" ];
    extra-trusted-public-keys = [ "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E=" ];
  };

  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
  };

  # `comma`: run any nixpkgs binary on demand (`, ffmpeg`) without installing it,
  # and command-not-found suggestions. Uses the prebuilt nix-index database (the
  # nix-index-database flake input) so it works immediately — no manual `nix-index`.
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  # The home-manager activation runs `depend install` (packages.yaml: flatpaks,
  # vscode extensions, pipx) on every switch. On a FRESH/impermanent install that's
  # a multi-GB first-boot download that overran the default start timeout and got
  # SIGTERM'd mid-install. Give it headroom — it's a one-time cost (user flatpaks
  # then persist on /home). (A sturdier design would move `depend` into its own
  # non-blocking oneshot service instead of the activation; this fixes the timeout.)
  # (home-manager sets this to "5m" by default — that was the 5-minute kill.)
  systemd.services.home-manager-chris.serviceConfig.TimeoutStartSec = lib.mkForce "30min";

  # NVIDIA RTX 3060 Mobile (Ampere) + Intel Tiger Lake iGPU. PRIME render offload:
  # iGPU drives the display, NVIDIA on demand via the `nvidia-offload` wrapper.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  fonts.packages = with pkgs; [ ubuntu-classic ];

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  # Declarative passwords — REQUIRED under impermanence: /etc/shadow lives on the
  # ephemeral root, so a `passwd`-set password is wiped on every @ rollback. The
  # hash lives in durable /persist (NOT in this repo). Create/rotate it with:
  #     mkpasswd -m sha-512 | sudo tee /persist/passwd/chris   # then: sudo chmod 600
  users.mutableUsers = false;
  users.users.chris = {
    isNormalUser = true;
    hashedPasswordFile = "/persist/passwd/chris";
    # dialout = serial/UART console access (junkyard UART work, /dev/ttyUSB*).
    extraGroups = [ "wheel" "docker" "dialout" "input" ];
  };
  # No direct root login; admin via sudo (chris in wheel).
  users.users.root.hashedPassword = "!";

  virtualisation.docker.enable = true;
  # GPU-accelerated containers: `docker run --gpus all ...` (PyTorch/TF/CUDA images).
  hardware.nvidia-container-toolkit.enable = true;

  # Android device access (adb/fastboot/recovery + the Quest) is handled by
  # systemd's built-in uaccess rules — the old `android-udev-rules` package was
  # removed from nixpkgs as redundant. Add a `services.udev.extraRules` entry only
  # if a specific device/mode turns out not to be tagged.

  # --- VR / OpenXR: WiVRn streams the rendered XR view to a Quest 2 over Wi-Fi ---
  services.wivrn = {
    enable = true;
    openFirewall = true;
    autoStart = true;
    highPriority = true;
    steam.enable = false;
    monadoEnvironment = {
      __NV_PRIME_RENDER_OFFLOAD = "1";
      __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      __VK_LAYER_NV_optimus = "NVIDIA_only";
    };
  };

  # Dynamic-loader shim for prebuilt (non-Nix) ELF binaries — lets the plain
  # (non-FHS) VSCode run extensions that download native binaries.
  programs.nix-ld.enable = true;
  # Libraries that prebuilt (pip/conda) wheels dlopen via nix-ld — without these
  # `import cv2` dies with "libGL.so.1: cannot open object file". Covers
  # opencv-python / numpy / torch wheels and the Android SDK's prebuilt binaries.
  # (CUDA wheels ship their own CUDA libs; libcuda comes from the NVIDIA driver.)
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib            # libstdc++
    zlib
    glib                        # libgthread (opencv)
    libGL libglvnd              # cv2 / rendering
    openssl
    libx11 libxext libxrender libsm libice
    libxtst libxi                # JetBrains/Java GUI input (Toolbox-installed IDEs)
    libsecret                    # JetBrains credential storage
    libxkbcommon
    fontconfig freetype
  ];

  # envfs: a FUSE filesystem over /usr/bin and /bin that resolves any
  # `/usr/bin/<tool>` / `/bin/<tool>` (and `#!/usr/bin/env <x>` shebangs) against
  # PATH at runtime — NixOS has no FHS, so prebuilt scripts/binaries that hardcode
  # those paths otherwise die. Complements nix-ld (loader shim for prebuilt ELFs).
  # NOTE: the impermanence initrd reseed of /usr/bin/env (modules/impermanence.nix)
  # is still required — it satisfies the systemd-258 PID1 /usr check before envfs's
  # stage-2 mount is up.
  services.envfs = {
    enable = true;
    # package comes from the overlay above (envfs 1.2.0, fixes the FUSE deadlock).
    # Make these resolve at /bin/<x> and /usr/bin/<x> regardless of the caller's PATH,
    # so Bazel/kleaf actions (which run with a sanitized PATH) can exec /bin/bash and
    # /usr/bin/env python3. Without this, envfs only resolves names on the caller's PATH,
    # which Bazel strips per-action — the reason the kleaf build fails in a plain shell.
    extraFallbackPathCommands = ''
      for p in ${pkgs.bash} ${pkgs.coreutils} ${pkgs.python3} ${pkgs.perl} \
               ${pkgs.gnused} ${pkgs.gnugrep} ${pkgs.gawk} ${pkgs.findutils} \
               ${pkgs.gnutar} ${pkgs.gzip} ${pkgs.diffutils} ${pkgs.which}; do
        for f in "$p"/bin/*; do ln -sfn "$f" "$out/$(basename "$f")"; done
      done
    '';
  };

  # --- Gaming (Steam / Proton) ---
  # Native Steam — better PRIME / 32-bit / controller integration than the flatpak
  # (32-bit graphics is already enabled above). PRIME offload is made AUTOMATIC via
  # extraEnv below, so games render on the RTX 3060 without `nvidia-offload` in the
  # launch options. GameMode stays opt-in per game: `gamemoderun %command%`.
  # For VR/Beat Saber the primary path is WiVRn + OpenComposite + Proton (NO
  # SteamVR); ALVR + SteamVR is the fallback (alvr below).
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;   # in-home streaming / Remote Play
    # Bake the offload env into Steam's FHS wrapper so every child (game) inherits
    # it — same 4 vars as the `nvidia-offload` wrapper / WiVRn monadoEnvironment.
    # TRADEOFF: the Steam *client* UI also lands on the dGPU, so finegrained power
    # management won't let the 3060 sleep while Steam is open — close it when idle.
    package = pkgs.steam.override {
      extraEnv = {
        __NV_PRIME_RENDER_OFFLOAD = "1";
        __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
        __GLX_VENDOR_LIBRARY_NAME = "nvidia";
        __VK_LAYER_NV_optimus = "NVIDIA_only";
      };
    };
  };
  programs.gamemode.enable = true;    # CPU governor/scheduling boost (gamemoderun)

  # E4E Synology FileStation FUSE mounter — non-root mounts need user_allow_other
  # in /etc/fuse.conf, which this option writes. (No NixOS module ships with the
  # flake; the package itself is added to systemPackages below.)
  programs.fuse.userAllowOther = true;

  # E4E Synology FileStation (flake input). The Avalonia GUI (`SynologyFuse.Gui`)
  # shells out to the `synology-filestation-fuse` CLI via PATH — in the Nix layout
  # the CLI is a SEPARATE package, not bundled beside the GUI, so BOTH must be on
  # PATH or mounting silently can't start. A home-manager desktop entry (home.nix)
  # makes the GUI show up in the GNOME app grid (the package ships no .desktop).
  environment.systemPackages =
    (with inputs.synology-filestation.packages.${pkgs.stdenv.hostPlatform.system}; [
      synologyfuse-gui
      synology-filestation-fuse
    ]) ++ (with pkgs; [
    cudatoolkit       # nvcc + CUDA libraries on PATH
    pciutils          # lspci
    android-tools     # adb + fastboot
    dnsutils          # nslookup, dig, host
    vulkan-tools      # vulkaninfo (VR GPU/encode diagnostics)
    # rebuild/secrets tooling
    sbctl             # Secure Boot key management (lanzaboote)
    sops age ssh-to-age  # edit/inspect sops secrets; derive age key from the SSH key
    nvtopPackages.nvidia # GPU utilization monitor (training/inference)
    tio               # serial terminal for UART console work (junkyard etc.)
    alvr              # SteamVR->Quest streaming, fallback VR path (opens its own LAN ports at runtime)
  ]);

  networking.firewall.enable = true;

  # See the comment in the original: keep in sync with home.stateVersion.
  system.stateVersion = "25.11";
}
