#!/usr/bin/env bash
# Initial setup for an ALREADY-INSTALLED machine: point /etc/nixos at this repo
# and switch via the flake. Safe to re-run. (For a from-scratch reinstall with
# disko, see REBUILD.md.)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deploying NixOS config from $REPO"

if [ -L /etc/nixos ]; then
  current="$(readlink -f /etc/nixos)"
  if [ "$current" = "$REPO" ]; then
    echo "==> /etc/nixos already linked to $REPO"
  else
    echo "ERROR: /etc/nixos is a symlink to $current (expected $REPO). Refusing to overwrite." >&2
    exit 1
  fi
elif [ -e /etc/nixos ]; then
  backup="/etc/nixos.bak.$(date +%Y%m%d-%H%M%S)"
  echo "==> Backing up /etc/nixos -> $backup"
  sudo mv /etc/nixos "$backup"
  echo "==> Linking /etc/nixos -> $REPO"
  sudo ln -s "$REPO" /etc/nixos
else
  echo "==> Linking /etc/nixos -> $REPO"
  sudo ln -s "$REPO" /etc/nixos
fi

echo "==> Running nixos-rebuild switch --flake"
sudo nixos-rebuild switch --flake "$REPO#chris-laptop"

echo "==> Done."
