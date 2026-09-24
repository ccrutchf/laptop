# git-wip — carry unfinished work (branches + uncommitted changes) between machines.
# See ./default.nix for the design; GIT_WIP_HOST is prepended by the Nix wrapper.
#
# Per repo, each machine keeps:
#   refs/wip/base          the snapshot this clone last synced to (exported or applied)
#   .git/wip/base.state    the local state right after that sync ("untouched since?")
#   refs/wip/<peer>/...    the latest snapshot + branches fetched from each peer
#   refs/wip/backup/*      the local state from before every automatic overwrite
# and publishes refs/wip/base as $HUB/<repo-key>/<host>.{base,snap}.bundle (see
# "sync" below). refs/wip/snap is the last snapshot actually published, and
# refs/wip/pub/* the base layer's contents.

HUB=${GIT_WIP_HUB:-$HOME/Documents/GitWip}
ROOT=${GIT_WIP_ROOT:-$HOME/Repos}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/git-wip
MAX_UNTRACKED_BYTES=$((50 * 1024 * 1024))
LINEAGE_MAX=500
BACKUPS_KEEP=20
# The snap layer is folded into a new base once it's over this and over a
# quarter of the base (see publish).
REBASE_MIN_BYTES=$((2 * 1024 * 1024))
# On a metered network, publish only when the upload is at most this.
METERED_MAX_BYTES=$((1024 * 1024))
# How long pre-sleep holds off suspend after writing a bundle, so the Nextcloud
# client gets a chance to upload it. Best effort: there's no "upload done" signal.
SETTLE_SECONDS=15

SELF=$0
export GIT_TERMINAL_PROMPT=0
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes}"
export GIT_SSH_COMMAND
export GIT_AUTHOR_NAME=git-wip GIT_AUTHOR_EMAIL="git-wip@$GIT_WIP_HOST"
export GIT_COMMITTER_NAME=git-wip GIT_COMMITTER_EMAIL="git-wip@$GIT_WIP_HOST"
mkdir -p "$CACHE"

