# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a **multi-host** Nix configuration for three personal machines, in one flake tracking **`nixos-unstable`** (home-manager follows it):

- **`chris-msi`** — NixOS on an MSI Creator 15 A11UE. Declarative disk via **disko**, **impermanent** btrfs root (`@` reset to empty every boot, previous kept as `@old`; durable `/persist`, `/home`, `/nix`, `/var/log`, `/var/lib/docker`), hibernation, Secure Boot.
- **`chris-lenovo`** — NixOS on a Lenovo ThinkPad X1 Carbon Gen 9 (i7-1185G7, Intel Iris Xe, **no dGPU**). Same impermanent btrfs-on-LUKS layout, but **NixOS-only** — disko wipes the whole 512GB NVMe. Hibernation and Secure Boot are **off** (the swapfile is still sized >= RAM so hibernation can be enabled later without repartitioning).
- **`chris-macbook`** — macOS (Apple Silicon MacBook Air) via **nix-darwin**. Nix installed with the **Determinate Systems** installer (it owns the daemon, so `nix.enable = false`); macOS itself is not declaratively installed.

None of them are part of the KastnerRG/krg-infra fleet.

## Commands

- **Apply (NixOS):** `sudo nixos-rebuild switch --flake .#chris-msi` (or `.#chris-lenovo`)
- **Apply (macOS):** `darwin-rebuild switch --flake .#chris-macbook`
- Both run the home-manager activation, which runs `depend install --prune` against `packages.yaml` — converging the non-Nix layer to the manifest on both hosts (see below).
- **Update inputs:** `nix flake update` (or a single input), then switch.
- **Validate without activating:** `nixos-rebuild build --flake .#chris-msi`, or `nix build .#darwinConfigurations.chris-macbook.system`, or `nix eval .#nixosConfigurations.chris-msi.config.system.build.toplevel.drvPath` (cheap eval). CI does this for both hosts (`.github/workflows/flake.yml`). Confirm a change builds before switching — and ALWAYS before a disk wipe.
- **Full reinstall:** `REBUILD.md` is the index → `REBUILD-MSI.md` (NixOS, disko wipes the 2TB drive; Windows on the other NVMe is untouched) and `REBUILD-MAC.md` (macOS bootstrap).
- **Preview non-Nix package changes:** `depend plan --config packages.yaml` (add `--prune` to also preview removals). `nixos-rebuild`/`darwin-rebuild` evaluation is the only validation — there is no separate test suite here.

## Repository layout

```
flake.nix                         mkNixosHost -> nixosConfigurations.{chris-msi,chris-lenovo} + darwinConfigurations.chris-macbook
hosts/
  chris-msi/default.nix        NixOS host module (imports its disko-config + ../../modules/nixos/*)
  chris-msi/disko-config.nix   declarative disk (btrfs-on-LUKS, the 2TB drive ONLY)
  chris-msi/hardware-configuration.nix   kernel modules / microcode only (disko owns disk entries)
  chris-lenovo/                   ThinkPad X1C9 host: hardware + quirks only (~85 lines)
  chris-macbook/default.nix       nix-darwin host module
modules/nixos/
  common.nix                      SHARED by every NixOS host: boot loader, nix settings/gc,
                                  the chris user, networking, fonts, audio, nix-ld, envfs
  desktop.nix                     SHARED: GNOME on GDM, geoclue, CUPS+Avahi, Bluetooth
  overlays.nix                    SHARED: package fixes (pipx, cantarell, envfs, gnome-shell, mutter, wivrn)
  impermanence / hibernation / secure-boot / backups   opt-in my.* features
home/
  common.nix                      cross-platform home-manager (shell stack, git, core CLIs, claude-backup) — BOTH hosts
  linux.nix                       Linux/desktop home (GNOME/flatpak/dconf/GTK/darkman) + Linux depend hook
  darwin.nix                      macOS home + the macOS depend hook
  claude-backup.nix               hourly ~/.claude snapshot to Nextcloud (systemd timer / launchd agent)
packages.yaml                     non-Nix packages, per-platform blocks, reconciled by depend
```

**Wiring.** `flake.nix` passes all inputs down via `specialArgs`. Each host's home is wired there: NixOS → `home/linux.nix`, darwin → `home/darwin.nix`; both import `home/common.nix`. `system.stateVersion` (per-host module) and `home.stateVersion` (`home/common.nix`) must generally not change.

