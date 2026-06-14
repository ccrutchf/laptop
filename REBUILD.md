# Rebuild runbooks

From-scratch reinstall instructions, one per machine:

- **[`REBUILD-NIXOS.md`](REBUILD-NIXOS.md)** — `chris-laptop` (NixOS). Destructive
  disko wipe of the 2TB drive (Windows on the other NVMe is never touched) + the
  post-install steps (TPM2, hibernation offset, sops/restic, Secure Boot).
- **[`REBUILD-MAC.md`](REBUILD-MAC.md)** — `chris-macbook` (macOS / nix-darwin). OS
  reinstall, Determinate Nix + Homebrew bootstrap, first `darwin-rebuild switch`.
