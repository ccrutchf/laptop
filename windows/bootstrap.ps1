<#
.SYNOPSIS
  One-time setup of the Windows laptop: cross-platform git settings, the sync
  scripts, and the Scheduled Task that runs them.

.DESCRIPTION
  Run once, from this repo, in a NORMAL (non-admin) PowerShell:

      cd $HOME\Repos\personal\laptop
      powershell -ExecutionPolicy Bypass -File .\windows\bootstrap.ps1

  Idempotent — safe to re-run after pulling repo changes, which is how you update
  the scripts on this machine.

  Not admin: the task runs as you, and needs no elevation. Developer Mode (for
  symlinks) is the one thing it can only tell you about.
#>
[CmdletBinding()]
param(
  [string]$Hub      = 'ogre01',
  [string]$HubPath  = '/mnt/data/srv',
  [string]$Root     = "$env:USERPROFILE\Repos",
  [int]$IntervalMinutes = 10,
  [string]$SshOpts = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'git-sync'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'git-sync.ps1') $InstallDir
Copy-Item -Force (Join-Path $PSScriptRoot 'git-wip.ps1')  $InstallDir
Write-Host "installed scripts -> $InstallDir"

# --- git settings that make repos portable across the three laptops -----------
# autocrlf=true: CRLF in the working tree for Visual Studio, LF in the object
# store, so the NixOS and macOS checkouts see normal Unix line endings.
& git config --global core.autocrlf true
# NTFS has no exec bit; without this every file looks mode-changed to the others.
& git config --global core.fileMode false
# Git's own 260-char path limit, independent of the Windows one.
& git config --global core.longpaths true
& git config --global core.symlinks true
& git config --global alias.wip "!powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\git-wip.ps1`""
Write-Host 'configured git (autocrlf/fileMode/longpaths/symlinks/alias.wip)'

# --- warn about the things this script genuinely cannot fix -------------------
$key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if (-not (Test-Path -LiteralPath $key)) {
  Write-Warning "no $key — restore the Nextcloud-synced SSH key here, or the hub will refuse every connection."
} else {
  # OpenSSH refuses a key readable by anyone else. Reset the ACL to just you.
  & icacls $key /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
  Write-Host 'ssh key present, permissions tightened'
}
$devMode = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
             -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
if (-not $devMode -or $devMode.AllowDevelopmentWithoutDevLicense -ne 1) {
  Write-Warning 'Developer Mode is off — git symlinks in a repo will check out as plain files. Settings > System > For developers.'
}

# --- the Scheduled Task -------------------------------------------------------
$TaskName = 'git-sync'
$argList = @(
  '-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
  '-File', "`"$InstallDir\git-sync.ps1`"",
  '-Hub', $Hub, '-HubPath', $HubPath, '-Root', "`"$Root`"", '-HostTag', $env:COMPUTERNAME.ToLower()
)
# Quoted as ONE argument: -File passes literals through without comma-splitting,
# so the script receives the whole option string and splits it itself.
if ($SshOpts) { $argList += @('-SshOpts', "`"$SshOpts`"") }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
# AtLogOn covers the window missed while the machine was off; the repeating
# trigger is what actually keeps it converged. Repetition runs indefinitely.
$t1 = New-ScheduledTaskTrigger -AtLogOn
$t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
              -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
  -Settings $settings -Description 'Sync git repos to the hub' -Force | Out-Null
Write-Host "registered Scheduled Task '$TaskName' (every $IntervalMinutes min, and at logon)"

Write-Host ''
Write-Host 'Done. Force a sync now with:'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$InstallDir\git-sync.ps1`""
Write-Host "Logs: $InstallDir\git-sync.log"
