# laptop

NixOS system configuration for `chris-laptop`.

This is a channel-based (non-flake) NixOS config that uses [home-manager](https://github.com/nix-community/home-manager) for the user environment and [dependency-manager](https://github.com/ccrutchf/dependency-manager) (`depend`) to reconcile packages that don't have a good Nix path (Flatpaks, VSCode/browser extensions, pipx).

## Layout

| File | Purpose |
| --- | --- |
| `configuration.nix` | System config and entry point; imports home-manager and `home.nix`. |
| `hardware-configuration.nix` | Machine-generated hardware scan (filesystems, LUKS UUID). |
| `home.nix` | home-manager user config; also runs `depend` on every switch. |
| `packages.yaml` | Declarative list of non-Nix packages, applied by `depend`. |
| `warp-terminal.nix` | Local override pinning a newer Warp Terminal release. |
| `deploy.sh` | First-time setup: links `/etc/nixos` to this repo and rebuilds. |

## Setup

On a fresh machine, clone the repo and run:

```sh
./deploy.sh
```

This symlinks `/etc/nixos` to this checkout (backing up any existing config) and runs `nixos-rebuild switch`. It is safe to re-run.

## Everyday use

```sh
sudo nixos-rebuild switch              # apply changes
sudo nixos-rebuild switch --upgrade    # apply + bump channels
sudo nixos-rebuild dry-build           # evaluate without applying
```

Switching also runs `depend install --config packages.yaml` automatically, so Flatpaks and extensions stay in sync. To preview what `depend` would do without applying:

```sh
depend plan --config packages.yaml
```

## Adding packages

Pick the right layer:

- **System tools / drivers** → `environment.systemPackages` in `configuration.nix`.
- **User & GUI apps** → `home.packages` in `home.nix`.
- **Flatpaks, VSCode/browser extensions, pipx** → `packages.yaml`.

See `CLAUDE.md` for the architecture details and gotchas (notably: any new `depend` provider binary must also be added to the activation `PATH` in `home.nix`).
