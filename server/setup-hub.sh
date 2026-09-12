#!/usr/bin/env bash
# One-time setup of the git hub on the personal Linux server (ogre01).
#
# The clients do the per-repo work themselves — git-sync creates each bare repo
# on first sight — so this only has to make the directory exist, confirm the
# prerequisites, and keep the hub from growing without bound.
#
# Run ON THE SERVER as the user the laptops SSH in as:
#     ./setup-hub.sh                 # defaults to /mnt/data/srv
#     HUB_PATH=/other/path ./setup-hub.sh
#
# Idempotent: safe to re-run.
set -euo pipefail

HUB_PATH=${HUB_PATH:-/mnt/data/srv}

command -v git >/dev/null || { echo "git is not installed on this server" >&2; exit 1; }

if [ ! -d "$HUB_PATH" ]; then
  # sudo only if the parent isn't already writable — most of the time it is.
  if mkdir -p "$HUB_PATH" 2>/dev/null; then :; else sudo mkdir -p "$HUB_PATH"; fi
fi
if [ ! -w "$HUB_PATH" ]; then sudo chown "$(id -un):$(id -gn)" "$HUB_PATH"; fi
echo "hub directory: $HUB_PATH ($(df -h --output=source,avail "$HUB_PATH" | tail -1))"

# The laptops authenticate with the Nextcloud-synced SSH key, the same identity
# that signs their commits. Nothing here installs it — that's a one-line
# ssh-copy-id from each laptop — but a hub with no authorized key is the most
# likely reason sync silently never starts, so say so loudly.
if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
  echo
  echo "WARNING: $HOME/.ssh/authorized_keys is empty or missing."
  echo "From EACH laptop, run:  ssh-copy-id $(id -un)@$(hostname -f 2>/dev/null || hostname)"
fi

# --- keep the hub from growing forever ---------------------------------------
# Every sync force-updates refs/wip/<host>/<branch>, so the previous snapshot's
# objects become unreachable. Without a gc they are never reclaimed and the hub
# grows by roughly a working tree per machine per change, indefinitely.
#
# --prune uses git's default 2-week grace period rather than `now`: pruning
# objects a concurrent push is still relying on is the one way gc can corrupt a
# repo, and two weeks makes that impossible in practice.
UNIT_DIR=/etc/systemd/system
if command -v systemctl >/dev/null && [ -d "$UNIT_DIR" ]; then
  sudo tee "$UNIT_DIR/git-hub-gc.service" >/dev/null <<UNIT
[Unit]
Description=Garbage-collect the git hub's bare repos

[Service]
Type=oneshot
User=$(id -un)
ExecStart=/usr/bin/env bash -c 'find "$HUB_PATH" -type d -name "*.git" -prune -print0 | xargs -0 -r -n1 -I{} git -C {} gc --quiet --prune'
UNIT
  sudo tee "$UNIT_DIR/git-hub-gc.timer" >/dev/null <<UNIT
[Unit]
Description=Weekly git hub gc

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now git-hub-gc.timer
  echo "enabled weekly git-hub-gc.timer"
else
  echo "no systemd here — schedule this yourself, weekly:"
  echo "  find $HUB_PATH -type d -name '*.git' -prune -print0 | xargs -0 -n1 -I{} git -C {} gc --quiet --prune"
fi

echo
echo "Hub ready. The laptops create their own bare repos on the next sync."
echo "Back up $HUB_PATH — it is now the only place all three laptops' work meets."
