<#
.SYNOPSIS
  Undoes edge-block.ps1. Puts back every value it changed, then Edge can install and update again.

.DESCRIPTION
  Reads %ProgramData%\EdgeBlocker\backup.json (written by edge-block.ps1):
  - a value that existed before gets its old value back,
  - a value that did not exist before is removed,
  - a registry key the block script created is removed if it is now empty,
  - the Edge helper service gets its old startup type back.
  Without a backup file it removes exactly the values edge-block.ps1 sets and
  sets the service back to Manual (the Windows default).

  The backup file is not trusted: only the values and the service that edge-block.ps1 changes
  are ever touched, whatever the file says.

.PARAMETER WhatIf
  Dry run. Prints every change it would make and changes nothing.

.PARAMETER DryRun
  Same as -WhatIf.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-unblock.ps1 -WhatIf
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-unblock.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$dry = [bool]$DryRun -or [bool]$WhatIfPreference
$WhatIfPreference = $false

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$UpdateKey = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
$Service   = 'MicrosoftEdgeElevationService'
$Backup    = Join-Path (Join-Path $env:ProgramData 'EdgeBlocker') 'backup.json'

# The only values this script may touch.
$Ours = @()
foreach ($id in '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', '{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}',
                '{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}', '{65C35B14-6C1D-4122-AC46-7148CC9D6497}',
                '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
  $Ours += [pscustomobject]@{ key = $PolicyKey; name = "Install$id" }
  $Ours += [pscustomobject]@{ key = $PolicyKey; name = "Update$id" }
}
$Ours += [pscustomobject]@{ key = $PolicyKey; name = 'CreateDesktopShortcutDefault' }
$Ours += [pscustomobject]@{ key = $UpdateKey; name = 'DoNotUpdateToEdgeWithChromium' }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Current($key, $name) {
  if (-not (Test-Path $key)) { return $null }
  $p = Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
  if ($null -eq $p) { return $null }
  return $p.$name
}
# Every change goes through here. In a dry run the action is never run.
function Step([string]$Target, [string]$What, [scriptblock]$Action) {
  if ($dry) { Write-Output "What if: $What`n         $Target"; return }
  if ($PSCmdlet.ShouldProcess($Target, $What)) { & $Action }
}

if (-not $dry -and -not (Test-Admin)) {
  Write-Error 'Run this from an administrator PowerShell window (or add -WhatIf for a dry run).'
  exit 1
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  Write-Error 'This is a 32-bit PowerShell. Open the normal 64-bit one, or the wrong values are read.'
  exit 1
}
if ($dry) { Write-Output 'DRY RUN: nothing will be changed.' }

$saved = @()
$createdKeys = @()
if (Test-Path $Backup) {
  $state = Get-Content -Path $Backup -Raw | ConvertFrom-Json
  $saved = @($state.values)
  $createdKeys = @($state.keys | Where-Object { -not $_.existed -and $_.key -in $PolicyKey, $UpdateKey } | ForEach-Object { $_.key })
  $startType = "$($state.service.startType)"
  Write-Output "Using backup from $($state.created): $Backup"
} else {
  Write-Output 'No backup file found. Removing the values edge-block.ps1 sets.'
  $startType = 'Manual'
}

foreach ($v in $Ours) {
  $now = Get-Current $v.key $v.name
  $was = $saved | Where-Object { $_.key -eq $v.key -and $_.name -eq $v.name } | Select-Object -First 1
  if ($was -and $was.existed) {
    $kind = if ($was.kind) { "$($was.kind)" } else { 'DWord' }
    if ($kind -notin 'DWord', 'QWord', 'String', 'ExpandString') {
      Write-Warning "$($v.name): cannot restore a value of type $kind, left as it is."
      continue
    }
    if ("$now" -eq "$($was.old)") { continue }
    Step "$($v.key)\$($v.name)" "Restore old value $($was.old)" {
      if (-not (Test-Path $v.key)) { New-Item -Path $v.key -Force | Out-Null }
      New-ItemProperty -Path $v.key -Name $v.name -Value $was.old -PropertyType $kind -Force | Out-Null
    }
  } elseif ($null -ne $now) {
    Step "$($v.key)\$($v.name)" 'Remove value (it did not exist before)' {
      Remove-ItemProperty -Path $v.key -Name $v.name
    }
  }
}

# Remove keys the block script created, but only if nothing else is left in them.
foreach ($k in $createdKeys) {
  if (Test-Path $k) {
    $item = Get-Item -Path $k
    if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
      Step $k 'Remove empty key (created by edge-block.ps1)' {
        Remove-Item -Path $k
      }
    }
  }
}

if ($startType -in 'Automatic', 'Manual', 'Disabled') {
  $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
  if ($svc -and "$($svc.StartType)" -ne $startType) {
    Step $Service "Set startup type back to $startType" {
      Set-Service -Name $Service -StartupType $startType
    }
  }
}

if (Test-Path $Backup) {
  $done = $Backup -replace '\.json$', (".restored-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Step $Backup "Rename the used backup to $done" {
    Move-Item -Path $Backup -Destination $done
    Write-Output "Backup kept as $done"
  }
}
if (-not $dry) { Write-Output 'Done. Edge can install and update again.' }