log() { printf 'git-wip: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

# Notices are queued and shown once per run, so a sync that touches ten repos
# makes one notification rather than ten.
notice() {
  log "$1: $2"
  printf '%s: %s\n' "$1" "$2" >> "$CACHE/notices"
}

desktop_notify() {
  if [ -x /usr/bin/osascript ]; then
    /usr/bin/osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null; then
    notify-send --app-name=git-wip "$1" "$2" 2>/dev/null || true
  fi
}

flush_notices() {
  local n
  [ -s "$CACHE/notices" ] || return 0
  n=$(wc -l < "$CACHE/notices")
  if [ "$n" -eq 1 ]; then
    desktop_notify git-wip "$(cat "$CACHE/notices")"
  else
    desktop_notify "git-wip: $n repos" "$(head -n 5 "$CACHE/notices")"
  fi
  : > "$CACHE/notices"
}

take_lock() {  # $1 = seconds to wait; 0 = give up at once
  exec 9>> "$CACHE/lock"
  if [ "$1" -eq 0 ]; then flock -n 9; else flock -w "$1" 9; fi
}

# ── repo context ────────────────────────────────────────────────────────────────

g() { git -C "$REPO" "$@"; }

open_repo() {  # $1 = a path inside the repo
  local common
  REPO=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  GD=$(git -C "$REPO" rev-parse --absolute-git-dir)
  common=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  if [ "$(cd "$GD" && pwd -P)" != "$common" ]; then
    log "$REPO: linked worktree, skipped"
    return 1
  fi
  WIP=$GD/wip
  mkdir -p "$WIP"
  NAME=${REPO#"$ROOT"/}
  KEY=$(repo_key) || return 1
  SLUG=$(printf '%s' "$KEY" | tr -c 'a-z0-9.-' '_')
}

# The same repo on two machines is recognised by its origin URL, normalised so
# git@host:o/r, ssh://git@host/o/r.git and https://host/o/r all match. Repos with
# no (or a local-path) origin fall back to their root commit.
repo_key() {
  local url host rest root
  url=$(g config --get remote.origin.url) || url=
  case $url in
    "" | /* | .* | file://*)
      root=$(g rev-list --max-parents=0 HEAD 2>/dev/null | sort | sed -n 1p)
      [ -n "$root" ] || return 1
      printf 'root/%s\n' "$root"
      return 0 ;;
  esac
  url=${url,,}
  url=${url%/}
  url=${url%.git}
  if [[ $url == *://* ]]; then url=${url#*://}; else url=${url/://}; fi
  host=${url%%/*}
  rest=${url#*/}
  printf '%s/%s\n' "${host#*@}" "$rest"
}

busy() {
  local f
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply index.lock; do
    [ -e "$GD/$f" ] && return 0
  done
  return 1
}

# Sets IDX_TREE, WT_TREE, HEAD_COMMIT and STATE (branches, HEAD, index tree and
# working-tree tree) without touching the real index: untracked, non-ignored
# files go into a throwaway copy of it. Untracked files over the size cap are
# left out and listed in $WIP/skipped.
compute_state() {
  local tmp ref
  IDX_TREE=$(g write-tree 2>/dev/null) || return 1
  HEAD_COMMIT=$(g rev-parse -q --verify 'HEAD^{commit}') || return 1
  tmp=$(mktemp "$CACHE/index.XXXXXX")
  # -p: git trusts stat data only for files older than the index file itself
  # ("racy git"); a fresh mtime on the copy would hide same-second edits.
  if [ -f "$GD/index" ]; then cp -p "$GD/index" "$tmp"; else rm -f "$tmp"; fi
  GIT_INDEX_FILE=$tmp git -C "$REPO" add -u
  : > "$WIP/skipped.new"
  (cd "$REPO" && git ls-files -z -o --exclude-standard) \
    | (cd "$REPO" && xargs -0 -r stat --printf '%s\t%n\0') \
    | gawk -v max="$MAX_UNTRACKED_BYTES" -v skipped="$WIP/skipped.new" '
        BEGIN { RS = ORS = "\0" }
        {
          i = index($0, "\t"); size = substr($0, 1, i - 1); path = substr($0, i + 1)
          if (path ~ /\/$/) next                      # nested repo: not ours
          if (size + 0 > max) printf "%s\n", path > skipped
          else print path
        }' \
    | GIT_INDEX_FILE=$tmp git -C "$REPO" update-index --add -z --stdin
  WT_TREE=$(GIT_INDEX_FILE=$tmp git -C "$REPO" write-tree)
  rm -f "$tmp"

  if [ -s "$WIP/skipped.new" ] && ! cmp -s "$WIP/skipped.new" "$WIP/skipped" 2>/dev/null; then
    notice "$NAME" "not synced, over 50 MB: $(paste -sd, "$WIP/skipped.new")"
  fi
  mv -f "$WIP/skipped.new" "$WIP/skipped"

  STATE=$(
    if ref=$(g symbolic-ref -q HEAD); then echo "head: ref $ref"; else echo "head: detached $HEAD_COMMIT"; fi
    g for-each-ref --format='branch: %(refname) %(objectname)' refs/heads
    echo "index: $IDX_TREE"
    echo "worktree: $WT_TREE"
  )
}

# ── snapshots ───────────────────────────────────────────────────────────────────
# A snapshot is a commit whose tree is the working tree, with parents HEAD and a
# commit of the index (so both travel in the bundle). Its message carries the
# state lines plus its lineage: every snapshot it descends from. Lineage is a
# list rather than parent links so a bundle never drags old snapshots along.

snap_msg()     { g cat-file commit "$1" | sed '1,/^$/d'; }
snap_state()   { snap_msg "$1" | grep -E '^(head|branch|index|worktree): ' || true; }
snap_field()   { snap_msg "$1" | sed -n "s/^$2: //p"; }
snap_lineage() { snap_field "$1" lineage; }

in_lineage() {  # $1 = sha, $2 = snapshot
  local lineage
  lineage=$(snap_lineage "$2")
  grep -qxF "$1" <<< "$lineage"
}

make_snapshot() {  # stdin: lineage shas; stdout: the new snapshot
  local lineage idx_commit
  lineage=$(awk -v max="$LINEAGE_MAX" 'NF && !seen[$0]++ && n++ < max')
  idx_commit=$(g commit-tree --no-gpg-sign -p "$HEAD_COMMIT" -m 'git-wip index' "$IDX_TREE")
  {
    printf 'git-wip snapshot of %s\n\nhost: %s\ntime: %s\n%s\n' \
      "$NAME" "$GIT_WIP_HOST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STATE"
    [ -z "$lineage" ] || printf 'lineage: %s\n' "${lineage//$'\n'/$'\nlineage: '}"
  } | g commit-tree --no-gpg-sign -p "$HEAD_COMMIT" -p "$idx_commit" -F - "$WT_TREE"
}

prune_backups() {
  g for-each-ref --sort=-refname --format='%(refname)' refs/wip/backup \
    | tail -n +$((BACKUPS_KEEP + 1)) \
    | while read -r ref; do g update-ref -d "$ref"; done
}

# Make branches, HEAD, index and working tree match snapshot $1, after saving the
# current state as a backup. mirror also deletes local branches the snapshot
# lacks (they were deleted on the other machine); keep leaves them.
apply_snapshot() {  # $1 = snapshot, $2 = where it came from, $3 = mirror|keep
  local snap=$1 from=$2 mode=$3 bk rstate ref sha head old new msg
  bk=$(make_snapshot < /dev/null)
  g update-ref "refs/wip/backup/$(date -u +%Y%m%dT%H%M%S.%N)" "$bk"
  prune_backups

  old=$(g symbolic-ref -q --short HEAD) || old=${HEAD_COMMIT:0:12}
  rstate=$(snap_state "$snap")
  while read -r _ ref sha; do
    g update-ref "$ref" "$sha"
  done < <(grep '^branch: ' <<< "$rstate" || true)
  if [ "$mode" = mirror ]; then
    while read -r ref; do
      grep -qF "branch: $ref " <<< "$rstate" || g update-ref -d "$ref"
    done < <(g for-each-ref --format='%(refname)' refs/heads)
  fi
  head=$(sed -n 's/^head: //p' <<< "$rstate")
  case $head in
    "ref "*)      g symbolic-ref HEAD "${head#ref }" ;;
    "detached "*) g update-ref --no-deref HEAD "${head#detached }" ;;
  esac

  # Index := every file the old snapshot covered, so the -u reset below deletes
  # files (tracked or untracked) that the new one lacks, and nothing else: ignored
  # and oversized files never enter the index, so they're never touched.
  g read-tree --reset "$WT_TREE"
  g read-tree -u --reset "$(sed -n 's/^worktree: //p' <<< "$rstate")"
  g read-tree --reset "$(sed -n 's/^index: //p' <<< "$rstate")"
  g update-index -q --refresh > /dev/null || true

  new=$(g symbolic-ref -q --short HEAD) || new=$(g rev-parse --short HEAD)
  if [ "$old" = "$new" ]; then msg="$new updated from $from"; else msg="$old → $new (from $from)"; fi
  printf '%s\n' "$from" > "$WIP/applied"
  notice "$NAME" "$msg"
}

