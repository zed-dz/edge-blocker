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
if ($DryRun) { $WhatIfPreference = $true }
$dry = [bool]$WhatIfPreference

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$UpdateKey = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
$Service   = 'MicrosoftEdgeElevationService'
$Backup    = Join-Path (Join-Path $env:ProgramData 'EdgeBlocker') 'backup.json'

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

if (-not $dry -and -not (Test-Admin)) {
  Write-Error 'Run this from an administrator PowerShell window (or add -WhatIf for a dry run).'
  exit 1
}
if ($dry) { Write-Output 'DRY RUN: nothing will be changed.' }

if (Test-Path $Backup) {
  $state = Get-Content -Path $Backup -Raw | ConvertFrom-Json
  $values = @($state.values)
  $keys = @($state.keys)
  $svcState = $state.service
  Write-Output "Using backup from $($state.created): $Backup"
} else {
  Write-Output 'No backup file found. Removing the values edge-block.ps1 sets.'
  $ids = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', '{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}',
         '{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}', '{65C35B14-6C1D-4122-AC46-7148CC9D6497}',
         '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  $values = @()
  foreach ($id in $ids) {
    $values += [pscustomobject]@{ key = $PolicyKey; name = "Install$id"; existed = $false; old = $null }
    $values += [pscustomobject]@{ key = $PolicyKey; name = "Update$id";  existed = $false; old = $null }
  }
  $values += [pscustomobject]@{ key = $PolicyKey; name = 'CreateDesktopShortcutDefault'; existed = $false; old = $null }
  $values += [pscustomobject]@{ key = $UpdateKey; name = 'DoNotUpdateToEdgeWithChromium'; existed = $false; old = $null }
  $keys = @()
  $svcState = [pscustomobject]@{ name = $Service; startType = 'Manual' }
}

foreach ($v in $values) {
  $now = Get-Current $v.key $v.name
  if ($v.existed) {
    if ("$now" -ne "$($v.old)" -and $PSCmdlet.ShouldProcess("$($v.key)\$($v.name)", "Restore old value $($v.old)")) {
      if (-not (Test-Path $v.key)) { New-Item -Path $v.key -Force | Out-Null }
      New-ItemProperty -Path $v.key -Name $v.name -Value ([int]$v.old) -PropertyType DWord -Force | Out-Null
    }
  } elseif ($null -ne $now) {
    if ($PSCmdlet.ShouldProcess("$($v.key)\$($v.name)", 'Remove value (it did not exist before)')) {
      Remove-ItemProperty -Path $v.key -Name $v.name
    }
  }
}

# Remove keys the block script created, but only if nothing else is left in them.
foreach ($k in $keys) {
  if (-not $k.existed -and (Test-Path $k.key)) {
    $item = Get-Item -Path $k.key
    if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
      if ($PSCmdlet.ShouldProcess($k.key, 'Remove empty key (created by edge-block.ps1)')) {
        Remove-Item -Path $k.key
      }
    }
  }
}

if ($svcState) {
  $svc = Get-Service -Name $svcState.name -ErrorAction SilentlyContinue
  if ($svc -and "$($svc.StartType)" -ne "$($svcState.startType)") {
    if ($PSCmdlet.ShouldProcess($svcState.name, "Set startup type back to $($svcState.startType)")) {
      Set-Service -Name $svcState.name -StartupType $svcState.startType
    }
  }
}

if (-not $dry) {
  if (Test-Path $Backup) {
    $done = $Backup -replace '\.json$', (".restored-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -Path $Backup -Destination $done
    Write-Output "Backup kept as $done"
  }
  Write-Output 'Done. Edge can install and update again.'
}
