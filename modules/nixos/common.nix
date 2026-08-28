# Machine-agnostic NixOS config shared by every Linux host in this flake: boot
# loader, nix daemon settings/gc, the chris user, networking, fonts, audio, the
# non-FHS escape hatches (nix-ld + envfs) and the base tooling. Anything that
# depends on a specific machine's hardware or peripherals belongs in that host's
# module instead; anything GNOME/desktop-shaped belongs in ./desktop.nix.
#
# NOTE: users.users.chris.extraGroups here is the BASE set. A host adds its own
# (e.g. "i2c" alongside hardware.i2c.enable) — the lists merge.
{ config, lib, pkgs, inputs, ... }:

{
  # Boot loader. systemd-boot by default; modules/secure-boot.nix replaces it with
  # lanzaboote (signed) once my.secureBoot.enable = true.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd-stage1 initrd: TPM2 auto-unlock + the impermanence rollback both need it.
  boot.initrd.systemd.enable = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.networkmanager.enable = true;
  # openconnect plugin: AnyConnect VPN type in GNOME Settings (UCSD vpn.ucsd.edu).
  networking.networkmanager.plugins = with pkgs; [ networkmanager-openconnect ];

  time.timeZone = "America/Los_Angeles";

  # Was commented out (defaulting to the C locale). Set it explicitly.
  i18n.defaultLocale = "en_US.UTF-8";

  services.flatpak.enable = true;

  # Firmware updates via LVFS (SSD/Thunderbolt/peripherals; MSI BIOS coverage is thin).
  services.fwupd.enable = true;

  # fwupd-refresh.service (the LVFS metadata timer) runs headless as the
  # `fwupd-refresh` system user, which has no login session — so polkit scores it
  # as "any" and the refresh-remote action defaults to auth_admin, failing with
  # "Failed to obtain auth". Upstream fwupd ships a JS rule granting this user a
  # pass, but NixOS's polkit only reads /etc/polkit-1/rules.d + polkit's own dir,
  # never fwupd's package dir, so that rule never loads. Re-add it here.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if ((action.id == "org.freedesktop.fwupd.refresh-remote" ||
           action.id == "org.freedesktop.fwupd.get-remotes" ||
           action.id == "org.freedesktop.fwupd.update-metadata") &&
          subject.user == "fwupd-refresh") {
        return polkit.Result.YES;
      }
    });
  '';

  # Periodic SSD TRIM (carried forward, now explicit) + btrfs scrub (bit-rot scan).
  services.fstrim.enable = true;
  services.btrfs.autoScrub = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/" ];   # one btrfs fs; scrubbing any subvol scrubs the device
  };

  nixpkgs.config.allowUnfree = true;

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

  fonts = {
    # ubuntu-classic ships the Ubuntu / Ubuntu Mono families; Noto gives broad
    # Unicode + a real serif; liberation covers the Arial/Times/Courier metric-
    # compatible aliases documents expect; JetBrainsMono Nerd Font is the mono
    # default below (terminal/VSCode) and carries glyphs.
    packages = with pkgs; [
      ubuntu-classic
      noto-fonts
      noto-fonts-color-emoji
      liberation_ttf
      nerd-fonts.jetbrains-mono
    ];

    fontconfig = {
      # The bare NixOS fallback is DejaVu — high-contrast and crunchy, and it's
      # what non-GTK apps reach for with no defaultFonts set. Pin the smoother
      # Ubuntu family as the sans default and JetBrainsMono Nerd Font for mono
      # (consistent with the terminal/Waybar and carries glyphs).
      defaultFonts = {
        sansSerif = [ "Ubuntu" "Noto Sans" ];
        serif     = [ "Noto Serif" ];
        monospace = [ "JetBrainsMono Nerd Font" "Ubuntu Mono" ];
        emoji     = [ "Noto Color Emoji" ];
      };
      # GNOME fractional scaling (org/gnome/mutter experimental-features in
      # home/linux.nix) rasterizes then downscales, so LCD subpixel order no
      # longer aligns with the panel — keep grayscale AA + slight hinting, NOT
      # rgb subpixel (which fringes here).
      antialias = true;
      hinting = { enable = true; style = "slight"; };
      subpixel.rgba = "none";
    };
  };

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
  # zsh is the interactive login shell (see home.nix for the zsh/atuin/starship
  # stack) — chosen over fish to keep POSIX muscle memory intact for tech-support
  # work on other people's machines, and to match the Mac. System-level enable
  # registers it in /etc/shells; the per-user config lives in home-manager.
  programs.zsh.enable = true;

  users.mutableUsers = false;
  users.users.chris = {
    isNormalUser = true;
    hashedPasswordFile = "/persist/passwd/chris";
    shell = pkgs.zsh;
    # dialout = serial/UART console access (junkyard UART work, /dev/ttyUSB*).
    extraGroups = [ "wheel" "docker" "dialout" "input" "tty" "uucp" ];
  };
  # No direct root login; admin via sudo (chris in wheel).
  users.users.root.hashedPassword = "!";

  virtualisation.docker.enable = true;

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

  networking.firewall.enable = true;
}