adopt() {  # $1 = snapshot now checked out
  g update-ref refs/wip/base "$1"
  compute_state
  printf '%s\n' "$STATE" > "$WIP/base.state"
}

# True when applying snapshot $1 would lose nothing: the tree is clean and every
# local branch is already contained in the snapshot's branch of the same name.
lossless() {
  local snap=$1 rstate ref sha rsha
  [ "$WT_TREE" = "$IDX_TREE" ] || return 1
  [ "$IDX_TREE" = "$(g rev-parse 'HEAD^{tree}')" ] || return 1
  rstate=$(snap_state "$snap")
  while read -r ref sha; do
    rsha=$(awk -v r="$ref" '$1 == "branch:" && $2 == r { print $3 }' <<< "$rstate")
    if [ -n "$rsha" ] && ! g merge-base --is-ancestor "$sha" "$rsha"; then return 1; fi
  done < <(g for-each-ref --format='%(refname) %(objectname)' refs/heads)
  if ! g symbolic-ref -q HEAD > /dev/null; then
    g merge-base --is-ancestor "$HEAD_COMMIT" "$snap^1" || return 1
  fi
}

local_changed() {  # since the last sync
  [ "$STATE" != "$(cat "$WIP/base.state" 2>/dev/null)" ]
}

# ── sync ────────────────────────────────────────────────────────────────────────
# Each machine publishes its work per repo in up to three layers, so an edit
# costs an upload about the size of the edit, not everything that isn't on origin:
#   <host>.base.bundle  a snapshot + its branches (refs/wip/pub/*): the bulk, i.e.
#                       unpushed commits and untracked files. Replaced by the
#                       current snapshot once the layers above outgrow it.
#   <host>.snap.bundle  the current snapshot, minus what's in base (refs/wip/mid/*
#                       records it). Rewritten on every unmetered publish.
#   <host>.top.bundle   metered publishes only: the current snapshot minus base and
#                       snap, so edits made on a phone connection stay small even
#                       when snap is big. Deleted by the next unmetered publish.
# Snapshots are the one machine's, so a peer takes the newest layer it can read.
# Files may land in any order; a mismatched set is stale or unverifiable and
# settles a run later.

LAYERS=(base snap top)
layer_ref()   { if [ "$1" = base ]; then echo refs/wip/pub/snap; else echo refs/wip/snap; fi; }
layer_heads() { if [ "$1" = base ]; then echo 'refs/wip/pub/heads/*'; else echo 'refs/heads/*'; fi; }

