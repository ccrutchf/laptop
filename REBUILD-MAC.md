# chris-macbook rebuild runbook

From-scratch setup of the MacBook Air (Apple Silicon) after a macOS reinstall.
Unlike the NixOS host there is no declarative disk/OS step — macOS installs itself;
nix-darwin takes over once Nix is present. The host module is
[`hosts/chris-macbook/default.nix`](hosts/chris-macbook/default.nix); the user
environment is [`home/darwin.nix`](home/darwin.nix) (+ shared `home/common.nix`).

## 0. Before the wipe
- [ ] **Sync all git repos** — uncommitted/stashed work, local-only branches.
- [ ] **Confirm the SSH key is in Nextcloud** — `~/.ssh/id_ed25519` is the
      sops/age identity *and* the git commit-signing key, shared with every
      personal machine.
- [ ] Note anything installed by hand you want to keep (it will be re-approved via
      `packages.yaml`, not migrated).

## 1. Reinstall macOS
- [ ] *Erase All Content and Settings* (or Recovery → reinstall). Create the
      account as **`chris`** (home `/Users/chris`) and set the machine name to
      **`chris-macbook`** — nix-darwin pins it, but matching at setup avoids churn.
- [ ] Sign into iCloud; install Xcode + Command Line Tools (`xcode-select --install`)
      — the iOS toolchain (cocoapods/fastlane/swiftlint) needs it.

## 2. Bootstrap Nix + Homebrew
- [ ] **Nix** — the Determinate Systems installer (robust `/nix` APFS volume,
      survives macOS upgrades; it owns the daemon, which is why the host module sets
      `nix.enable = false`):
      ```sh
      curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
      ```
- [ ] **Homebrew** (a prerequisite — `depend` shells out to `brew`/`mas`, it does
      not build them):
      ```sh
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      ```
- [ ] **Restore the SSH key** from Nextcloud to `~/.ssh/id_ed25519` (git signing;
      shared sops identity).

## 3. First switch
```sh
git clone <this repo> ~/Repos/personal/laptop
cd ~/Repos/personal/laptop
nix run nix-darwin -- switch --flake .#chris-macbook
```
This builds the system + home-manager, then the activation runs
`depend install --prune` against the `platform: osx` block in `packages.yaml`.

> PREREQUISITE: the `dependency-manager` flake must expose its `aarch64-darwin`
> package (and have `nix/deps.json` regenerated for the osx runtime) and be locked
> in `flake.lock`. If the build fails at `depend`, that step is still pending.

## 4. Day-to-day
```sh
darwin-rebuild switch --flake .#chris-macbook        # apply changes (converges Homebrew via --prune)
nix flake update && darwin-rebuild switch --flake .#chris-macbook
depend plan --prune --config packages.yaml           # preview installs + removals
```

Curate the machine by editing the `mac-apps` block in `packages.yaml` — add
`brew:`/`cask:`/`mas:` entries as you re-approve apps. Because the activation runs
`--prune`, anything you remove from the block is uninstalled on the next switch;
an empty section leaves that provider untouched.
