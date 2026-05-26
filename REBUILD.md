# chris-laptop rebuild runbook

From-scratch reinstall onto the **2TB Samsung 990** (btrfs-on-LUKS, impermanent
root, hibernation, Secure Boot). **Windows on the 1TB Samsung 980 is never
touched** — disko only references the 2TB by-id.

## 0. Before the wipe
- [ ] **Sync all git repos** — uncommitted/stashed work, local-only branches.
      restic isn't set up yet, so this is the only safety net for `~/Repos`.
- [ ] **Back up `~/.claude`** to Nextcloud — just `CLAUDE.md` + `memory/` (the
      rebuild plan lives there), NOT the whole tree (it holds transcripts + auth).
- [ ] **Confirm the SSH key is in Nextcloud** — it's the sops/age identity *and*
      the commit-signing key.
- [ ] **Windows BitLocker recovery key handy** — Secure Boot will prompt once.
- [ ] De-risk: on the CURRENT machine, `nixos-rebuild build --flake .#chris-laptop`
      (and `nix flake lock`) so eval/build errors surface while it still works.
      (KeePass is read-only from a backup; the VPN is trivially recreatable — nothing to save.)

## 1. Partition — DESTRUCTIVE (boot a NixOS installer ISO)
Pre-flight — confirm the id still points at the 2TB drive, not Windows:
```sh
ls -l /dev/disk/by-id/ | grep -i 990_EVO    # must be the Samsung 990, NOT the 980
```
Clone the repo, then run disko against the 2TB drive only (prompts for the LUKS passphrase):
```sh
sudo nix --experimental-features "nix-command flakes" \
  run github:nix-community/disko -- --mode disko ./disko-config.nix
```

> No `@blank` step is needed — the impermanence rollback recreates `@` empty on
> every boot and moves the previous root to `@old`. On the very first boot the
> freshly-installed `@` just becomes the first `@old`.

## 2. Install
```sh
# First the declarative login password — mutableUsers=false + an ephemeral
# /etc/shadow means a MISSING hash file = locked out on first boot. disko mounted
# /persist at /mnt/persist:
sudo mkdir -p /mnt/persist/passwd
mkpasswd -m sha-512 | sudo tee /mnt/persist/passwd/chris
sudo chmod 600 /mnt/persist/passwd/chris

sudo nixos-install --no-root-passwd --flake /path/to/repo#chris-laptop   # root is declaratively locked
# reboot
```

## 3. First boot — post-install
- [ ] **TPM2 auto-unlock** (basic now; re-enrolled with PCRs in step 6):
  ```sh
  sudo systemd-cryptenroll --tpm2-device=auto \
    /dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NJ0Y432453X-part2
  ```
- [ ] **Restore the SSH key** from Nextcloud to `~/.ssh/id_ed25519` (needed for
      sops decryption + commit signing).
- [ ] **Hibernation resume offset:**
  ```sh
  sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
  ```
  Put the value in `modules/hibernation.nix` (`resume_offset=`), uncomment, rebuild.
- [ ] **sops / restic:** add your recipient to `.sops.yaml`
      (`ssh-to-age < ~/.ssh/id_ed25519.pub`), create `secrets/secrets.yaml`
      (see `secrets/README.md`), set `my.backups.enable = true;`, rebuild, then
      `systemctl status restic-backups-repos` to confirm the first run.
- [ ] **junkyard-boot-img:** `chattr +C ~/Repos/school/krg/junkyard/junkyard-boot-img/boot`
      (while empty) so image builds are NoCoW, and revert the Makefile's `truncate`
      workaround back to `fallocate` (it was only there because of the old ext2 root).

## 4. Verify hibernate
```sh
systemctl hibernate     # then power on — should RESUME, not cold-boot
```
If it cold-boots, `resume_offset` is wrong — recompute in step 4.

## 5. Secure Boot (phase 2)
```sh
sudo sbctl create-keys
# set my.secureBoot.enable = true; in configuration.nix
sudo nixos-rebuild switch --flake .#chris-laptop
# reboot -> firmware -> put Secure Boot in "setup mode"
sudo sbctl enroll-keys --microsoft     # MS keys too, so Windows still boots
# enable Secure Boot in firmware; Windows asks for the BitLocker key once
sudo sbctl status                      # expect: Secure Boot enabled, keys enrolled
```
Then re-enroll the TPM2 keyslot bound to the measured PCRs (closes the
unmeasured-initrd gap):
```sh
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+2+7 \
  /dev/disk/by-id/nvme-Samsung_SSD_990_EVO_Plus_2TB_S7U6NJ0Y432453X-part2
```

## Day-to-day
- Apply: `sudo nixos-rebuild switch --flake .#chris-laptop`
- Update: `nix flake update && sudo nixos-rebuild switch --flake .#chris-laptop`
- Generations/rollback still work — the store (`/nix`) and boot entries are durable.
