# chris-lenovo install runbook

Moving the **Lenovo ThinkPad X1 Carbon Gen 9** (i7-1185G7, 16GB, 512GB NVMe,
Intel Iris Xe) from ChromeOS Flex to NixOS — btrfs-on-LUKS, impermanent root, no
discrete GPU. It stays the shared couch machine: two accounts, `chris` and
`fiona`, GNOME with Firefox and Zoom, updating itself (`my.autoUpgrade`).

> **This wipes the whole disk, including ChromeOS Flex and the Linux container.**
> Unlike `chris-msi` (dual-boot, where disko names only one of two NVMes), this
> machine is NixOS-only and the single NVMe is repartitioned in full.

> For the other hosts see [`REBUILD-MSI.md`](REBUILD-MSI.md) (NixOS, MSI) and
> [`REBUILD-MAC.md`](REBUILD-MAC.md) (macOS).

## 0. Before the wipe (from ChromeOS Flex)
- [ ] **Fiona's local files.** ChromeOS keeps Downloads and anything else under
      *My Files* on the disk only; Google Drive files are in her account and come
      back by themselves. In Files, move what she wants to keep into *Google
      Drive*, and wait until it shows as synced.
- [ ] **Fiona's browser data, out of Chrome.** She moves to Firefox, and Chrome
      sync doesn't carry over. Firefox can only import from a Chrome installed on
      the same machine, which won't exist after the wipe. So, in Chrome, into
      Google Drive:
      - bookmarks: *Bookmark manager → ⋮ → Export bookmarks* (an `.html` file);
      - passwords: *Password Manager → Settings → Export passwords* (a `.csv`).
        This file is every password in plain text: delete it from Drive once
        Firefox has imported it.
- [ ] **Chris's Linux container.** Repos travel via GitHub and git-wip (check
      `git wip status` shows *in sync* for each, with Nextcloud up); copy anything
      else in the container's `~` that isn't in a repo or Nextcloud.
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
# Fiona's too: have her type it, or set a temporary one and change it together
# on first login (see step 4; `passwd` does not work here).
mkpasswd -m sha-512 | sudo tee /mnt/persist/passwd/fiona
sudo chmod 600 /mnt/persist/passwd/chris /mnt/persist/passwd/fiona

# Install from a CLEAN checkout of a commit that is on GitHub main: my.autoUpgrade
# only takes over from systems built from a pushed commit (a dirty tree pauses it).
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
- [ ] **Enroll fingerprints, both of you** — each logged in as themselves:
      Settings → Users → Fingerprint Login (`services.fprintd.enable` is on).
      GNOME then uses it for login (and sudo, for chris).
- [ ] **Fiona's first login.** Open Firefox (first in the dock) and import what
      step 0 exported from Google Drive: *Bookmarks → Manage bookmarks → Import
      and Backup → Import Bookmarks from HTML*, then *Passwords (about:logins) →
      ⋯ → Import from a File*. Delete the passwords `.csv` from Drive afterwards.
      A Mozilla account (optional) keeps it all synced from then on. Then join
      `zoom.us/test` in the Zoom app and try a screen share.
- [ ] **Changing a password** is not `passwd` or GNOME Settings: users are
      declarative (`users.mutableUsers = false`) and /etc/shadow is wiped every
      boot. Rewrite the hash instead, which takes effect on the next boot:
      ```sh
      mkpasswd -m sha-512 | sudo tee /persist/passwd/fiona
      ```
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
- Updates are automatic (`my.autoUpgrade`): GitHub main is built daily for the
  next boot. `journalctl -u nixos-upgrade` shows the last run, or why it skipped.
- Apply a change by hand: commit and push it, then
  `sudo nixos-rebuild switch --flake .#chris-lenovo` from the clean tree. A switch
  from uncommitted work pauses auto-upgrades until you do that.
