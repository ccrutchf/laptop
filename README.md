# laptop

NixOS system configuration for `chris-laptop` (an MSI Creator 15 A11UE). A **flake**
tracking **`nixos-unstable`**, with [home-manager](https://github.com/nix-community/home-manager)
for the user environment and [dependency-manager](https://github.com/ccrutchf/dependency-manager)
(`depend`) for packages with no good Nix path (Flatpaks, VSCode/browser extensions, pipx).

The disk layout is declarative via [disko](https://github.com/nix-community/disko), and
the root is **impermanent** — a btrfs `@` subvolume reset to empty every boot, with durable
`/persist`, `/home`, `/nix`, `/var/log`, and `/var/lib/docker`. Personal machine; not part
of the KastnerRG/krg-infra fleet.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Entry point: `nixosConfigurations.chris-laptop` + inputs (nixpkgs, home-manager, disko, impermanence, lanzaboote, sops-nix, …). |
| `configuration.nix` | Host module; imports the below and sets the `my.*` feature toggles. |
| `disko-config.nix` | Declarative disk layout (btrfs-on-LUKS, the 2TB drive only). |
| `hardware-configuration.nix` | Kernel modules / microcode only — disko owns the disk entries. |
| `modules/` | `impermanence`, `hibernation`, `secure-boot`, `backups`. |
| `home.nix` | home-manager user config; runs `depend` on every switch. |
| `packages.yaml` | Non-Nix packages, reconciled by `depend`. |
| `.sops.yaml`, `secrets/` | sops-nix encrypted secrets (age via the Nextcloud-synced SSH key). |
| `REBUILD.md` | From-scratch (destructive) reinstall + post-install runbook. |
| `CLAUDE.md` | Architecture details and gotchas. |

## Everyday use

```sh
sudo nixos-rebuild switch --flake .#chris-laptop   # apply changes
nix flake update                                   # bump pinned inputs, then switch
nixos-rebuild build --flake .#chris-laptop         # evaluate/build without applying
```

Switching also runs `depend install --config packages.yaml`, so Flatpaks and extensions
stay in sync. Preview without applying:

```sh
depend plan --config packages.yaml
```

A full reinstall (disk wipe) lives in [`REBUILD.md`](REBUILD.md).

## Adding packages

- **System tools / drivers** → `environment.systemPackages` in `configuration.nix`.
- **User & GUI apps** → `home.packages` in `home.nix`.
- **Flatpaks, VSCode/browser extensions, pipx** → `packages.yaml`.
- **Language toolchains (Rust, Flutter, Node, …)** → per-project flake devshells via direnv, not the system profile.

See [`CLAUDE.md`](CLAUDE.md) for architecture and gotchas (notably: a new `depend` provider
binary must also be added to the activation `PATH` in `home.nix`).