bundle_head() {  # $1 = bundle, $2 = ref; prints the sha, or nothing
  [ -f "$1" ] || return 0
  g bundle list-heads "$1" "$2" 2> /dev/null | cut -d' ' -f1 || true
}

# Fetch bundle $1 with refspecs $3... once it verifies. The bundles leave out
# whatever the peer saw on origin, so a failed verify fetches origin first, at
# most every half hour per pending snapshot ($2) so an offline origin isn't
# hammered. Returns 1 while the prerequisites are still missing.
fetch_bundle() {
  local file=$1 id=$2 pending=$WIP/pending.${1##*/}
  shift 2
  if ! g bundle verify -q "$file" > /dev/null 2>&1; then
    if [ "$(cat "$pending" 2> /dev/null)" = "$id" ] \
       && [ -n "$(find "$pending" -mmin -30 2> /dev/null)" ]; then
      return 1
    fi
    printf '%s\n' "$id" > "$pending"
    if g remote get-url origin > /dev/null 2>&1; then g fetch -q origin || true; fi
    if ! g bundle verify -q "$file" > /dev/null 2>&1; then
      log "$NAME: ${file##*/} needs objects this clone doesn't have yet; will retry"
      return 1
    fi
  fi
  rm -f "$pending"
  g fetch -q --prune --no-write-fetch-head "$file" "$@"
}

newer() {  # is snapshot $1 newer than $2? Lineage first; clocks only to break ties.
  if in_lineage "$2" "$1"; then return 0; fi
  if in_lineage "$1" "$2"; then return 1; fi
  ! [[ $(snap_field "$1" time) < $(snap_field "$2" time) ]]
}

import_peer() {  # $1 = peer host
  local peer=$1 l f head key snap seen base
  key=
  for l in "${LAYERS[@]}"; do
    key+="$(bundle_head "$HUB/$SLUG/$peer.$l.bundle" "$(layer_ref "$l")") "
  done
  [ -n "${key// /}" ] || return 0
  [ "$key" != "$(cat "$WIP/seen-files.$peer" 2> /dev/null)" ] || return 0

  for l in "${LAYERS[@]}"; do
    f=$HUB/$SLUG/$peer.$l.bundle
    if [ ! -f "$f" ]; then
      g for-each-ref --format='delete %(refname)' "refs/wip/$peer/layers/$l" | g update-ref --stdin
      continue
    fi
    head=$(bundle_head "$f" "$(layer_ref "$l")")
    [ "$head" != "$(g rev-parse -q --verify "refs/wip/$peer/layers/$l/snap")" ] || continue
    fetch_bundle "$f" "$head" "+$(layer_ref "$l"):refs/wip/$peer/layers/$l/snap" \
      "+$(layer_heads "$l"):refs/wip/$peer/layers/$l/heads/*" || return 0
  done
  snap=
  for l in "${LAYERS[@]}"; do
    head=$(g rev-parse -q --verify "refs/wip/$peer/layers/$l/snap") || continue
    if [ -z "$snap" ] || newer "$head" "$snap"; then snap=$head; fi
  done
  [ -n "$snap" ] || return 0
  g update-ref "refs/wip/$peer/snap" "$snap"
  printf '%s\n' "$key" > "$WIP/seen-files.$peer"
  seen=$(cat "$WIP/seen.$peer" 2> /dev/null) || seen=
  [ "$snap" != "$seen" ] || return 0

  base=$(g rev-parse -q --verify refs/wip/base) || base=
  if [ -n "$base" ] && { [ "$snap" = "$base" ] || in_lineage "$snap" "$base"; }; then
    rm -f "$WIP/conflict.$peer"                  # we already have this or newer
  elif [ "$(snap_state "$snap")" = "$STATE" ]; then
    adopt "$snap"                                # identical already; just record it
    rm -f "$WIP/conflict.$peer"
  elif [ -n "$base" ] && in_lineage "$base" "$snap" && ! local_changed; then
    apply_snapshot "$snap" "$peer" mirror        # the normal hand-off
    adopt "$snap"
    rm -f "$WIP/conflict.$peer"
  elif lossless "$snap"; then
    apply_snapshot "$snap" "$peer" keep          # e.g. first contact, clean tree
    adopt "$snap"
    rm -f "$WIP/conflict.$peer"
  else
    [ -e "$WIP/conflict.$peer" ] \
      || notice "$NAME" "changed here and on $peer — git wip take $peer, or git wip keep"
    printf '%s\n' "$snap" > "$WIP/conflict.$peer"
  fi
  printf '%s\n' "$snap" > "$WIP/seen.$peer"
}

export_state() {
  local base snap
  base=$(g rev-parse -q --verify refs/wip/base) || base=
  if [ -n "$base" ] && ! local_changed; then return 0; fi
  snap=$(if [ -n "$base" ]; then echo "$base"; snap_lineage "$base"; fi | make_snapshot)
  g update-ref refs/wip/base "$snap"
  printf '%s\n' "$STATE" > "$WIP/base.state"
}

# refs/wip/$1/* := snapshot $2 and the branches it recorded (a published layer).
set_layer() {
  local ref sha
  g for-each-ref --format='delete %(refname)' "refs/wip/$1" | g update-ref --stdin
  [ -n "${2:-}" ] || return 0
  g update-ref "refs/wip/$1/snap" "$2"
  while read -r _ ref sha; do
    if g cat-file -e "$sha" 2> /dev/null; then g update-ref "refs/wip/$1/heads/${ref#refs/heads/}" "$sha"; fi
  done < <(snap_state "$2" | grep '^branch: ' || true)
}

size_of() { if [ -f "$1" ]; then stat -c %s "$1"; else echo 0; fi; }

# Write a layer: refs/wip/snap + branches, minus every object in the layers
# named in $2... (refs/wip/<layer>/*). `git bundle create --not` can't do this: it
# only drops what's reachable through commit ancestry, and a snapshot doesn't
# descend from the one below it, so the base's untracked files would be packed
# again. Instead: the objects a full bundle would need, minus those layers', packed
# under a v2 bundle header that lists the layers as prerequisites. Uses publish's
# `origin`/`not_origin`.
write_delta() {  # $1 = bundle to write, rest = layers beneath it
  local out=$1 d l
  local -a below=()
  shift
  for l in "$@"; do below+=(--glob="refs/wip/$l/*"); done
  d=$(mktemp -d "$CACHE/delta.XXXXXX")
  g rev-list --objects --objects-edge refs/wip/snap --branches \
    --not "${below[@]}" "${origin[@]}" > "$d/want"
  g rev-list --objects "${below[@]}" "${not_origin[@]}" | cut -d' ' -f1 | sort -u > "$d/have"
  grep -v '^-' "$d/want" | cut -d' ' -f1 | sort -u | comm -23 - "$d/have" > "$d/send"
  {
    grep '^-' "$d/want" | cut -d' ' -f1 | cut -c2-
    for l in "$@"; do g for-each-ref --format='%(objectname)' "refs/wip/$l"; done
  } | sort -u > "$d/prereq"
  {
    echo '# v2 git bundle'
    sed 's/^/-/' "$d/prereq"
    g for-each-ref --format='%(objectname) %(refname)' refs/wip/snap refs/heads
    echo
    g pack-objects --stdout -q < "$d/send"
  } > "$out"
  rm -rf "$d"
}

# Publish refs/wip/base. After applying a peer's snapshot that's the peer's own
# snapshot, so the peer sees "same as mine" rather than something new. On a
# metered network only the top layer is written, and only if it's at most
# METERED_MAX_BYTES; anything bigger waits for a better network.
publish() {
  local snap dir f prev pub mid tmp='' write='' total
  local -a origin=() not_origin=()
  snap=$(g rev-parse -q --verify refs/wip/base) || return 0
  dir=$HUB/$SLUG
  f=$dir/$GIT_WIP_HOST
  if [ -f "$f.top.bundle" ]; then prev=$(bundle_head "$f.top.bundle" refs/wip/snap)
  elif [ -f "$f.snap.bundle" ]; then prev=$(bundle_head "$f.snap.bundle" refs/wip/snap)
  else prev=$(bundle_head "$f.base.bundle" refs/wip/pub/snap)
  fi
  [ "$prev" != "$snap" ] || return 0

  mkdir -p "$dir"
  [ -f "$dir/KEY" ] || printf '%s\n' "$KEY" > "$dir/KEY"
  if [ -n "$(g for-each-ref --count=1 refs/remotes/origin)" ]; then
    origin=(--remotes=origin)
    not_origin=(--not --remotes=origin)
  fi
  # Layer on only what's actually in the hub.
  pub=$(g rev-parse -q --verify refs/wip/pub/snap) || pub=
  [ -z "$pub" ] || [ "$(bundle_head "$f.base.bundle" refs/wip/pub/snap)" = "$pub" ] || pub=
  mid=$(g rev-parse -q --verify refs/wip/mid/snap) || mid=
  [ -n "$pub" ] && [ -n "$mid" ] && [ "$(bundle_head "$f.snap.bundle" refs/wip/snap)" = "$mid" ] || mid=

  prev=$(g rev-parse -q --verify refs/wip/snap) || prev=
  g update-ref refs/wip/snap "$snap"
  # Staged outside the Nextcloud tree and renamed in (~/.cache and ~/Documents
  # share a filesystem on every host), so the client never sees a partial file.
  tmp=$(mktemp "$CACHE/bundle.XXXXXX"); rm -f "$tmp"
  if [ -z "$pub" ]; then
    write=base
  elif [ "$GIT_WIP_METERED" = 1 ] && [ -n "$mid" ]; then
    write=top
    write_delta "$tmp" pub mid
  else
    write=snap
    write_delta "$tmp" pub
    # Rebase once the layer is over 2 MB and a quarter of the base: the current
    # snapshot becomes the base, so its bulk goes up once rather than on every
    # later edit.
    if [ "$GIT_WIP_METERED" != 1 ] && [ "$(size_of "$tmp")" -gt "$REBASE_MIN_BYTES" ] \
       && [ $(( $(size_of "$tmp") * 4 )) -gt "$(size_of "$f.base.bundle")" ]; then
      write=base
    fi
  fi
  if [ "$write" = base ]; then
    rm -f "$tmp"
    set_layer pub "$snap"
    g bundle create -q "$tmp" --glob='refs/wip/pub/*' "${not_origin[@]}"
  fi

  total=$(size_of "$tmp")
  if [ "$GIT_WIP_METERED" = 1 ] && [ "$total" -gt "$METERED_MAX_BYTES" ]; then
    rm -f "$tmp"
    if [ -n "$prev" ]; then g update-ref refs/wip/snap "$prev"; else g update-ref -d refs/wip/snap; fi
    printf '%s\n' "$total" > "$WIP/held"
    log "$NAME: holding $((total / 1024)) KB until off the metered network"
    return 0
  fi
  rm -f "$WIP/held"
  mv -f "$tmp" "$f.$write.bundle"
  case $write in
    base) rm -f "$f.snap.bundle" "$f.top.bundle"; set_layer mid ;;
    snap) rm -f "$f.top.bundle"; set_layer mid "$snap" ;;
  esac
  rm -f "$f.bundle"                              # the old single-bundle format
  touch "$CACHE/published"
}