## Package management — know the layer AND the platform

1. **System packages** → `environment.systemPackages` in `hosts/chris-msi/default.nix` (NixOS) — CLIs, drivers, system tools.
2. **Cross-platform user CLIs** → `home.packages` in `home/common.nix` (shared by both hosts: `gh`, `claude-code`, `uv`, `depend`).
3. **Host-specific GUI/desktop** → `home.packages` in `home/linux.nix` (vscode, android-studio, keepass, GNOME bits) or `home/darwin.nix` (currently minimal).
4. **Non-Nix packages** → `packages.yaml`, reconciled by `depend`. On Linux: Flatpaks, VSCode/browser extensions, pipx (blocks scoped `platform: linux`). On macOS: Homebrew `brew`/`cask` + Mac App Store `mas` (the `platform: osx` block).

**GUI app defaults.** Linux: Flatpak by default (sandboxing + vendor-fresh), `home.packages` only when open-source and Nix-integrated (vscode, android-studio, keepass). macOS: Homebrew casks via `packages.yaml` — **not** nix-darwin's `homebrew` module (see below).

## The `depend` activation hook (critical gotcha)

Both home configs pull the `depend` binary from the `dependency-manager` flake input (it is cross-platform now — the flake exposes `aarch64-darwin`) and run it from a `home.activation` hook on every switch. That hook runs with a **stripped PATH**, so every provider binary `depend` shells out to must be on the activation `PATH`:

Both hosts run `depend install --prune` (converge — remove installed-but-undeclared packages to match `packages.yaml`); they differ only in the providers and the `PATH`:
- **Linux** (`home/linux.nix`): prunes flatpak/vscode/pipx; `PATH` via `lib.makeBinPath [ pkgs.flatpak vscode pkgs.pipx ]`.
- **macOS** (`home/darwin.nix`): prunes brew/cask/mas; `PATH` prepends `/opt/homebrew/bin` (where `brew`/`mas` live). Homebrew is a prerequisite — depend shells out to `brew`, it does not build it.

If you add a `packages.yaml` provider that invokes a new external binary, add that binary to the relevant activation `PATH` or the activation silently fails to find it.

## `packages.yaml` schema (consumed by `depend`)

A top-level map of named blocks. Each has filter keys (`platform`, `architecture`) and provider sections. Providers in use:
- `flatpak:` (Linux) — keys are app IDs, `source: flathub`.
- `vscode:` (Linux) — extension IDs; the block uses `requires: [code]` to assert VSCode is present before applying.
- `pipx:` (Linux) — pip distribution name; `url:` points at a wheel/sdist.
- `zen:` / `firefox:` (Linux) — browser extensions via enterprise-policy files. **Keys are the addon ID** (quote IDs starting with `{`); `source:` is the AMO slug for the `.xpi` URL.
- `brew:` / `cask:` / `mas:` (macOS, `platform: osx`) — Homebrew formulae / casks / Mac App Store (numeric id). `brew` never runs as sudo; a `source:` with a slash is a tap.
- `dependencies: [<id>]` orders one package after another within the plan.

**Convergence/prune (both hosts):** depend's `--prune` removes installed-but-undeclared packages. A safety rail skips any provider that declares **zero** packages on the current platform — so an empty section (e.g. `brew:`/`cask:`/`mas:`) means depend leaves that provider untouched until you actually list things. This is intentionally why nix-darwin's `homebrew` module is NOT used: one `packages.yaml` drives the non-Nix layer on both machines.

## `my.*` feature modules (`modules/nixos/`, toggled in `hosts/chris-msi/default.nix`)

