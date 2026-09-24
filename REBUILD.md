# Rebuild runbooks

From-scratch reinstall instructions, one per machine:

- **[`REBUILD-MSI.md`](REBUILD-MSI.md)** — `chris-msi` (NixOS). Destructive
  disko wipe of the 2TB drive (Windows on the other NVMe is never touched) + the
  post-install steps (TPM2, hibernation offset, sops/restic, Secure Boot).
- **[`REBUILD-FLEX.md`](REBUILD-FLEX.md)**: the ThinkPad X1 Carbon Gen 9 as it
  actually runs, ChromeOS Flex shared with Chris's wife, plus standalone
  home-manager (`chris@crostini`) in Chris's Linux container.
- **[`REBUILD-LENOVO.md`](REBUILD-LENOVO.md)** — the NixOS fallback for the same
  laptop, `chris-lenovo` (NixOS, ThinkPad X1
  Carbon Gen 9). Destructive full-disk wipe: NixOS-only, the pre-installed Windows
  does not survive. Includes the BIOS prep and the optional Secure Boot/hibernation
  phases, both off by default.
- **[`REBUILD-MAC.md`](REBUILD-MAC.md)** — `chris-macbook` (macOS / nix-darwin). OS
  reinstall, Determinate Nix + Homebrew bootstrap, first `darwin-rebuild switch`.