peers() {  # hosts with bundles for this repo, other than us
  local f p
  for f in "$HUB/$SLUG"/*.bundle; do
    [ -f "$f" ] || continue
    p=${f##*/}
    p=${p%.bundle}
    case $p in *.base | *.snap | *.top) p=${p%.*} ;; *) continue ;; esac
    # Also skips Nextcloud's "(conflicted copy …)" duplicates.
    [[ $p =~ ^[a-z0-9-]+$ ]] && [ "$p" != "$GIT_WIP_HOST" ] && echo "$p"
  done | sort -u
}

sync_repo() {  # $1 = repo path, $2 = full|export
  local mode=$2 peer
  open_repo "$1" || return 0
  [ "$(g config --type=bool --get wip.enable || echo true)" = true ] || return 0
  if busy; then log "$NAME: git operation in progress, skipped"; return 0; fi
  if grep -qxF "$KEY" "$CACHE/keys" 2> /dev/null; then
    log "$NAME: another clone of $KEY already synced this run, skipped"
    return 0
  fi
  echo "$KEY" >> "$CACHE/keys"
  compute_state || { log "$NAME: no commits yet or unmerged paths, skipped"; return 0; }

  if [ "$mode" = full ]; then
    for peer in $(peers); do import_peer "$peer"; done
  fi
  export_state
  publish
}