- `impermanence.nix` — btrfs root rollback in initrd: each boot `@` → `@old` (recoverable) and recreated EMPTY (a recursive delete first clears the subvolumes systemd nests under `@`). Plus the `/persist` bind list. Ordered after the LUKS device + `systemd-hibernate-resume.service`; reseeds `/usr/bin/env` for the systemd-258 empty-`/usr` PID1 freeze. **GOTCHA:** the rollback's `mount`/`btrfs` binaries must be in `boot.initrd.systemd.storePaths`. Because `/etc/shadow` is on the ephemeral root, **passwords are declarative**: `users.users.chris.hashedPasswordFile` (hash in `/persist`, not git) + `users.mutableUsers = false`.
- `hibernation.nix` — lid matrix (docked→`ignore`, AC/battery→suspend-then-hibernate); resume from the NoCoW `/swap/swapfile` (`resume_offset` is install-specific — re-derive on reinstall).
- `secure-boot.nix` — lanzaboote. **Two-phase**: `my.secureBoot.enable = false` for the first install, then `sbctl create-keys` → enable → `sbctl enroll-keys --microsoft` → re-enroll TPM2 bound to the measured PCRs.
- `backups.nix` — restic → Nextcloud over rclone WebDAV (`~/Repos`). **Gated** on the sops secrets (`my.backups.enable`).

The desktop is **GNOME on Wayland** via **GDM** (`services.desktopManager.gnome` + `services.displayManager.gdm` in the host module). GNOME owns power management (low-battery warnings + auto-suspend), lid handling, gnome-keyring (Secret Service), and accessibility (Large Text + fractional scaling in Settings). Desktop tweaks are home-manager: `home/linux.nix` sets dconf (extensions, dash-to-dock, fractional scaling, fonts), GTK, and **darkman** for sunrise/sunset light↔dark. *(The repo previously ran a Hyprland-only session with a greetd/ReGreet greeter; that was removed in favor of GNOME — see git history if resurrecting any of it.)*

Secrets are **sops-nix** (`.sops.yaml`, `secrets/`); the age identity is derived (`ssh-to-age`) from the SSH key synced via Nextcloud, so every personal machine decrypts and a reinstall doesn't lose it. **Disk:** `hosts/chris-msi/disko-config.nix` is btrfs-on-LUKS, **the 2TB drive ONLY** — Windows lives on a separate, never-referenced NVMe.

**Hardware notes** (in `hosts/chris-msi/default.nix`): NVIDIA RTX 3060 + Intel iGPU using PRIME render-offload; LUKS root with TPM2 auto-unlock (passphrase fallback); GNOME on Wayland (GDM greeter); PipeWire with HDA power-saving disabled to avoid clipped playback onsets.

## Don't take the running environment down

This is the user's daily-driver desktop, not a lab machine. A diagnostic that
stops a service is **not** free and is rarely worth it — prefer read-only
inspection (`wpctl`/`pw-cli`/`pw-dump`, `amixer`, `/proc/asound`, `/sys`) and,
when you must change live state, the narrowest reversible knob.

**Never stop `pipewire-pulse` (or `pipewire`/`wireplumber`) to free a device.**
libpulse does not reconnect to a restarted PulseAudio server, so stopping it
permanently detaches *every* running client until each is restarted:
gnome-shell's volume slider and `gsd-media-keys` (spawned by gnome-session, so
there is no unit to restart and `Alt+F2`+`r` is X11-only), plus Zen, Slack,
Signal and Zoom. Restarting the service does not bring them back — only a
logout does. Note that native PipeWire clients like `pw-play` reconnect fine,
so audio can look healthy from the CLI while the whole desktop is silent;
check `wpctl status` **Clients**/**Streams** for missing apps before declaring
things fixed. To free an ALSA device, flip the card profile instead
(`wpctl set-profile <dev> 0`, restore after) — the Pulse server stays up.

General rules for this machine:
- Prefer changes that take effect on the next boot/login the user chooses over
  ones that interrupt the session now. The user reboots at their convenience.
- Before anything disruptive, say what will break and get an explicit go-ahead.
  "It's reversible" is not the same as "it's non-disruptive".
- Always restore state on `INT`/`TERM`, not just `EXIT` — a script the user
  Ctrl+Cs must leave the system as it found it.
- Never hardcode PipeWire node IDs in a script; they are renumbered on every
  daemon restart, and a stale ID silently targets an unrelated node (a `pw-play
  --target` at a former sink id can end up aimed at a microphone). Resolve by
  node name, or use the default sink.

## CI

`.github/workflows/flake.yml` validates both hosts on every push/PR: the NixOS host is evaluated (a full system build is multi-GB — too big for hosted runners), the darwin host is built on a macOS runner. The darwin job requires the `dependency-manager` darwin output to be published + locked here.
