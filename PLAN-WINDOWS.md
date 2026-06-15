# PLAN-WINDOWS

Forward-looking plan for adding a third personal machine — **`chris-windows`** — to
this flake. Nothing here is wired up yet; this is the design + checklist to follow
when the work actually starts. It will graduate into a `REBUILD-WINDOWS.md` runbook
(alongside [`REBUILD-NIXOS.md`](REBUILD-NIXOS.md) / [`REBUILD-MAC.md`](REBUILD-MAC.md))
once the layers below exist.

## The core constraint

Nix does not manage native Windows. The two existing hosts each give us a
home-manager `home.activation` hook that runs `depend install --prune` against
[`packages.yaml`](packages.yaml) on every switch (see [CLAUDE.md](CLAUDE.md), "The
`depend` activation hook"). Native Windows has neither a Nix switch nor
home-manager, so "add Windows" is really a question of **which layer Windows plugs
into**. There are two clean answers and they compose.

## Strategy A — WSL2 as a third flake host (the dev environment)

Treat native Windows as a substrate and put the real environment in **NixOS-WSL**.
This is the smallest-effort, highest-reuse path: it matches the existing
architecture almost exactly (a third `nixosConfiguration` reusing the shared home
layer) and gives a real dev shell immediately.

What we get for free from [`home/common.nix`](home/common.nix): the
zsh/atuin/starship/zoxide/fzf stack, git + SSH commit signing, `depend`, the
cross-platform CLIs, and the `vscode-extensions: platform: all` block via Remote-WSL.

The laptop-hardware modules in `modules/nixos/` (impermanence, disko, secure-boot,
hibernation) are simply **not** imported — WSL has no disk/boot/lid concerns.

### Checklist
- [ ] Add the **`nixos-wsl`** flake input (`github:nix-community/NixOS-WSL`,
      `inputs.nixpkgs.follows = "nixpkgs"`) in [`flake.nix`](flake.nix).
- [ ] Add `nixosConfigurations.chris-windows-wsl` (`x86_64-linux`) in
      [`flake.nix:74`](flake.nix#L74), importing `nixos-wsl.nixosModules.default`
      plus a new `hosts/chris-windows-wsl/default.nix` (minimal: hostname, user
      `chris`, `wsl.enable = true`, `wsl.defaultUser = "chris"`).
- [ ] Create **`home/wsl.nix`** — imports `home/common.nix` but drops the desktop
      bits (Hyprland/GTK/dconf/flatpak live only in `home/linux.nix`). WSL is
      headless, so this is a thin file: `home.homeDirectory = "/home/chris"` + the
      Linux `depend` activation hook **without** the flatpak/vscode providers
      (those are GUI/Linux-desktop concerns). Decide whether the WSL host runs
      `depend` at all, or leaves the non-Nix layer to native Windows (Strategy B).
- [ ] Wire the host's `home-manager.users.chris = import ./home/wsl.nix` in the
      flake, mirroring the laptop/mac blocks.
- [ ] CI: add `chris-windows-wsl` to the eval matrix in
      `.github/workflows/flake.yml` — it evaluates on the Linux runner exactly like
      `chris-laptop` (no special runner needed; it's a NixOS config).

### Bootstrap (future REBUILD-WINDOWS.md, WSL section)
- [ ] `wsl --install`, import the NixOS-WSL tarball as the distro.
- [ ] Restore the SSH key from Nextcloud to `~/.ssh/id_ed25519` (shared sops/age
      identity + git signing key — same key as every other host).
- [ ] `git clone` this repo, `sudo nixos-rebuild switch --flake .#chris-windows-wsl`.

## Strategy B — native Windows via `depend` + a `platform: windows` block

This extends the repo's stated philosophy ("one `packages.yaml` drives the non-Nix
layer on both machines") to native Windows GUI apps that can't live in WSL (games,
native Office, drivers, native browsers). It is **gated on work in another repo**
and should only be pursued for apps that genuinely must be native.

### Prerequisite (in `ccrutchf/dependency-manager`, not here)
- [ ] `depend` must support a **`windows`** platform value and a **winget**
      provider (and probably **scoop**; optionally **choco**). **This is the real
      blocker** — Strategy B cannot start until depend speaks Windows. Confirm
      current support before committing to this path.
- [ ] The `dependency-manager` flake should expose a Windows-runnable `depend`
      binary, or we accept fetching it out-of-band (there is no Nix on native
      Windows to build it).

### Checklist (in this repo, once depend is ready)
- [ ] Add a `platform: windows` block to [`packages.yaml`](packages.yaml) with a
      `winget:` (and/or `scoop:`) section, mirroring the `mac-apps` cask block —
      keys are winget package IDs, comments add the non-obvious "why".
- [ ] Confirm how the existing `platform: all` `vscode-extensions` block resolves
      `code` on Windows (the block relies on `dependencies: [visual-studio-code]`
      to put `code` on PATH — verify the winget VS Code package does the same, or
      add a Windows-specific guard).
- [ ] Decide the **dotfiles** story: home-manager does not run on native Windows.
      Options — a small PowerShell bootstrap that symlinks configs, or `chezmoi`,
      or simply accept that native dotfiles live in WSL only and native Windows
      gets apps-but-not-shell-config.

### Bootstrap / convergence (no activation hook exists)
There is no `nixos-rebuild`/`darwin-rebuild` on native Windows, so nothing
auto-runs `depend install --prune`. Pick a driver:
- [ ] A line in the PowerShell `$PROFILE`, **or** a Scheduled Task, **or** a
      documented manual `depend install --prune --config packages.yaml` step in
      REBUILD-WINDOWS.md. Manual is the honest MVP; automate later.

## Recommendation

Do **both, in order**: Strategy A first (a near-free third host that yields a real
dev environment and reuses the entire shell/Nix/dotfile layer), then Strategy B
**only** for the handful of apps that must be native — and only after depend's
winget provider exists. Keeping WSL as the dev surface means we never reinvent the
shell/dotfile/Nix layer on Windows.

The decision that shapes scope: **what is this machine for?**
- *A dev box that happens to run Windows* → Strategy A alone is likely enough; B is optional.
- *A gaming / native-app machine to manage declaratively* → B is required, so invest in depend's winget provider first.

## Open questions
- [ ] Does `depend` currently support a `windows` platform + winget provider? (Gates Strategy B.)
- [ ] One machine wearing two hats (native Windows **and** WSL), or is WSL the only
      managed surface? Determines whether `home/wsl.nix` runs `depend` or leaves the
      non-Nix layer entirely to a native `platform: windows` block.
- [ ] Dotfiles on native Windows: bootstrap script, `chezmoi`, or WSL-only?
- [ ] Hostname convention: `chris-windows` (native) vs `chris-windows-wsl` (the
      NixOS config) — if both exist on one box, they need distinct names.
</content>
</invoke>
