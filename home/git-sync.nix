# Automatic, hands-off sync of every git repo across all three laptops.
#
# Why not Nextcloud: the desktop client's non-atomic writes corrupt live `.git`
# trees (same failure mode documented in home/claude-backup.nix and
# modules/nixos/backups.nix), and it has no notion of merging. Git already is a
# sync protocol; the only thing missing was something to drive it on a timer.
#
# The model: a bare-repo hub on the personal Linux server (`my.gitSync.hub`).
# Every repo under ~/Repos gets a `hub` remote pointing there, auto-created on
# first sight. On a timer each machine
#   1. pushes a SNAPSHOT of its working tree (including uncommitted and untracked
#      files) to refs/wip/<host>/<branch> on the hub, and
#   2. fast-forward-pushes its real branches + tags there, and
#   3. fetches everything back, so every other machine's branches and snapshots
#      are locally available as refs/remotes/hub/* and refs/remotes/wip/*.
#
# CRITICAL INVARIANT — this never touches your working state. The snapshot commit
# is built through a THROWAWAY index (GIT_INDEX_FILE) with plumbing
# (read-tree/add/write-tree/commit-tree), so HEAD, the real index, the stash and
# the working tree are never modified. Nothing is ever merged or checked out for
# you; step 3 only populates remote-tracking refs. Pulling another machine's work
# into your tree stays an explicit `git wip` command, because auto-merging into a
# tree you might be mid-edit in is exactly the class of surprise this is meant to
# avoid.
#
# `origin` is never written to. WIP snapshots go ONLY to `hub` — if a repo's
# origin is a public GitHub repo, pushing half-finished work there would publish
# it. The hub is the single sync fabric; origin stays whatever it already was.
#
# Cross-platform: a systemd user timer on Linux, a launchd agent on macOS (same
# script), and a PowerShell port driven by a Scheduled Task on Windows — that one
# is not Nix-managed, see windows/README.md.
{ pkgs, lib, config, ... }:
let
  cfg = config.my.gitSync;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  host = if isDarwin then "chris-macbook" else "chris-laptop";

  # Everything the script shells out to. Both the systemd service and the launchd
  # agent run with a stripped PATH (the same gotcha as the `depend` activation
  # hook in home/linux.nix), so nothing may be assumed present.
  runtimeDeps = with pkgs; [ git openssh coreutils findutils gnugrep gnused util-linux ];

  gitSync = pkgs.writeShellApplication {
    name = "git-sync";
    runtimeInputs = runtimeDeps;
    # The script handles its own errors per-repo: one bad repo must never abort
    # the run over the other forty.
    text = ''
      HUB_SSH=''${GIT_SYNC_HUB:-${cfg.hub}}
      HUB_PATH=''${GIT_SYNC_HUB_PATH:-${cfg.hubPath}}
      ROOT=''${GIT_SYNC_ROOT:-${cfg.root}}
      HOST=''${GIT_SYNC_HOST:-${host}}
      # Extra ssh(1) options for the hub — a non-standard port, a specific
      # identity, a ProxyJump. Word-split, so keep them free of spaces.
      read -r -a EXTRA_SSH <<< "''${GIT_SYNC_SSH_OPTS:-${cfg.sshOptions}}"
      STATE=''${XDG_STATE_HOME:-$HOME/.local/state}/git-sync

      # Safety rails against a repo that forgot to .gitignore its build output:
      # a snapshot that would add more than this many files, or any single file
      # this large, is skipped and logged rather than shipped to the hub.
      MAX_NEW_FILES=''${GIT_SYNC_MAX_NEW_FILES:-2000}
      MAX_FILE_BYTES=''${GIT_SYNC_MAX_FILE_BYTES:-104857600}   # 100 MiB

      mkdir -p "$STATE"

      # stderr, always: the snapshot subshell's stdout carries the tree hash.
      # systemd captures both streams; the launchd agent points both at one file.
      log() { printf '%s  %s\n' "$(date -Is)" "$*" >&2; }

      # stat(1) is incompatible between GNU and BSD; both hosts run this script.
      filesize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

      # Overlapping runs would race on the temp indexes and the hub. A missed tick
      # is free — the next one picks up the same work.
      exec 9>"$STATE/lock"
      if ! flock -n 9; then log "another git-sync is running; skipping"; exit 0; fi

      if [ ! -d "$ROOT" ]; then log "no $ROOT on this host; nothing to do"; exit 0; fi

      # One connection for the whole run: reachability probe now, and every later
      # ssh/git-over-ssh rides the same multiplexed socket. Without this a 40-repo
      # run means 80+ TCP+auth handshakes.
      # A FIXED short name, not ssh's %C token: %C is a 64-char hash and the
      # sun_path limit for a unix socket is 104 bytes, which the expanded
      # $HOME/.local/state/git-sync/ssh-<hash> path lands within one character of.
      # Only one hub and only one run at a time (flock above), so a constant name
      # is unambiguous. Clear any socket a crashed run left behind.
      CTL="$STATE/cm"
      rm -f "$CTL"
      SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10
                -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=60
                "''${EXTRA_SSH[@]}")
      export GIT_SSH_COMMAND="ssh ''${SSH_OPTS[*]}"

      if ! ssh "''${SSH_OPTS[@]}" "$HUB_SSH" true 2>/dev/null; then
        # Expected and fine: laptop is off-network, or the hub is down. Everything
        # is still safe on disk; the next tick that reaches the hub catches up.
        log "hub $HUB_SSH unreachable; will retry next tick"
        exit 0
      fi

      # Create the bare repo on the hub if it isn't there yet. Idempotent, and
      # safe to race with another laptop doing the same thing.
      # The path travels over stdin and the remote command is single-quoted, so
      # nothing is expanded client-side — a repo path containing a space or a
      # quote can't turn into extra words in the remote shell.
      provision() {
        printf '%s\n' "$HUB_PATH/$1.git" \
          | ssh "''${SSH_OPTS[@]}" "$HUB_SSH" \
              'read -r d && mkdir -p "$d" && { [ -e "$d/HEAD" ] || git init --bare -q -b main "$d"; }'
      }

      sync_repo() {
        local dir="$1" rel branch head parent tree commit added big statefile prev
        rel=''${dir#"$ROOT"/}

        # Don't fight an in-progress operation: a rebase/merge/bisect has a
        # deliberately inconsistent tree, and index.lock means git is mid-write.
        local g="$dir/.git"
        if [ -e "$g/index.lock" ] || [ -e "$g/rebase-merge" ] || [ -e "$g/rebase-apply" ] \
           || [ -e "$g/MERGE_HEAD" ] || [ -e "$g/CHERRY_PICK_HEAD" ] || [ -e "$g/BISECT_LOG" ]; then
          log "$rel: operation in progress, skipping"
          return 0
        fi

        # Wire up the hub remote on first sight. `origin`, if any, is not touched.
        if ! git -C "$dir" remote get-url hub >/dev/null 2>&1; then
          if ! provision "$rel"; then log "$rel: could not provision on hub"; return 1; fi
          git -C "$dir" remote add hub "$HUB_SSH:$HUB_PATH/$rel.git" || return 1
          log "$rel: adopted -> $HUB_SSH:$HUB_PATH/$rel.git"
        fi

        branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached")
        head=$(git -C "$dir" rev-parse --quiet --verify HEAD 2>/dev/null || echo "")

        # --- Build the snapshot commit in a throwaway index. -------------------
        # This is the whole trick: GIT_INDEX_FILE redirects every index write to a
        # temp file, so `git add -A` stages the entire working tree WITHOUT
        # touching .git/index or anything the user can see.
        local tmpindex; tmpindex=$(mktemp "$STATE/index.XXXXXX") || return 1
        (
          export GIT_INDEX_FILE="$tmpindex"
          cd "$dir" || exit 1
          # A repo with no commits yet has no HEAD to diff against; git's
          # hardcoded empty-tree object stands in so the guards below still work.
          if [ -n "$head" ]; then
            git read-tree HEAD || exit 1
            base=HEAD
          else
            base=4b825dc642cb6eb9a060e54bf8d69288fbee4904
          fi
          git add -A 2>/dev/null || true

          added=$(git diff --cached --name-only "$base" | wc -l | tr -d ' ')
          if [ "$added" -gt "$MAX_NEW_FILES" ]; then
            log "$rel: $added changed files (> $MAX_NEW_FILES) — looks like unignored build output, skipping snapshot"
            exit 3
          fi

          # Drop oversized blobs rather than aborting: the rest of the snapshot is
          # still worth having, and this is usually one stray artifact.
          while IFS= read -r f; do
            [ -f "$f" ] || continue
            big=$(filesize "$f")
            if [ "$big" -gt "$MAX_FILE_BYTES" ]; then
              log "$rel: excluding $f from snapshot ($big bytes)"
              git rm --cached --quiet --force -- "$f" >/dev/null 2>&1 || true
            fi
          done < <(git diff --cached --name-only --diff-filter=A "$base")

          git write-tree
        ) > "$tmpindex.tree"
        local rc=$?
        tree=$(tail -n1 "$tmpindex.tree" 2>/dev/null || echo "")
        rm -f "$tmpindex" "$tmpindex.tree"
        [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 0

        # Skip the push when nothing moved since last time. Keeps a quiet machine
        # from rewriting the same ref every ten minutes forever.
        statefile="$STATE/$(printf '%s' "$rel" | tr '/' '_').state"
        prev=$(cat "$statefile" 2>/dev/null || echo "")
        if [ "$prev" = "$tree $head" ]; then
          git -C "$dir" fetch --quiet --prune hub \
            "+refs/heads/*:refs/remotes/hub/*" "+refs/wip/*:refs/remotes/wip/*" 2>/dev/null || true
          return 0
        fi

        if [ -n "$head" ]; then parent="-p $head"; else parent=""; fi
        # shellcheck disable=SC2086
        commit=$(git -C "$dir" commit-tree $parent -m "wip@$HOST $(date -Is) [$branch]" "$tree") || return 1

        # Force is correct and safe here: refs/wip/<host>/... is namespaced per
        # machine, so this laptop only ever overwrites its own snapshot. Pushing
        # the commit also carries any local commits you forgot to push, because
        # git sends the objects the ref depends on.
        git -C "$dir" push --quiet --force hub "$commit:refs/wip/$HOST/$branch" 2>/dev/null || {
          log "$rel: wip push failed"; return 1; }

        # Real branches and tags: NOT forced, so a divergence fails harmlessly and
        # is left for you to resolve rather than being silently clobbered.
        git -C "$dir" push --quiet hub "refs/heads/*:refs/heads/*" 2>/dev/null || true
        git -C "$dir" push --quiet --tags hub 2>/dev/null || true

        git -C "$dir" fetch --quiet --prune hub \
          "+refs/heads/*:refs/remotes/hub/*" "+refs/wip/*:refs/remotes/wip/*" 2>/dev/null || true

        printf '%s %s' "$tree" "$head" > "$statefile"
        log "$rel: synced ($branch)"
      }

      # -prune stops the walk at each .git, so submodules and nested checkouts
      # aren't visited twice.
      while IFS= read -r g; do
        d=$(dirname "$g")
        sync_repo "$d" || log "$(basename "$d"): sync failed"
      done < <(find "$ROOT" -type d -name .git -prune 2>/dev/null | sort)

      ssh "''${SSH_OPTS[@]}" -O exit "$HUB_SSH" 2>/dev/null || true
    '';
  };

  # The manual half. git-sync pushes and fetches automatically; pulling another
  # machine's work INTO your tree is deliberately a command you type, because the
  # alternative is a background job mutating a tree you may be mid-edit in.
  gitWip = pkgs.writeShellApplication {
    name = "git-wip";
    runtimeInputs = runtimeDeps;
    text = ''
      usage() {
        cat <<'USAGE'
      git wip — work-in-progress snapshots from your other laptops

        git wip list             what snapshots exist for this repo, and how old
        git wip diff <host>      what that machine has that you don't
        git wip log <host>       commits on that machine's branch
        git wip take <host>      check the snapshot out as a local branch

      `take` needs a clean tree and only ever creates a branch — it will not
      overwrite uncommitted work. Snapshots are pushed by the git-sync timer;
      run `git-sync` by hand to force one now.
      USAGE
      }

      git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 1; }

      cmd=''${1:-list}; shift || true

      case "$cmd" in
        list)
          # Nothing fetched yet is the common first-run case; say so plainly
          # instead of printing an empty list that looks like a bug.
          if [ -z "$(git for-each-ref --format='%(refname)' refs/remotes/wip 2>/dev/null)" ]; then
            echo "no snapshots fetched yet (is this repo synced? run git-sync)"
            exit 0
          fi
          git for-each-ref --sort=-committerdate \
            --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(subject)' \
            refs/remotes/wip \
            | sed "s|^${host}/\([^	]*\)|${host}/\1 (this machine)|"
          ;;
        diff|log|take)
          h=''${1:-}
          [ -n "$h" ] || { echo "which host? try: git wip list" >&2; exit 1; }
          # Accept either "chris-macbook" or the full "chris-macbook/main".
          ref=$(git for-each-ref --format='%(refname)' "refs/remotes/wip/$h" | head -n1)
          [ -n "$ref" ] || { echo "no snapshot matching '$h' — try: git wip list" >&2; exit 1; }
          case "$cmd" in
            diff) git diff HEAD "$ref" ;;
            log)  git log --oneline --graph HEAD.."$ref" ;;
            take)
              if [ -n "$(git status --porcelain)" ]; then
                echo "your tree has uncommitted changes — commit or stash first" >&2
                exit 1
              fi
              # Keep the host in the branch name: basename alone gives "wip/main"
              # for every machine, so taking from a second one would collide.
              b="wip/''${ref#refs/remotes/wip/}"
              git checkout -B "$b" "$ref"
              echo "on $b — this is $h's working tree as of $(git log -1 --format=%cr "$ref")"
              ;;
          esac
          ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
      esac
    '';
  };
