# secrets/

sops-nix encrypted secrets. The encrypted `secrets.yaml` is safe to commit; the
**decryption key never lives here** — it's the age identity derived from the SSH
key synced via Nextcloud (see `../.sops.yaml`). Keep this repo **private**.

## One-time setup

1. Put the age recipient in `../.sops.yaml`:
   ```sh
   ssh-to-age < ~/.ssh/id_ed25519.pub      # paste output over age1REPLACE_...
   ```
2. Create the secrets file:
   ```sh
   sops secrets/secrets.yaml
   ```
   Add these two keys:
   ```yaml
   restic:
       password: <a long random passphrase — encrypts the restic repo>
       rclone-conf: |
           [nextcloud]
           type = webdav
           url = https://YOUR_NEXTCLOUD_HOST/remote.php/dav/files/YOUR_USER/
           vendor = nextcloud
           user = YOUR_USER
           pass = <obscured>      # rclone obscure 'YOUR_NEXTCLOUD_APP_PASSWORD'
   ```
   Generate the obscured password with: `rclone obscure 'app-password'`.
   The app password is created in Nextcloud → Settings → Security (scoped, revocable).
3. Flip `my.backups.enable = true;` in `configuration.nix` and rebuild.

## Bootstrap note (fresh install)

sops can only decrypt once `~/.ssh/id_ed25519` is present, so restore that key
from Nextcloud **before** the first `switch` with backups enabled — otherwise the
restic secrets won't materialize and the backup service will fail until they do.
