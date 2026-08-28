# chris-lenovo install runbook

First install onto the **Lenovo ThinkPad X1 Carbon Gen 9** (i7-1185G7, 16GB,
512GB NVMe, Intel Iris Xe) — btrfs-on-LUKS, impermanent root, no discrete GPU.

> **This wipes the whole disk, including the pre-installed Windows 11 Pro.**
> Unlike `chris-msi` (dual-boot, where disko names only one of two NVMes), this
> machine is NixOS-only and the single NVMe is repartitioned in full.

> For the other hosts see [`REBUILD-MSI.md`](REBUILD-MSI.md) (NixOS, MSI) and
> [`REBUILD-MAC.md`](REBUILD-MAC.md) (macOS).

## 0. Before the wipe
- [ ] **Anything wanted off the Windows install** — it does not survive. Grab the
      Windows product key if you might ever want it back
      (`wmic path SoftwareLicensingService get OA3xOriginalProductKey`); on this
      machine it is normally embedded in firmware and re-activates on its own.
- [ ] **Confirm the SSH key is in Nextcloud** — it is the sops/age identity *and*
      the commit-signing key, and it is what makes this machine able to decrypt
      the same secrets as the others.
- [ ] De-risk from a working machine: `nixos-rebuild build --flake .#chris-lenovo`
      so eval errors surface before you are standing at an installer prompt.

## 1. BIOS prep (F1 at the ThinkPad splash)
- [ ] **Secure Boot: disabled** for now. It gets enrolled in step 6, if at all.
- [ ] **Sleep State: Linux** if the option is present. The X1C9 defaults to
      Windows/Modern Standby (s2idle only). `boot.kernelParams` deliberately does
      NOT set `mem_sleep_default=deep` — forcing deep on s2idle-only firmware
      produces a machine that suspends and never resumes.
- [ ] Note the firmware is UEFI-only; no CSM/legacy toggle is needed.

## 2. Partition — DESTRUCTIVE (boot a NixOS installer ISO)
`hosts/chris-lenovo/disko-config.nix` ships a **placeholder device id** that does
not exist, so disko fails loudly rather than eating the wrong disk. Find the real
one and edit it in:
```sh
lsblk -o NAME,SIZE,MODEL,SERIAL          # identify the 512GB NVMe
ls -l /dev/disk/by-id/ | grep -v part    # take its by-id path
```
Then, with the id substituted into `disko-config.nix` (prompts for the LUKS passphrase):
```sh
sudo nix --experimental-features "nix-command flakes" \
  run github:nix-community/disko -- --mode disko ./hosts/chris-lenovo/disko-config.nix
```

> No `@blank` step is needed — the impermanence rollback recreates `@` empty on
> every boot and moves the previous root to `@old`. The freshly-installed `@`
> just becomes the first `@old`.

## 3. Install
```sh
# The declarative login password FIRST. users.mutableUsers = false plus an
# ephemeral /etc/shadow means a MISSING hash file = locked out on first boot,
# with no recovery short of re-mounting from the ISO. disko mounted /persist:
sudo mkdir -p /mnt/persist/passwd
mkpasswd -m sha-512 | sudo tee /mnt/persist/passwd/chris
sudo chmod 600 /mnt/persist/passwd/chris

sudo nixos-install --no-root-passwd --flake /path/to/repo#chris-lenovo
# reboot
```

## 4. First boot — post-install
- [ ] **Reconcile the hardware scan.** `hardware-configuration.nix` was written
      by hand from the known X1C9 layout, not generated. Confirm it:
      ```sh
      sudo nixos-generate-config --no-filesystems --show-hardware-config
      ```
      Take only the kernel-module / microcode lines; leave every disk entry to
      disko. Commit any difference.
- [ ] **TPM2 auto-unlock** (the X1C9 has a discrete TPM 2.0):
      ```sh
      sudo systemd-cryptenroll --tpm2-device=auto /dev/disk/by-id/<the-nvme>-part2
      ```
- [ ] **Restore the SSH key** from Nextcloud to `~/.ssh/id_ed25519` (sops
      decryption + commit signing).
- [ ] **Enroll a fingerprint** — Settings → Users → Fingerprint Login
      (`services.fprintd.enable` is on). GNOME then uses it for login and sudo.
- [ ] **Wi-Fi** should already work (AX201 via
      `hardware.enableRedistributableFirmware`). If not, that flag is the suspect.

## 5. Verify the impermanent root
```sh
touch /root-canary && sudo reboot     # after reboot: /root-canary must be GONE
ls /persist /home /nix                # these must all have survived
```
If the canary survives, the rollback did not run — check
`modules/nixos/impermanence.nix` and the initrd `storePaths` gotcha.

## 6. Optional — Secure Boot
Off by default here (`my.secureBoot.enable = false`). To enable, the two-phase
dance from `modules/nixos/secure-boot.nix`:
```sh
sudo sbctl create-keys
# set my.secureBoot.enable = true; in hosts/chris-lenovo/default.nix
sudo nixos-rebuild switch --flake .#chris-lenovo
# reboot -> firmware -> Secure Boot to "setup mode"
sudo sbctl enroll-keys            # no --microsoft needed: no Windows on this disk
sudo sbctl status
```
Then re-enroll the TPM2 keyslot against the measured PCRs:
```sh
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+2+7 \
  /dev/disk/by-id/<the-nvme>-part2
```

## 7. Optional — hibernation
Off by default (`my.hibernation.enable = false`), but the swapfile is already
sized at 20G (>= the 16G of RAM), so no repartition is needed:
```sh
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
```
Set `my.hibernation.enable = true` and `my.hibernation.resumeOffset` in
`hosts/chris-lenovo/default.nix`, rebuild, then verify `systemctl hibernate`
RESUMES rather than cold-booting.

## Day-to-day
- Apply: `sudo nixos-rebuild switch --flake .#chris-lenovo`
- Update: `nix flake update && sudo nixos-rebuild switch --flake .#chris-lenovo`
