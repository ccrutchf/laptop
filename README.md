# laptop

Multi-host Nix configuration for two personal machines, in one **flake** tracking
**`nixos-unstable`**, with [home-manager](https://github.com/nix-community/home-manager)
for the user environment and [dependency-manager](https://github.com/ccrutchf/dependency-manager)
(`depend`) for packages with no good Nix path:

- **`chris-laptop`** — NixOS (MSI Creator 15 A11UE). Declarative disk via
  [disko](https://github.com/nix-community/disko); **impermanent** btrfs root (reset to
  empty every boot) with durable `/persist`, `/home`, `/nix`, `/var/log`, `/var/lib/docker`;
  hibernation; Secure Boot.
- **`chris-macbook`** — macOS (Apple Silicon) via
  [nix-darwin](https://github.com/nix-darwin/nix-darwin), Nix installed with the
  [Determinate Systems](https://github.com/DeterminateSystems/nix-installer) installer.

Personal machines; not part of the KastnerRG/krg-infra fleet.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Entry point: `nixosConfigurations.chris-laptop` + `darwinConfigurations.chris-macbook` + inputs. |
| `hosts/chris-laptop/` | NixOS host module (`default.nix`), `disko-config.nix`, `hardware-configuration.nix`. |
| `hosts/chris-macbook/` | nix-darwin host module (`default.nix`). |
| `modules/nixos/` | NixOS feature modules: `impermanence`, `hibernation`, `secure-boot`, `backups`, `hyprland`. |
| `home/common.nix` | Cross-platform home-manager (shell stack, git, core CLIs) — both hosts. |
| `home/linux.nix` / `home/darwin.nix` | Per-host home (imports `common.nix`); each runs `depend` on switch. |
| `home/hyprland.nix` | Hyprland session config (imported by `home/linux.nix`). |
| `packages.yaml` | Non-Nix packages, per-platform blocks, reconciled by `depend`. |
| `.sops.yaml`, `secrets/` | sops-nix encrypted secrets (age via the Nextcloud-synced SSH key). |
| `REBUILD.md` | Index → `REBUILD-NIXOS.md` (NixOS) and `REBUILD-MAC.md` (macOS) reinstall runbooks. |
| `CLAUDE.md` | Architecture details and gotchas. |

## Everyday use

```sh
# NixOS
sudo nixos-rebuild switch --flake .#chris-laptop
# macOS
darwin-rebuild switch --flake .#chris-macbook

nix flake update                                   # bump pinned inputs, then switch
```

Switching also runs `depend` against `packages.yaml` (Linux: `depend install`; macOS:
`depend install --prune`, which converges Homebrew to the manifest). Preview without applying:

```sh
depend plan --config packages.yaml          # add --prune to also preview removals
```

Full reinstalls ([`REBUILD.md`](REBUILD.md) indexes both): [`REBUILD-NIXOS.md`](REBUILD-NIXOS.md)
(NixOS, destructive disk wipe) and [`REBUILD-MAC.md`](REBUILD-MAC.md) (macOS bootstrap).

## Adding packages

- **System tools / drivers (NixOS)** → `environment.systemPackages` in `hosts/chris-laptop/default.nix`.
- **Cross-platform user CLIs** → `home.packages` in `home/common.nix` (both machines).
- **Host-specific GUI apps** → `home.packages` in `home/linux.nix` or `home/darwin.nix`.
- **Non-Nix** → `packages.yaml`: Flatpaks / VSCode+browser extensions / pipx (`platform: linux`);
  Homebrew `brew`/`cask`/`mas` (`platform: osx`).
- **Language toolchains** → per-project flake devshells via direnv, not the system profile.

See [`CLAUDE.md`](CLAUDE.md) for architecture and gotchas (notably: a new `depend` provider
binary must also be added to the activation `PATH` in the relevant `home/*.nix`).
