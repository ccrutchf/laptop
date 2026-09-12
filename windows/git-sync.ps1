<#
.SYNOPSIS
  Windows port of home/git-sync.nix — snapshots every git repo to the hub.

.DESCRIPTION
  Same model as the Nix-managed hosts, and deliberately the same on-hub layout so
  all three laptops share one fabric:

    <Root>\personal\laptop  ->  hub:<HubPath>/personal/laptop.git
    refs/heads/*                real branches, fast-forward pushes only
    refs/wip/<host>/<branch>    working-tree snapshot, incl. uncommitted+untracked

  The snapshot is built through a THROWAWAY index (GIT_INDEX_FILE) using git
  plumbing, so HEAD, the real index, the stash and the working tree are never
  touched. Nothing is ever merged into your tree; `git wip` does that on demand.

  `origin` is never written to — WIP goes only to the `hub` remote, so a repo
  whose origin is a public GitHub repo can't leak half-finished work.

  Windows differs from the Nix hosts in one way that matters: there is no flock,
  so the lock is a file created with CreateNew (atomic on NTFS).

.NOTES
  Driven by a Scheduled Task registered by bootstrap.ps1. Run it by hand any time
  to force a sync now.
#>
[CmdletBinding()]
param(
  [string]$Hub     = $(if ($env:GIT_SYNC_HUB)      { $env:GIT_SYNC_HUB }      else { 'ogre01' }),
  [string]$HubPath = $(if ($env:GIT_SYNC_HUB_PATH) { $env:GIT_SYNC_HUB_PATH } else { '/mnt/data/srv' }),
  [string]$Root    = $(if ($env:GIT_SYNC_ROOT)     { $env:GIT_SYNC_ROOT }     else { "$env:USERPROFILE\Repos" }),
  [string]$HostTag = $(if ($env:GIT_SYNC_HOST)     { $env:GIT_SYNC_HOST }     else { $env:COMPUTERNAME.ToLower() }),
  # A single whitespace-separated string, NOT a string[]: PowerShell's -File mode
  # passes every argument as a literal string and does not comma-split into an
  # array, so an array parameter arrives as one broken token. This matches the
  # GIT_SYNC_SSH_OPTS contract on the Nix hosts.
  [string]$SshOpts = $(if ($env:GIT_SYNC_SSH_OPTS) { $env:GIT_SYNC_SSH_OPTS } else { '' }),
  [int]$MaxNewFiles = 2000,
  [long]$MaxFileBytes = 104857600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # one bad repo must not abort the whole run

$State = Join-Path $env:LOCALAPPDATA 'git-sync'
New-Item -ItemType Directory -Force -Path $State | Out-Null

function Write-Log { param([string]$Message)
  $line = "{0}  {1}" -f (Get-Date -Format o), $Message
  Write-Host $line
  Add-Content -LiteralPath (Join-Path $State 'git-sync.log') -Value $line
}

# Invoke git and hand back stdout + success, without letting a non-zero exit code
# turn into a terminating error.
#
# $GitArgs is an explicit array and every call site MUST pass one. Splatting bare
# words instead lets PowerShell try to bind a leading dash as one of this
# function's own parameters — `-p` matches both -ProgressAction and
# -PipelineVariable and fails as ambiguous before git ever sees it.
function Invoke-Git { param([string]$Dir, [string[]]$GitArgs)
  $out = & git -C $Dir @GitArgs 2>&1
  return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = ($out | Out-String).Trim() }
}

# --- single-instance lock -----------------------------------------------------
# No flock on Windows; [IO.File]::Open with CreateNew is atomic, and the handle
# dying with the process means a crashed run can't wedge the lock forever.
$lockPath = Join-Path $State 'run.lock'
try {
  $lock = [System.IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None')
} catch {
  # Stale lock from a killed process: if nothing holds it, Open succeeds after we
  # delete it. If something does, the delete fails and we correctly back off.
  try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        $lock = [System.IO.File]::Open($lockPath, 'CreateNew', 'Write', 'None') }
  catch { Write-Log 'another git-sync is running; skipping'; exit 0 }
}

try {
  if (-not (Test-Path -LiteralPath $Root)) { Write-Log "no $Root on this host; nothing to do"; exit 0 }

  # One multiplexed connection for the run would be ideal, but Win32 OpenSSH has
  # no ControlMaster. Each git call pays its own handshake; with a handful of
  # repos that is fine, and it keeps this portable to stock Windows.
  $extra = if ($SshOpts) { $SshOpts -split '\s+' | Where-Object { $_ } } else { @() }
  $sshArgs = @('-o','BatchMode=yes','-o','ConnectTimeout=10') + $extra
  $env:GIT_SSH_COMMAND = "ssh " + ($sshArgs -join ' ')

  & ssh @sshArgs $Hub 'true' 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    # Off the network, or the hub is down. Nothing is lost; the next tick catches up.
    Write-Log "hub $Hub unreachable; will retry next tick"
    exit 0
  }

  # Walk for repos, stopping the descent at each .git so submodules and nested
  # checkouts are not visited twice.
  $repos = New-Object System.Collections.Generic.List[string]
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue((Resolve-Path -LiteralPath $Root).Path)
  while ($queue.Count -gt 0) {
    $d = $queue.Dequeue()
    if (Test-Path -LiteralPath (Join-Path $d '.git')) { $repos.Add($d); continue }
    foreach ($sub in (Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue)) {
      if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }  # don't follow junctions
      $queue.Enqueue($sub.FullName)
    }
  }

  foreach ($dir in ($repos | Sort-Object)) {
    $rel = $dir.Substring((Resolve-Path -LiteralPath $Root).Path.Length).TrimStart('\','/').Replace('\','/')
    $g = Join-Path $dir '.git'

    # Never interfere with an operation in flight.
    $busy = @('index.lock','rebase-merge','rebase-apply','MERGE_HEAD','CHERRY_PICK_HEAD','BISECT_LOG') |
              Where-Object { Test-Path -LiteralPath (Join-Path $g $_) }
    if ($busy) { Write-Log "${rel}: operation in progress, skipping"; continue }

    # Adopt: create the bare repo on the hub, then point a `hub` remote at it.
    # origin, if the repo has one, is left exactly as it is.
    if (-not (Invoke-Git $dir @('remote','get-url','hub')).Ok) {
      $remoteCmd = 'read -r d && mkdir -p "$d" && { [ -e "$d/HEAD" ] || git init --bare -q -b main "$d"; }'
      "$HubPath/$rel.git" | & ssh @sshArgs $Hub $remoteCmd
      if ($LASTEXITCODE -ne 0) { Write-Log "${rel}: could not provision on hub"; continue }
      if (-not (Invoke-Git $dir @('remote','add','hub',"${Hub}:$HubPath/$rel.git")).Ok) {
        Write-Log "${rel}: could not add hub remote"; continue
      }
      Write-Log "${rel}: adopted -> ${Hub}:$HubPath/$rel.git"
    }

    $branch = (Invoke-Git $dir @('symbolic-ref','--quiet','--short','HEAD')).Out
    if (-not $branch) { $branch = 'detached' }
    $headRes = Invoke-Git $dir @('rev-parse','--quiet','--verify','HEAD')
    $head = if ($headRes.Ok) { $headRes.Out } else { '' }

    # --- snapshot into a throwaway index -------------------------------------
    $tmpIndex = Join-Path $State ("index." + [guid]::NewGuid().ToString('N'))
    $tree = $null
    try {
      $env:GIT_INDEX_FILE = $tmpIndex
      # Empty-tree object stands in for HEAD in a repo with no commits yet.
      $base = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
      if ($head) {
        if (-not (Invoke-Git $dir @('read-tree','HEAD')).Ok) { Write-Log "${rel}: read-tree failed"; continue }
        $base = 'HEAD'
      }
      Invoke-Git $dir @('add','-A') | Out-Null

      $changed = (Invoke-Git $dir @('diff','--cached','--name-only',$base)).Out
      $changedList = if ($changed) { $changed -split "`r?`n" } else { @() }
      if ($changedList.Count -gt $MaxNewFiles) {
        Write-Log "${rel}: $($changedList.Count) changed files (> $MaxNewFiles) — looks like unignored build output, skipping snapshot"
        continue
      }

      # Drop oversized blobs instead of abandoning the snapshot; it is usually a
      # single stray artifact and the rest of the tree is still worth keeping.
      $addedOut = (Invoke-Git $dir @('diff','--cached','--name-only','--diff-filter=A',$base)).Out
      if ($addedOut) {
        foreach ($f in ($addedOut -split "`r?`n")) {
          $full = Join-Path $dir $f
          if (Test-Path -LiteralPath $full -PathType Leaf) {
            $len = (Get-Item -LiteralPath $full).Length
            if ($len -gt $MaxFileBytes) {
              Write-Log "${rel}: excluding $f from snapshot ($len bytes)"
              Invoke-Git $dir @('rm','--cached','--quiet','--force','--',$f) | Out-Null
            }
          }
        }
      }

      $tw = Invoke-Git $dir @('write-tree')
      if ($tw.Ok) { $tree = $tw.Out }
    } finally {
      Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
      Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
    }
    if (-not $tree) { continue }

    # Nothing moved since last run: just refresh remote-tracking refs and move on.
    $stateFile = Join-Path $State (($rel -replace '[\\/]', '_') + '.state')
    $prev = if (Test-Path -LiteralPath $stateFile) { (Get-Content -LiteralPath $stateFile -Raw).Trim() } else { '' }
    $now = "$tree $head"
    if ($prev -eq $now) {
      Invoke-Git $dir @('fetch','--quiet','--prune','hub','+refs/heads/*:refs/remotes/hub/*','+refs/wip/*:refs/remotes/wip/*') | Out-Null
      continue
    }

    $msg = "wip@$HostTag {0} [$branch]" -f (Get-Date -Format o)
    $ct = if ($head) { Invoke-Git $dir @('commit-tree','-p',$head,'-m',$msg,$tree) }
          else       { Invoke-Git $dir @('commit-tree','-m',$msg,$tree) }
    if (-not $ct.Ok) { Write-Log "${rel}: commit-tree failed"; continue }
    $commit = $ct.Out

    # Force is safe: refs/wip/<host>/... is this machine's own namespace, so it
    # only ever overwrites its own previous snapshot.
    if (-not (Invoke-Git $dir @('push','--quiet','--force','hub',"${commit}:refs/wip/$HostTag/$branch")).Ok) {
      Write-Log "${rel}: wip push failed"; continue
    }
    # Real branches/tags are NOT forced: a divergence fails harmlessly and is left
    # for you to resolve rather than being silently clobbered.
    Invoke-Git $dir @('push','--quiet','hub','refs/heads/*:refs/heads/*') | Out-Null
    Invoke-Git $dir @('push','--quiet','--tags','hub') | Out-Null
    Invoke-Git $dir @('fetch','--quiet','--prune','hub','+refs/heads/*:refs/remotes/hub/*','+refs/wip/*:refs/remotes/wip/*') | Out-Null

    Set-Content -LiteralPath $stateFile -Value $now -NoNewline
    Write-Log "${rel}: synced ($branch)"
  }
} finally {
  if ($lock) { $lock.Close(); Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