# NetworkManager's verdict on NixOS (Android hotspots flag themselves; mark any
# other connection metered in GNOME Settings). macOS has no shell-visible flag,
# so an iPhone Personal Hotspot is recognised by its fixed gateway. Overridden
# by `git wip metered on|off`; Crostini, which can't see ChromeOS's network,
# relies on that.
detect_metered() {
  local v gw
  case $(cat "$CACHE/metered" 2> /dev/null) in
    on) return 0 ;;
    off) return 1 ;;
  esac
  if [ "$(uname -s)" = Darwin ]; then
    gw=$(/sbin/route -n get default 2> /dev/null | awk '/gateway:/ { print $2 }')
    [ "$gw" = 172.20.10.1 ]
    return
  fi
  v=$(dbus-send --system --print-reply=literal --dest=org.freedesktop.NetworkManager \
        /org/freedesktop/NetworkManager org.freedesktop.DBus.Properties.Get \
        string:org.freedesktop.NetworkManager string:Metered 2> /dev/null | awk '{ print $NF }') || return 1
  [ "$v" = 1 ] || [ "$v" = 3 ]                 # NM_METERED_YES, NM_METERED_GUESS_YES
}

# Decided once per run; the per-repo processes inherit it.
init_metered() {
  if [ -n "${GIT_WIP_METERED:-}" ]; then return 0; fi
  if detect_metered; then GIT_WIP_METERED=1; else GIT_WIP_METERED=0; fi
  export GIT_WIP_METERED
}

