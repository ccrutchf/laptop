<#
.SYNOPSIS
  Windows port of the `git wip` helper — read another laptop's snapshot.

.DESCRIPTION
  git-sync pushes and fetches on a timer. Pulling another machine's work INTO
  your tree is deliberately a command you type: a background job mutating a tree
  you may be mid-edit in is exactly the surprise this design avoids.

    git wip list           what snapshots exist here, and how old
    git wip diff <host>    what that machine has that you don't
    git wip log <host>     commits on that machine's branch
    git wip take <host>    check the snapshot out as a local branch

  `take` requires a clean tree and only ever creates a branch.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'list',
  [Parameter(Position = 1)][string]$TargetHost
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { Write-Error 'not a git repo'; exit 1 }

$me = $env:COMPUTERNAME.ToLower()

function Get-WipRef { param([string]$H)
  if (-not $H) { Write-Error 'which host? try: git wip list'; exit 1 }
  $r = (& git for-each-ref --format='%(refname)' "refs/remotes/wip/$H" | Select-Object -First 1)
  if (-not $r) { Write-Error "no snapshot matching '$H' — try: git wip list"; exit 1 }
  return $r
}

switch ($Command) {
  'list' {
    $refs = & git for-each-ref --format='%(refname)' refs/remotes/wip
    if (-not $refs) { Write-Host 'no snapshots fetched yet (is this repo synced? run git-sync)'; break }
    & git for-each-ref --sort=-committerdate `
        --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(subject)' refs/remotes/wip |
      ForEach-Object { if ($_ -like "$me/*") { "$_  (this machine)" } else { $_ } }
  }
  'diff' { & git diff HEAD (Get-WipRef $TargetHost) }
  'log'  { & git log --oneline --graph "HEAD..$(Get-WipRef $TargetHost)" }
  'take' {
    $ref = Get-WipRef $TargetHost
    if (& git status --porcelain) {
      Write-Error 'your tree has uncommitted changes — commit or stash first'; exit 1
    }
    # Keep the host in the branch name, or two machines collide on "wip/main".
    $b = 'wip/' + ($ref -replace '^refs/remotes/wip/', '')
    & git checkout -B $b $ref
    Write-Host "on $b — this is $TargetHost's working tree as of $(& git log -1 --format=%cr $ref)"
  }
  default {
    Write-Host 'usage: git wip [list|diff <host>|log <host>|take <host>]'
    exit 1
  }
}
