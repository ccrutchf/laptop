# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the NixOS system configuration for a single machine (`chris-laptop`, an MSI Creator 15 A11UE). It **is a flake** (`flake.nix`) tracking **`nixos-unstable`** (home-manager follows it). The disk layout is declarative via **disko** (`disko-config.nix`), and the root is **impermanent** — a btrfs `@` subvolume rolled back to an empty `@blank` snapshot every boot, with durable `/persist`, `/home`, `/nix`, `/var/log`, and `/var/lib/docker` subvolumes. It is a personal machine and is **not** part of the KastnerRG/krg-infra fleet.

## Commands

- **Apply config:** `sudo nixos-rebuild switch --flake .#chris-laptop` — builds and activates. This also runs the home-manager activation, which in turn runs `depend install` against `packages.yaml` (see below).
- **Update inputs:** `nix flake update` (or `nix flake update nixpkgs`), then switch.
- **Validate without activating:** `nixos-rebuild build --flake .#chris-laptop` (build the toplevel, no switch) or `nix flake check`. Confirm a change builds before switching — and ALWAYS before a disk wipe.
- **Disk layout (DESTRUCTIVE) + full reinstall:** see `REBUILD.md` (disko wipes the 2TB drive; Windows on the other NVMe is untouched).
- **Preview non-Nix package changes:** `depend plan --config packages.yaml` shows the resolved install plan for `packages.yaml` without applying it. There is no test suite or linter in this repo — `nixos-rebuild`'s evaluation is the only validation.

## Architecture

**Entry point and module wiring.** `flake.nix` is the entry point: it defines `nixosConfigurations.chris-laptop` from `nixpkgs` (unstable) and pulls in home-manager, disko, impermanence, lanzaboote, sops-nix, and the user's `dependency-manager` as inputs. `configuration.nix` is the host module — it imports `hardware-configuration.nix`, `disko-config.nix`, and `modules/*.nix`, and sets the `my.*` feature toggles. home-manager is wired in `flake.nix` (`home-manager.users.chris = import ./home.nix`). **disko owns the disk entries** (`fileSystems`/`luks`/`swapDevices`), so `hardware-configuration.nix` keeps only the kernel-module/microcode lines. `system.stateVersion` (configuration.nix) and `home.stateVersion` (home.nix) must stay in sync and generally must not change.

**Three layers of package management** — know which layer a package belongs to before adding it:
1. **System packages** → `environment.systemPackages` in `configuration.nix` (CLIs, drivers, system tools).
2. **User / GUI packages** → `home.packages` in `home.nix` (home-manager, e.g. vscode, android-studio, keepass).
3. **Non-Nix packages** → `packages.yaml`, reconciled by `dependency-manager` (the `depend` binary). This covers Flatpaks, VSCode extensions, pipx packages, and browser extensions — things with no good nixpkgs path or that the user wants from upstream.

**The `depend` activation hook (critical gotcha).** `home.nix` pulls the `depend` binary from the `dependency-manager` flake input (was `builtins.getFlake`, which is illegal in a flake's pure eval) and runs `depend install --config packages.yaml` from a `home.activation` hook on every `switch`. That hook runs inside a systemd unit with a **stripped PATH**, so every provider binary `depend` shells out to (currently `flatpak`, `vscode-fhs`, `pipx`) must be added explicitly to the activation's `lib.makeBinPath [ ... ]`. If you add a `packages.yaml` provider that invokes a new external binary, you must also add that binary there or the activation will silently fail to find it.

**`packages.yaml` schema** (consumed by `depend`): a top-level map of named blocks. Each block has filter keys (`platform`, `architecture`) and provider sections. Notable providers in use here:
- `flatpak:` — keys are app IDs, `source: flathub`.
- `vscode:` — keys are extension IDs; the block uses `requires: [code]` to assert VSCode (installed via Nix) is present before applying.
- `pipx:` — keys are the pip distribution name; `url:` points at a wheel/sdist.
- `zen:` / `firefox:` — browser extensions installed via enterprise-policy files. **Keys are the addon ID** (quote IDs that start with `{`, e.g. Bitwarden's GUID, or YAML parses them as a flow-map), and `source:` is the AMO slug used to build the `.xpi` URL.
- `dependencies: [<id>]` orders one package after another within the plan (e.g. Zen extensions depend on `app.zen_browser.zen` so the policy is written after the flatpak's install dir exists).
**`my.*` feature modules** (`modules/`, toggled in `configuration.nix`):
- `impermanence.nix` — btrfs root rollback in initrd: each boot `@` is moved to `@old` (recoverable) and recreated EMPTY via `btrfs subvolume create` (a recursive delete first clears the subvolumes systemd nests under `@`: `var/lib/{machines,portables}`, `/srv`, `/tmp`, `/var/tmp`). Plus the `/persist` bind list. Ordered after the LUKS device + `systemd-hibernate-resume.service` (so a resume isn't wiped); reseeds `/usr/bin/env` for the systemd-258 empty-`/usr` PID1 freeze. **GOTCHA:** the rollback's `mount`/`btrfs` binaries must be in `boot.initrd.systemd.storePaths` — the service `path` alone leaves them off the initrd (`mount: command not found`). Because `/etc/shadow` is on the ephemeral root, **passwords are declarative**: `users.users.chris.hashedPasswordFile` (hash in `/persist`, not git) + `users.mutableUsers = false`.
- `hibernation.nix` — lid matrix (docked→`ignore`=clamshell, AC/battery→suspend-then-hibernate); resume from the NoCoW `/swap/swapfile` (`resume_offset` is install-specific, from `btrfs inspect-internal map-swapfile` — re-derive on reinstall).
- `secure-boot.nix` — lanzaboote. **Two-phase**: keep `my.secureBoot.enable = false` for the first install, then `sbctl create-keys` → enable → `sbctl enroll-keys --microsoft` (MS keys so Windows still boots) → re-enroll TPM2 bound to the measured PCRs.
- `backups.nix` — restic → Nextcloud over rclone WebDAV (`~/Repos`). **Gated** on the sops secrets existing (`my.backups.enable`).

Secrets are **sops-nix** (`.sops.yaml`, `secrets/`); the age identity is derived (`ssh-to-age`) from the SSH key synced via Nextcloud, so every personal machine decrypts and a reinstall doesn't lose it. **Disk:** `disko-config.nix` is btrfs-on-LUKS, **the 2TB drive ONLY** — Windows lives on a separate, never-referenced NVMe.

**Hardware notes** (in `configuration.nix`): NVIDIA RTX 3060 + Intel iGPU using PRIME render-offload (iGPU drives the display, `nvidia-offload` wrapper for the dGPU); LUKS root with TPM2 auto-unlock (passphrase fallback); GNOME on Wayland; audio is PipeWire with HDA power-saving disabled (`boot.extraModprobeConfig`) to avoid clipped playback onsets.
