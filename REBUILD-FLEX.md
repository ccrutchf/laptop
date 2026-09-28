# Lenovo on ChromeOS Flex — setup runbook

The ThinkPad X1 Carbon Gen 9 runs **ChromeOS Flex** as a shared couch machine:
one Google account each for Chris and his wife. ChromeOS owns the OS, updates,
browser and desktop. The only part in this repo is Chris's terminal layer inside
the Linux container (Crostini): standalone home-manager,
`homeConfigurations."chris@crostini"` in [`flake.nix`](flake.nix), built from
[`home/crostini.nix`](home/crostini.nix) plus the shared `home/common.nix`.

The NixOS config for this machine (`hosts/chris-lenovo/`,
[`REBUILD-LENOVO.md`](REBUILD-LENOVO.md)) stays in the repo as the fallback.

## 0. Before the wipe (from the pre-installed Windows)
- [ ] **Check the model** on Google's [certified models
      list](https://support.google.com/chromeosflex/answer/11513094) and read its
      known issues (fingerprint and IR camera are expected not to work).
- [ ] **Update firmware now**, while Windows is still here (Lenovo Commercial
      Vantage, or the BIOS update utility from Lenovo support). ChromeOS Flex has no
      fwupd, so after the wipe this means booting a USB updater.
- [ ] **Battery health:** `powercfg /batteryreport` → compare *Full charge
      capacity* with *Design capacity*. Below ~75%, a replacement battery is the
      single biggest battery-life upgrade.
- [ ] **Windows 11 Pro does not survive.** Its key is normally embedded in firmware
      and re-activates on its own if Windows is ever reinstalled.
- [ ] **Confirm the SSH key is in Nextcloud.** It is the git commit-signing key.

## 1. Install ChromeOS Flex
- [ ] On any machine with Chrome: install the **Chromebook Recovery Utility**
      extension → *Select a model from a list* → *Google ChromeOS Flex* → write to a
      USB stick (8GB+).
- [ ] Boot it on the ThinkPad (F12 → USB). Secure Boot can stay **on**.
- [ ] Optionally *Try it first* from USB to check Wi-Fi, audio, webcam and
      suspend. Then *Install ChromeOS Flex*, which **wipes the whole disk**.

## 2. Accounts
- [ ] **The first account to sign in becomes the owner** and controls device
      settings. Sign in with whichever account should own it, then add the other
      (*Settings → Accounts*). Optionally restrict sign-in to just the two of you.
- [ ] Each person: Chrome sync on; install web apps from Chrome (⋮ → *Cast, save
      and share → Install page as app*) for Gmail, Docs, Slack and so on.
- [ ] **Zoom:** open `app.zoom.us`, install it as an app, then join
      `zoom.us/test` and try a screen share. Flex has no Play Store, so this web app
      is the Zoom client. Don't use the Linux client in Crostini: webcam access is
      limited there.

## 3. Linux container (Chris's profile only)
- [ ] *Settings → About ChromeOS → Developers → Linux development environment →
      Turn on.* **Username: `chris`** (home-manager requires `$HOME` =
      `/home/chris`). Disk: 40GB or so; it can be resized later.
- [ ] *Settings → … → Linux → Allow Linux to access your microphone* if needed.
- [ ] **SSH key:** download `id_ed25519` and `id_ed25519.pub` from the Nextcloud web
      UI. In Files, right-click *Downloads → Share with Linux*, then:
      ```sh
      install -d -m 700 ~/.ssh
      install -m 600 /mnt/chromeos/MyFiles/Downloads/id_ed25519 ~/.ssh/
      install -m 644 /mnt/chromeos/MyFiles/Downloads/id_ed25519.pub ~/.ssh/
      ```
      Then delete both files from Downloads.

## 4. Nix + home-manager
- [ ] **Nix** (Determinate Systems installer, as on the Mac):
      ```sh
      curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
      ```
      Open a new terminal afterwards. Until the switch below, `nix-shell --help` and
      friends fail with "The 'man' command was not found": Debian's container has no
      `man`, and the switch brings it (home-manager's default `man-db`).
- [ ] **Clone and switch:**
      ```sh
      mkdir -p ~/.config/nix
      echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
      mkdir -p ~/Repos/personal && cd ~/Repos/personal
      nix shell nixpkgs#git nixpkgs#openssh -c git clone git@github.com:ccrutchf/laptop.git
      cd laptop
      nix shell nixpkgs#git -c nix run home-manager/master -- switch --flake '.#chris@crostini'
      ```
      Debian's container has no git, so the first clone and switch borrow it from
      nixpkgs. The switch needs it too: the Synology FileStation package has a Cargo
      git dependency (`smb2`), which crane fetches with `builtins.fetchGit` during
      evaluation, and that shells out to `git` on PATH. After this, `programs.git`
      (`home/common.nix`) keeps git on PATH for later switches.
      The `nix.conf` line is a no-op on Determinate Nix (flakes on by default) and
      needed on upstream Nix. It has to be config, not a
      `--extra-experimental-features` flag: home-manager runs its own `nix build`,
      which doesn't see the outer command's flags.
      From then on, `home-manager switch --flake '.#chris@crostini'`. Update after the
      MSI has lived on the same `flake.lock` for a while, so the MSI finds any breakage first.
      Each switch also runs `depend install --prune --tag crostini` against
      `packages.yaml`: it apt-installs `flatpak`, adds Flathub, and installs the
      untagged Linux Flathub apps (Zen, Nextcloud). To add or remove an app here, edit
      `packages.yaml`, not this machine. Preview with `depend plan --prune`
      (`DEPEND_TAGS=crostini` is set for you).
- [ ] **zsh as login shell:**
      ```sh
      command -v zsh | sudo tee -a /etc/shells
      sudo chsh -s "$(command -v zsh)" chris
      ```
      Then restart the container (right-click *Terminal* → *Shut down Linux*).
- [ ] **Nextcloud** (installed by the switch above). Start it from the launcher
      (restart Linux first if it isn't listed), sign in, and use **selective sync**.
      Saving the login creates a gnome-keyring "login" keyring: pick a password you'll
      remember. Crostini has no login screen to unlock it, so it asks again after
      each Linux restart. It runs on X11 (see `home/crostini.nix`); in its folder
      picker, Ctrl+H shows hidden folders and Ctrl+L takes a typed path.
      Never sync the whole account into a ~40GB container. At minimum include
      `Documents/ClaudeBackup` and `Documents/GitWip`, which claude-backup and git-wip
      write into. Synced files show up in ChromeOS Files under **Linux files**.
      It only syncs while it's running, and Crostini doesn't autostart GUI apps, so
      open it at the start of a session.

## 5. UCSD VPN
Two commands from `home/crostini.nix`. Try the first; fall back to the second:
- [ ] `ucsd-vpn`: kernel tunnel (sudo). Covers everything in the container. If it
      fails to open `/dev/net/tun`, the container has no tun device → use the next.
- [ ] `ucsd-vpn-socks`: user-space tunnel (no root). Leaves a SOCKS5 proxy on
      `localhost:1080`. In Zen: *Settings → Network Settings → Manual proxy →
      SOCKS Host `localhost` port `1080`, SOCKS v5, Proxy DNS when using SOCKS v5.*
- [ ] Record which one worked here, and drop the other from `home/crostini.nix`.

The VPN only covers the container. Chrome on the ChromeOS side does not go through
it unless its proxy is pointed at `localhost:1080`, and that only works if
ChromeOS forwards the port (untested).

## 6. Zen (Flatpak, inside the container)
- [ ] Already installed by the home-manager switch (step 4). If it doesn't show up
      in the ChromeOS launcher, restart Linux.
- [ ] Sign into the Mozilla account for sync.
- [ ] Set Zen's download folder to `/mnt/chromeos/MyFiles/Downloads`. It needs the
      *Share with Linux* from step 3; otherwise downloads land where ChromeOS can't see them.
- [ ] Expect no hardware video decode in the container: use Chrome for video.
      Page rendering is GPU-accelerated only with the flag from step 8 on
      (`about:support` → Compositing `WebRender`, not `WebRender (Software)`).

## 7. VSCode (Nix-built)
- [ ] The switch in step 4 installs `code` (the same build as the NixOS hosts, with
      `--no-sandbox`) and the `vscode-extensions` block from `packages.yaml`.
      Open it once from the launcher to check it starts.

## 8. Synology FileStation (Nix-built GUI + CLI)
- [ ] The switch in step 4 installs `SynologyFuse.Gui` and `synology-filestation-fuse`,
      apt-installs `fuse3` for the setuid `fusermount3` they mount through, and runs
      `non-nixos-gpu-setup` (home-manager's GPU shim) through passwordless sudo. That
      step creates `/run/opengl-driver` so Nix GUI apps find Mesa, and it re-runs
      whenever the drivers change.
- [ ] Give Linux a GPU: Flex leaves it off. Set `chrome://flags/#crostini-gpu-support`
      to *Enabled*, restart ChromeOS, then right-click *Terminal* → *Shut down Linux*
      (closing the terminal isn't enough). If launchers then say "Your device didn't
      shut down properly", do that Shut down Linux once more.
- [ ] The step 4 switch added you to the `render` group; without it Mesa can't open
      the GPU. It applies from the Shut down Linux above.
- [ ] Check GPU acceleration: `ls /dev/dri` should list `renderD128`, and
      `glxinfo -B` via comma (`, glxinfo -B`) should name a virgl renderer rather
      than llvmpipe. If it says llvmpipe, the VM has no GPU (flag off, or Linux not
      restarted since); everything still runs, only slower.
- [ ] Mount a share under `~/mnt/<share>` from the GUI or the CLI. Then check whether
      it appears in ChromeOS Files under *Linux files*. If it doesn't, the mount
      needs `allow_other` plus `user_allow_other` in `/etc/fuse.conf`.
- [ ] Mounts only live while Linux is running; shutting it down drops them.

## 9. First-week checks
- [ ] **Sleep drain:** note the battery level at night with the lid closed, and
      check it in the morning.
- [ ] Zoom test meeting + screen share (step 2).
- [ ] `ucsd-vpn` or `ucsd-vpn-socks` against a campus-only page.

## Going back
ChromeOS reset: *Powerwash* (Settings → Reset settings). Switching the machine to
NixOS instead: [`REBUILD-LENOVO.md`](REBUILD-LENOVO.md). The disko wipe removes
Flex.