run_repos() {  # $1 = full|export, rest = repo paths
  local mode=$1 repo
  shift
  : > "$CACHE/keys"
  rm -f "$CACHE/published"
  if [ ! -d "$HUB" ]; then
    [ -d "$(dirname "$HUB")" ] || { log "$(dirname "$HUB") missing — is Nextcloud set up?"; return 0; }
    mkdir -p "$HUB"
  fi
  for repo in "$@"; do
    # A process per repo, so one repo's failure (set -e) can't stop the rest.
    "$SELF" --repo "$repo" "$mode" \
      || notice "${repo#"$ROOT"/}" "sync failed — see the git-wip log"
  done
  flush_notices
}

all_repos() {
  [ -d "$ROOT" ] || return 0
  find "$ROOT" -maxdepth 6 -type d \( -name node_modules -o -name .direnv -o -name target \) -prune \
    -o -type d -name .git -prune -print \
    | sed 's|/\.git$||'
}

# ── commands ────────────────────────────────────────────────────────────────────

cmd_sync() {
  local -a repos
  init_metered
  if [ "${1:-}" = --all ]; then
    take_lock 0 || exit 0                        # a run is already going
    mapfile -t repos < <(all_repos)
  else
    take_lock 120 || die "another git-wip run is still going"
    repos=("$PWD")
  fi
  run_repos full "${repos[@]}"
}

cmd_pre_sleep() {
  local -a repos
  init_metered
  take_lock 30 || exit 0
  mapfile -t repos < <(all_repos)
  run_repos export "${repos[@]}"
  if [ -e "$CACHE/published" ]; then sleep "$SETTLE_SECONDS"; fi
}

cmd_status() {
  local base peer snap rel when f
  init_metered
  open_repo "$PWD" || die "not in a git repository"
  compute_state || die "no commits yet, or unmerged paths"
  base=$(g rev-parse -q --verify refs/wip/base) || base=
  echo "$NAME ($KEY)"
  if [ -z "$base" ]; then echo "  here:  not synced yet"
  elif local_changed; then echo "  here:  changed since the last sync (published on the next run)"
  else echo "  here:  in sync"
  fi
  f=$HUB/$SLUG/$GIT_WIP_HOST
  echo "  published: base $(( $(size_of "$f.base.bundle") / 1024 )) KB, snap $(( $(size_of "$f.snap.bundle") / 1024 )) KB, top $(( $(size_of "$f.top.bundle") / 1024 )) KB"
  if [ -s "$WIP/held" ]; then
    echo "  held: $(( $(cat "$WIP/held") / 1024 )) KB waits for an unmetered network"
  fi
  [ "$GIT_WIP_METERED" = 0 ] || echo "  network: metered (git wip metered off to override)"
  for peer in $(peers); do
    snap=$(g rev-parse -q --verify "refs/wip/$peer/snap") || snap=
    if [ -z "$snap" ]; then echo "  $peer: not fetched yet"; continue; fi
    when=$(snap_field "$snap" time)
    if [ -e "$WIP/conflict.$peer" ]; then rel="DIVERGED — git wip take $peer, or git wip keep"
    elif [ "$snap" = "$base" ]; then rel="same as here"
    elif [ -n "$base" ] && in_lineage "$snap" "$base"; then rel="older than here"
    elif [ -n "$base" ] && in_lineage "$base" "$snap"; then rel="newer — applied on the next sync"
    else rel="not compared yet"
    fi
    echo "  $peer: $rel (snapshot $when)"
  done
  [ ! -s "$WIP/skipped" ] || echo "  not synced (over 50 MB): $(paste -sd, "$WIP/skipped")"
  echo "  backups: $(g for-each-ref refs/wip/backup | wc -l) (git wip undo restores the newest)"
}

