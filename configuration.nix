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
    ];

  # --- local feature toggles (see each module) ---
  my.impermanence.enable = true;   # ephemeral btrfs root + /persist
  my.hibernation.enable  = true;
  my.hibernation.resumeOffset = 533760;  # /swap/swapfile offset (btrfs inspect-internal map-swapfile); re-derive on reinstall
  my.secureBoot.enable   = false;  # PHASE 2: flip true AFTER `sbctl create-keys` (see module)
  my.backups.enable      = false;  # flip true AFTER the age key + secrets/secrets.yaml exist

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

  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  services.flatpak.enable = true;

  # CUPS for campus/network printers.
  services.printing.enable = true;

  # Bluetooth (controller present). Pinned explicitly so the flake owns it.
  hardware.bluetooth.enable = true;

  # Intel thermal management (Tiger Lake-H + RTX 3060 in a 15" chassis).
  services.thermald.enable = true;

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
    extraGroups = [ "wheel" "docker" "dialout" ];
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

  environment.systemPackages = with pkgs; [
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
  ];

  networking.firewall.enable = true;

  # See the comment in the original: keep in sync with home.stateVersion.
  system.stateVersion = "25.11";
}
