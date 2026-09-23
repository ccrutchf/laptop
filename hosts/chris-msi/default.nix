# NixOS entry point for chris-msi. Now a flake (see flake.nix); home-manager,
# disko, impermanence, lanzaboote and sops-nix come in as flake inputs/modules,
# not via fetchTarball. The disk layout lives in disko-config.nix.
{ config, lib, pkgs, inputs, ... }:

{
  imports =
    [ ./hardware-configuration.nix
      ./disko-config.nix
      # shared layers (see each file)
      ../../modules/nixos/common.nix
      ../../modules/nixos/desktop.nix
      ../../modules/nixos/overlays.nix
      # opt-in features, toggled by the my.* flags below
      ../../modules/nixos/impermanence.nix
      ../../modules/nixos/hibernation.nix
      ../../modules/nixos/secure-boot.nix
      ../../modules/nixos/backups.nix
    ];

  # --- local feature toggles (see each module) ---
  my.impermanence.enable = true;   # ephemeral btrfs root + /persist
  my.hibernation.enable  = true;
  my.hibernation.resumeOffset = 533760;  # /swap/swapfile offset (btrfs inspect-internal map-swapfile); re-derive on reinstall
  my.secureBoot.enable   = false;  # PHASE 2: flip true AFTER `sbctl create-keys` (see module)
  my.backups.enable      = false;  # flip true AFTER the age key + secrets/secrets.yaml exist

  # LUKS device is created/declared by disko (disko-config.nix). Here we only add
  # the TPM2 auto-unlock opt; the keyslot is enrolled post-install with
  # systemd-cryptenroll (and re-enrolled once Secure Boot is on — see secure-boot.nix).
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "tpm2-device=auto" ];

  # zswap: compressed RAM cache in front of the disk swap (hibernation-compatible,
  # unlike zram). mem_sleep_default=deep: prefer S3 over drain-prone s2idle for the
  # pre-hibernate window (machine exposes `[s2idle] deep`).
  boot.kernelParams = [
    "zswap.enabled=1" "zswap.compressor=zstd" "zswap.zpool=zsmalloc" "zswap.max_pool_percent=20"
    "mem_sleep_default=deep"
  ];

  # Disable HDA audio power-saving: the SOF codec/controller suspending on idle
  # clips the onset of playback (first syllable dropped when audio resumes).
  #
  # msi_ec: this machine's EC reports 16V4EMS2.108, which upstream msi-ec does not
  # whitelist, so the module refuses to load without an override. The board (MS-16V4)
  # is the GS66 Stealth 11UE's, whose EMS1 firmware maps to CONF_G2_2 — hence forcing
  # that profile. Verified against the live EC in debug mode BEFORE writing to it:
  # 0x68 read 94 while coretemp independently said 96, 0x80 read 79 while nvidia-smi
  # independently said 79, and 0xd2=c1 (comfort) / 0xd4=0d (auto) are both legal enum
  # values for the profile. Every other EMS1/EMS2 sibling pair in the driver (16R4,
  # 1585, 16W1, 17L5, 15M1) shares one config, i.e. EMS2 is a board revision and not
  # a different EC layout. Re-check this if msi-ec is ever updated to know EMS2.
  # The dump behind that reasoning, plus the stock fan curves and how to re-capture
  # them, is in ./ec-baseline-16V4EMS2.108.txt.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=0 power_save_controller=N
    options msi_ec firmware=16V4EMS1.116
  '';

  # MSI EC fan/thermal control, exposed at /sys/devices/platform/msi-ec/:
  #   shift_mode    eco|comfort|turbo    raises the whole fan ceiling
  #   cooler_boost  on|off               pins fans to the top of the current table
  #   fan_mode      auto|silent|advanced
  # realtime_fan_speed is a percentage of the ACTIVE shift_mode's table, not an
  # absolute: "100%" in comfort is ~4200 rpm, in turbo ~8100 rpm. Under a pinned
  # 80W GPU load, turbo+boost took the fans 3582/4210/4173 -> 8135/6956/7058 rpm,
  # dropped the GPU 79 -> 69 C and cleared its HW thermal slowdown entirely.
  # Nothing is forced at boot on purpose: comfort/auto is the right default and
  # turbo is loud. Flip it by hand when a GPU job is cooking the machine.
  boot.extraModulePackages = [ config.boot.kernelPackages.msi-ec ];
  boot.kernelModules = [ "msi_ec" ];

  # `fan-turbo` / `fan-auto` / `fan-status` — the only fan UI worth having here.
  # MControlCenter (nixpkgs `mcontrolcenter`) was tried and dropped: without
  # `ec_sys write_support=1` it cannot edit the fan curves, which is the only
  # thing it offered over these three lines, and we deliberately do not enable
  # ec_sys (see ./ec-baseline-16V4EMS2.108.txt).
  #
  # No sudo: the udev rule further down hands the three msi-ec attributes to the
  # wheel group. That grants wheel nothing it could not already get via sudo, and
  # touches only msi-ec's curated attributes -- never the raw EC.

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

  networking.hostName = "chris-msi";
  # NetworkManager pulls in ModemManager, which probes any USB-serial adapter
  # with AT commands the instant it appears — colliding with UART console
  # sessions (tio/minicom) and producing dropped keystrokes + high-bit garbage.
  # The exact adapter works fine under Windows/PuTTY and Ubuntu, which don't
  # probe it. No cellular modem on this laptop, so disable MM outright. (For a
  # surgical alternative, a udev rule tagging the adapter ENV{ID_MM_DEVICE_IGNORE}
  # would stop MM touching just that port.)
  systemd.services.ModemManager.enable = lib.mkForce false;

  # Dual-boot with Windows: Windows treats the RTC as local time, so match it here
  # instead of fighting it (otherwise the clock is off by the UTC offset after
  # switching OSes). The cleaner alternative is making Windows use UTC (the
  # `RealTimeIsUniversal` registry DWORD), but this matches your usual approach.
  time.hardwareClockInLocalTime = true;
  # xpadneo: out-of-tree driver for Xbox One/Series controllers over Bluetooth.
  # Adds rumble + battery reporting and disables BT ERTM (the Enhanced Re-
  # Transmission Mode Xbox pads choke on when pairing). Pairing keys land in
  # /var/lib/bluetooth, which is already a persist bind, so a paired controller
  # survives the impermanent-root wipe. (USB needs nothing — xpad is in-kernel.)
  hardware.xpadneo.enable = true;
  # Bluetooth pairing UI is GNOME's Settings → Bluetooth panel (gnome-bluetooth);
  # no separate applet/polkit service needed.

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
  #
  # Second rule: give the logged-in user access to Qualcomm boards in EDL/9008
  # mode (05c6:9008) so `qdl` can flash them without root. Rubik Pi 3 enumerates
  # here once switched into Emergency Download mode.
  # Third rule: let wheel drive the msi-ec fan knobs without sudo, so `fan-turbo`
  # and `fan-auto` are plain commands. MODE=/GROUP= do not apply to a platform
  # device's attribute files, so chgrp/chmod them directly — the same idiom the
  # intel-rapl energy_uj rule uses. Only these three curated attributes are opened
  # up; the raw EC is untouched, and wheel could already reach them via sudo.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x9a21", ATTR{power/control}="on"
    SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9008", MODE="0660", TAG+="uaccess"
    ACTION=="add|change", SUBSYSTEM=="platform", KERNEL=="msi-ec", RUN+="${pkgs.coreutils}/bin/chgrp wheel /sys/%p/shift_mode /sys/%p/fan_mode /sys/%p/cooler_boost", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/%p/shift_mode /sys/%p/fan_mode /sys/%p/cooler_boost"
  '';

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

  # The external monitor's own audio volume (DDC/CI VCP 0x62) is a gain stage
  # the audio stack CANNOT see. HDMI/DP sinks expose no ALSA volume control at
  # all, so PipeWire, every mixer and the codec pins all read a flat 0 dB while
  # the panel quietly halved everything on its way to the powered speakers on
  # its headphone jack -- it shipped at 50/100. Chased this through PipeWire,
  # the SOF DSP topology and legacy snd_hda_intel before finding it; if audio
  # is ever "quiet with everything at unity" again, check VCP 0x62 FIRST:
  #     ddcutil detect --brief && ddcutil getvcp 62
  # Pinned to full scale here; listening level is the speakers' own knob.
  hardware.i2c.enable = true;   # i2c-dev + udev rules -> /dev/i2c-*
  users.users.chris.extraGroups = [ "i2c" ];   # base set in modules/nixos/common.nix

  systemd.services.monitor-audio-full-scale = {
    description = "Pin the external monitor's DDC/CI audio volume to full scale";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    # DDC over a freshly-enumerated DP link is racy: the DRM connector can be up
    # before the panel answers on i2c. Retry, and never fail the boot over it.
    script = ''
      for i in $(seq 1 10); do
        if ${pkgs.ddcutil}/bin/ddcutil --model LU28R55 setvcp 62 100; then
          echo "monitor VCP 0x62 set to 100"; exit 0
        fi
        sleep 5
      done
      echo "monitor did not answer DDC/CI; left its volume alone" >&2
    '';
  };

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
    ddcutil           # monitor DDC/CI control (see monitor-audio-full-scale)
    # Fan control (msi-ec). See the msi_ec block near the top of this file.
    (writeShellScriptBin "fan-turbo" ''
      set -eu
      EC=/sys/devices/platform/msi-ec
      [ -d "$EC" ] || { echo "fan-turbo: msi-ec not loaded" >&2; exit 1; }
      echo turbo > "$EC/shift_mode"
      echo on    > "$EC/cooler_boost"
      echo "fans: turbo + cooler boost"
    '')
    (writeShellScriptBin "fan-auto" ''
      set -eu
      EC=/sys/devices/platform/msi-ec
      [ -d "$EC" ] || { echo "fan-auto: msi-ec not loaded" >&2; exit 1; }
      echo off     > "$EC/cooler_boost"
      echo comfort > "$EC/shift_mode"
      echo auto    > "$EC/fan_mode"
      echo "fans: stock (comfort + auto)"
    '')
    (writeShellScriptBin "fan-status" ''
      set -eu
      EC=/sys/devices/platform/msi-ec
      [ -d "$EC" ] || { echo "fan-status: msi-ec not loaded" >&2; exit 1; }
      printf 'shift_mode   %s\n' "$(cat "$EC/shift_mode")"
      printf 'fan_mode     %s\n' "$(cat "$EC/fan_mode")"
      printf 'cooler_boost %s\n' "$(cat "$EC/cooler_boost")"
      printf 'cpu          %s C, fan %s%%\n' \
        "$(cat "$EC/cpu/realtime_temperature")" "$(cat "$EC/cpu/realtime_fan_speed")"
      printf 'gpu          %s C, fan %s%%\n' \
        "$(cat "$EC/gpu/realtime_temperature")" "$(cat "$EC/gpu/realtime_fan_speed")"
      # Resolve the hwmon by NAME -- hwmonN numbering is not stable across boots.
      for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = msi_wmi_platform ] || continue
        printf 'rpm          %s\n' "$(cat "$h"/fan[123]_input | tr '\n' ' ')"
      done
    '')
    android-tools     # adb + fastboot
    qdl               # flash Qualcomm boards (Rubik Pi 3) over EDL/9008
    dnsutils          # nslookup, dig, host
    vulkan-tools      # vulkaninfo (VR GPU/encode diagnostics)
    # rebuild/secrets tooling
    sbctl             # Secure Boot key management (lanzaboote)
    sops age ssh-to-age  # edit/inspect sops secrets; derive age key from the SSH key
    nvtopPackages.nvidia # GPU utilization monitor (training/inference)
    tio               # serial terminal for UART console work (junkyard etc.)
    # VeraCrypt (GUI + CLI). A system package, not a flatpak/home one: mounting a
    # volume re-execs the binary under sudo (nixpkgs patches its binary search to
    # look in /run/wrappers/bin and /run/current-system/sw/bin) and mounts through
    # the setuid fusermount3 wrapper — both of which the flatpak sandbox blocks.
    # Unfree (TrueCrypt License 3.0 AND Apache-2.0); allowUnfree is already set in
    # modules/nixos/common.nix.
    veracrypt
    alvr              # SteamVR->Quest streaming, fallback VR path (opens its own LAN ports at runtime)
  ]);

  # See the comment in the original: keep in sync with home.stateVersion.
  system.stateVersion = "25.11";
}