cmd_take() {  # adopt a peer's state wholesale; ours becomes a backup
  local peer=${1:-} snap
  init_metered
  [ -n "$peer" ] || die "usage: git wip take <host>"
  take_lock 120 || die "another git-wip run is still going"
  open_repo "$PWD" || die "not in a git repository"
  snap=$(g rev-parse -q --verify "refs/wip/$peer/snap") || die "nothing from $peer — run git wip sync first"
  compute_state || die "no commits yet, or unmerged paths"
  apply_snapshot "$snap" "$peer" mirror
  adopt "$snap"
  rm -f "$WIP/conflict.$peer"
  publish
  flush_notices
}

cmd_keep() {  # keep our state and publish it as newer than the peers' diverged work
  local -a peers=("$@")
  local base snap peer f
  init_metered
  take_lock 120 || die "another git-wip run is still going"
  open_repo "$PWD" || die "not in a git repository"
  compute_state || die "no commits yet, or unmerged paths"
  if [ ${#peers[@]} -eq 0 ]; then
    for f in "$WIP"/conflict.*; do [ -e "$f" ] && peers+=("${f##*/conflict.}"); done
  fi
  base=$(g rev-parse -q --verify refs/wip/base) || base=
  snap=$(
    {
      if [ -n "$base" ]; then echo "$base"; snap_lineage "$base"; fi
      for peer in "${peers[@]}"; do
        f=$(g rev-parse -q --verify "refs/wip/$peer/snap") || continue
        echo "$f"; snap_lineage "$f"
      done
    } | make_snapshot
  )
  g update-ref refs/wip/base "$snap"
  printf '%s\n' "$STATE" > "$WIP/base.state"
  for peer in "${peers[@]}"; do rm -f "$WIP/conflict.$peer"; done
  publish
  log "$NAME: kept this machine's state; other machines follow on their next sync"
}

cmd_undo() {  # restore the state from before the last automatic overwrite
  local ref snap
  take_lock 120 || die "another git-wip run is still going"
  open_repo "$PWD" || die "not in a git repository"
  ref=$(g for-each-ref --sort=-refname --count=1 --format='%(refname)' refs/wip/backup)
  [ -n "$ref" ] || die "no backups in this repo"
  snap=$(g rev-parse "$ref")
  compute_state || die "no commits yet, or unmerged paths"
  apply_snapshot "$snap" backup mirror           # saves the current state first
  g update-ref -d "$ref"
  rm -f "$WIP/applied"
  flush_notices
}

cmd_prompt() {  # for starship: prints nothing unless there's something to say
  local gd f
  gd=$(git rev-parse --absolute-git-dir 2> /dev/null) || return 0
  for f in "$gd"/wip/conflict.*; do
    [ -e "$f" ] && { printf '⚠ wip diverged'; return 0; }
  done
  if [ -n "$(find "$gd/wip/applied" -mmin -60 2> /dev/null)" ]; then
    printf '⇄ %s' "$(cat "$gd/wip/applied")"
  fi
}

cmd_metered() {
  case ${1:-} in
    on | off) echo "$1" > "$CACHE/metered" ;;
    auto) rm -f "$CACHE/metered" ;;
    "") ;;
    *) die "usage: git wip metered [on|off|auto]" ;;
  esac
  if detect_metered; then echo "metered"; else echo "not metered"; fi
  [ ! -f "$CACHE/metered" ] || echo "(forced $(cat "$CACHE/metered"); git wip metered auto to detect)"
}

usage() {
  cat << 'EOF'
usage: git wip <command>

  sync [--all]   sync this repo (or every repo under ~/Repos) now
  status         this repo's sync state against the other machines
  take <host>    replace this repo's state with <host>'s (after a divergence)
  keep [host]    keep this machine's state; the other machines follow it
  undo           restore the state from before the last automatic change
  pre-sleep      publish every repo now (run by the sleep hooks)
  metered [on|off|auto]
                 force metered-network behaviour on or off, or detect it (default)

Runs automatically every minute. On a metered network only uploads up to 1 MB
go out; bigger ones wait. Opt a repo out: git config wip.enable false
EOF
}

case ${1:-help} in
  sync)      shift; cmd_sync "$@" ;;
  status)    cmd_status ;;
  take)      shift; cmd_take "$@" ;;
  keep)      shift; cmd_keep "$@" ;;
  undo)      cmd_undo ;;
  pre-sleep) cmd_pre_sleep ;;
  prompt)    cmd_prompt ;;
  metered)   shift; cmd_metered "$@" ;;
  --repo)    init_metered; sync_repo "$2" "$3" ;;
  help | -h | --help) usage ;;
  *)         usage >&2; exit 2 ;;
esac
