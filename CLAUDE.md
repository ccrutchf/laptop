# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the NixOS system configuration for a single machine (`chris-laptop`). It is **not a flake** — it relies on `nix-channel` for nixpkgs and fetches home-manager via `fetchTarball`.

## Commands

- **Apply config:** `sudo nixos-rebuild switch` — builds and activates. This also runs the home-manager activation, which in turn runs `depend install` against `packages.yaml` (see below).
- **Apply + upgrade channels:** `sudo nixos-rebuild switch --upgrade`
- **Validate without activating:** `sudo nixos-rebuild dry-build` (evaluate only) or `nixos-rebuild build` (build the toplevel, no switch). Use these to check that a change evaluates before switching.
- **Initial setup on a fresh machine:** `./deploy.sh` — symlinks `/etc/nixos` to this repo (backing up any existing dir) and runs `nixos-rebuild switch`. Idempotent; refuses to overwrite a symlink pointing elsewhere.
- **Preview non-Nix package changes:** `depend plan --config packages.yaml` shows the resolved install plan for `packages.yaml` without applying it. There is no test suite or linter in this repo — `nixos-rebuild`'s evaluation is the only validation.

## Architecture

**Entry point and module wiring.** `configuration.nix` is the NixOS entry point. It fetches home-manager (tracking `master`) via `fetchTarball`, imports it as a NixOS module, and wires the user config with `home-manager.users.chris = import ./home.nix`. `hardware-configuration.nix` is machine-generated (LUKS device UUID, filesystems) and should not be hand-edited casually. `system.stateVersion` (configuration.nix) and `home.stateVersion` (home.nix) must stay in sync and generally must not change.

**Three layers of package management** — know which layer a package belongs to before adding it:
1. **System packages** → `environment.systemPackages` in `configuration.nix` (CLIs, drivers, system tools).
2. **User / GUI packages** → `home.packages` in `home.nix` (home-manager, e.g. vscode, android-studio, keepass).
3. **Non-Nix packages** → `packages.yaml`, reconciled by `dependency-manager` (the `depend` binary). This covers Flatpaks, VSCode extensions, pipx packages, and browser extensions — things with no good nixpkgs path or that the user wants from upstream.

**The `depend` activation hook (critical gotcha).** `home.nix` pulls the `depend` binary from `getFlake "github:ccrutchf/dependency-manager"` and runs `depend install --config packages.yaml` from a `home.activation` hook on every `switch`. That hook runs inside a systemd unit with a **stripped PATH**, so every provider binary `depend` shells out to (currently `flatpak`, `vscode-fhs`, `pipx`) must be added explicitly to the activation's `lib.makeBinPath [ ... ]`. If you add a `packages.yaml` provider that invokes a new external binary, you must also add that binary there or the activation will silently fail to find it.

**`packages.yaml` schema** (consumed by `depend`): a top-level map of named blocks. Each block has filter keys (`platform`, `architecture`) and provider sections. Notable providers in use here:
- `flatpak:` — keys are app IDs, `source: flathub`.
- `vscode:` — keys are extension IDs; the block uses `requires: [code]` to assert VSCode (installed via Nix) is present before applying.
- `pipx:` — keys are the pip distribution name; `url:` points at a wheel/sdist.
- `zen:` / `firefox:` — browser extensions installed via enterprise-policy files. **Keys are the addon ID** (quote IDs that start with `{`, e.g. Bitwarden's GUID, or YAML parses them as a flow-map), and `source:` is the AMO slug used to build the `.xpi` URL.
- `dependencies: [<id>]` orders one package after another within the plan (e.g. Zen extensions depend on `app.zen_browser.zen` so the policy is written after the flatpak's install dir exists).

**`warp-terminal.nix`** is a local `overrideAttrs` of the nixpkgs `warp-terminal`, pinning a newer upstream stable release than the channel ships. The file header documents the version/hash bump procedure. It is consumed in `home.nix` via `pkgs.callPackage ./warp-terminal.nix { }`.

**Hardware notes** (in `configuration.nix`): NVIDIA RTX 3060 + Intel iGPU using PRIME render-offload (iGPU drives the display, `nvidia-offload` wrapper for the dGPU); LUKS root with TPM2 auto-unlock (passphrase fallback); GNOME on Wayland; audio is PipeWire with HDA power-saving disabled (`boot.extraModprobeConfig`) to avoid clipped playback onsets.
