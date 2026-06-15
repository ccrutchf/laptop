# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is a **multi-host** Nix configuration for two personal machines, in one flake tracking **`nixos-unstable`** (home-manager follows it):

- **`chris-laptop`** — NixOS on an MSI Creator 15 A11UE. Declarative disk via **disko**, **impermanent** btrfs root (`@` reset to empty every boot, previous kept as `@old`; durable `/persist`, `/home`, `/nix`, `/var/log`, `/var/lib/docker`), hibernation, Secure Boot.
- **`chris-macbook`** — macOS (Apple Silicon MacBook Air) via **nix-darwin**. Nix installed with the **Determinate Systems** installer (it owns the daemon, so `nix.enable = false`); macOS itself is not declaratively installed.

Neither is part of the KastnerRG/krg-infra fleet.

## Commands

- **Apply (NixOS):** `sudo nixos-rebuild switch --flake .#chris-laptop`
- **Apply (macOS):** `darwin-rebuild switch --flake .#chris-macbook`
- Both run the home-manager activation, which runs `depend install --prune` against `packages.yaml` — converging the non-Nix layer to the manifest on both hosts (see below).
- **Update inputs:** `nix flake update` (or a single input), then switch.
- **Validate without activating:** `nixos-rebuild build --flake .#chris-laptop`, or `nix build .#darwinConfigurations.chris-macbook.system`, or `nix eval .#nixosConfigurations.chris-laptop.config.system.build.toplevel.drvPath` (cheap eval). CI does this for both hosts (`.github/workflows/flake.yml`). Confirm a change builds before switching — and ALWAYS before a disk wipe.
- **Full reinstall:** `REBUILD.md` is the index → `REBUILD-NIXOS.md` (NixOS, disko wipes the 2TB drive; Windows on the other NVMe is untouched) and `REBUILD-MAC.md` (macOS bootstrap).
- **Preview non-Nix package changes:** `depend plan --config packages.yaml` (add `--prune` to also preview removals). `nixos-rebuild`/`darwin-rebuild` evaluation is the only validation — there is no separate test suite here.

## Repository layout

```
flake.nix                         nixosConfigurations.chris-laptop + darwinConfigurations.chris-macbook
hosts/
  chris-laptop/default.nix        NixOS host module (imports its disko-config + ../../modules/nixos/*)
  chris-laptop/disko-config.nix   declarative disk (btrfs-on-LUKS, the 2TB drive ONLY)
  chris-laptop/hardware-configuration.nix   kernel modules / microcode only (disko owns disk entries)
  chris-macbook/default.nix       nix-darwin host module
modules/nixos/                    NixOS feature modules: impermanence, hibernation, secure-boot, backups, hyprland
home/
  common.nix                      cross-platform home-manager (shell stack, git, core CLIs, claude-backup) — BOTH hosts
  linux.nix                       Linux/desktop home (GNOME/Hyprland/flatpak/dconf/GTK/darkman) + Linux depend hook
  darwin.nix                      macOS home + the macOS depend hook
  hyprland.nix                    Hyprland session config (imported by home/linux.nix)
  claude-backup.nix               hourly ~/.claude snapshot to Nextcloud (systemd timer / launchd agent)
packages.yaml                     non-Nix packages, per-platform blocks, reconciled by depend
```

**Wiring.** `flake.nix` passes all inputs down via `specialArgs`. Each host's home is wired there: NixOS → `home/linux.nix`, darwin → `home/darwin.nix`; both import `home/common.nix`. `system.stateVersion` (per-host module) and `home.stateVersion` (`home/common.nix`) must generally not change.

## Package management — know the layer AND the platform

1. **System packages** → `environment.systemPackages` in `hosts/chris-laptop/default.nix` (NixOS) — CLIs, drivers, system tools.
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

## `my.*` feature modules (`modules/nixos/`, toggled in `hosts/chris-laptop/default.nix`)

- `impermanence.nix` — btrfs root rollback in initrd: each boot `@` → `@old` (recoverable) and recreated EMPTY (a recursive delete first clears the subvolumes systemd nests under `@`). Plus the `/persist` bind list. Ordered after the LUKS device + `systemd-hibernate-resume.service`; reseeds `/usr/bin/env` for the systemd-258 empty-`/usr` PID1 freeze. **GOTCHA:** the rollback's `mount`/`btrfs` binaries must be in `boot.initrd.systemd.storePaths`. Because `/etc/shadow` is on the ephemeral root, **passwords are declarative**: `users.users.chris.hashedPasswordFile` (hash in `/persist`, not git) + `users.mutableUsers = false`.
- `hibernation.nix` — lid matrix (docked→`ignore`, AC/battery→suspend-then-hibernate); resume from the NoCoW `/swap/swapfile` (`resume_offset` is install-specific — re-derive on reinstall).
- `secure-boot.nix` — lanzaboote. **Two-phase**: `my.secureBoot.enable = false` for the first install, then `sbctl create-keys` → enable → `sbctl enroll-keys --microsoft` → re-enroll TPM2 bound to the measured PCRs.
- `backups.nix` — restic → Nextcloud over rclone WebDAV (`~/Repos`). **Gated** on the sops secrets (`my.backups.enable`).
- `hyprland.nix` — the system half of the Hyprland session (greeter is greetd + ReGreet inside a Hyprland instance; see the greetd block in the host module).

Secrets are **sops-nix** (`.sops.yaml`, `secrets/`); the age identity is derived (`ssh-to-age`) from the SSH key synced via Nextcloud, so every personal machine decrypts and a reinstall doesn't lose it. **Disk:** `hosts/chris-laptop/disko-config.nix` is btrfs-on-LUKS, **the 2TB drive ONLY** — Windows lives on a separate, never-referenced NVMe.

**Hardware notes** (in `hosts/chris-laptop/default.nix`): NVIDIA RTX 3060 + Intel iGPU using PRIME render-offload; LUKS root with TPM2 auto-unlock (passphrase fallback); Hyprland on Wayland (GNOME removed); PipeWire with HDA power-saving disabled to avoid clipped playback onsets.

## CI

`.github/workflows/flake.yml` validates both hosts on every push/PR: the NixOS host is evaluated (a full system build is multi-GB — too big for hosted runners), the darwin host is built on a macOS runner. The darwin job requires the `dependency-manager` darwin output to be published + locked here.