in
{
  options.my.gitSync = {
    enable = lib.mkEnableOption "automatic git repo sync via a bare-repo hub" // { default = true; };

    hub = lib.mkOption {
      type = lib.types.str;
      default = "ogre01";
      description = ''
        SSH destination of the hub, as ssh(1) resolves it — an alias from
        ~/.ssh/config or a real hostname. NOTE: `ogre01` only resolves on the home
        LAN, so sync pauses when you travel. Once the server is reachable from
        outside, point this (or the ~/.ssh/config Host block) at the public name
        and it works everywhere with no other change.
      '';
    };

    sshOptions = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Extra ssh(1) options used to reach the hub, e.g. "-p 2222" or
        "-i /home/chris/.ssh/hub_ed25519". Word-split on spaces, so each option
        and its value are separate words and none may contain a space.
      '';
    };

    hubPath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/srv";
      description = "Directory on the hub holding the bare repos, mirroring the ~/Repos layout.";
    };

    root = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Repos";
      description = "Tree that is walked for repos to sync.";
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Minutes between sync runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ gitSync gitWip ];

    # Makes `git wip ...` work as a subcommand, not just `git-wip`.
    programs.git.settings.alias.wip = "!git-wip";

    # Regenerable junk that must never reach a snapshot. Repo-level .gitignore
    # still wins, so a repo that legitimately tracks one of these can un-ignore it.
    programs.git.settings.core.excludesFile =
      let f = pkgs.writeText "gitignore-global" ''
        .direnv/
        result
        result-*
        .DS_Store
        Thumbs.db
        *~
        *.swp
        __pycache__/
        .venv/
      ''; in "${f}";

    # Cross-platform hygiene. These matter the moment a repo is shared with the
    # Windows laptop: LF in the object store regardless of what the checkout looks
    # like, and no phantom mode diffs from a filesystem with no exec bit.
    programs.git.settings.core.autocrlf = "input";
    programs.git.settings.core.fileMode = true;

    # See home/claude-backup.nix for why this is mkIf and not optionalAttrs: making
    # the SET of option paths depend on `pkgs` is an infinite recursion in the
    # module fixpoint. mkIf keeps the paths static and defers only the value.
    systemd.user.services.git-sync = lib.mkIf (!isDarwin) {
      Unit.Description = "Sync git repos to the hub";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe gitSync;
      };
    };
    systemd.user.timers.git-sync = lib.mkIf (!isDarwin) {
      Unit.Description = "Periodic git repo sync";
      Timer = {
        OnBootSec = "2m";
        OnUnitActiveSec = "${toString cfg.interval}m";
        Persistent = true;   # catch up immediately after resume from suspend
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # launchd has no Persistent catch-up; RunAtLoad covers the window missed while
    # the lid was shut, and StartInterval is wall-clock so it resumes on wake.
    launchd.agents.git-sync = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe gitSync) ];
        StartInterval = cfg.interval * 60;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/git-sync.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/git-sync.log";
      };
    };
  };
}
