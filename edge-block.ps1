<#
.SYNOPSIS
  Stops Microsoft Edge (the browser) from being reinstalled or updated by Windows.
  WebView2, which many apps need, stays allowed.

.DESCRIPTION
  Sets Microsoft's documented EdgeUpdate policy values and disables the Edge helper service.
  Before changing anything it saves the old values to
  %ProgramData%\EdgeBlocker\backup.json, so edge-unblock.ps1 can put every value back exactly.
  It does not uninstall Edge and does not delete any files.

.PARAMETER WhatIf
  Dry run. Prints every change it would make and changes nothing. Admin rights not needed.

.PARAMETER DryRun
  Same as -WhatIf.

.PARAMETER KeepService
  Leave the MicrosoftEdgeElevationService startup type as it is.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-block.ps1 -WhatIf
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\edge-block.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$DryRun,
  [switch]$KeepService
)
$ErrorActionPreference = 'Stop'
if ($DryRun) { $WhatIfPreference = $true }
$dry = [bool]$WhatIfPreference

$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
$UpdateKey = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'
$Service   = 'MicrosoftEdgeElevationService'
$BackupDir = Join-Path $env:ProgramData 'EdgeBlocker'
$Backup    = Join-Path $BackupDir 'backup.json'

# Edge browser channels: install and update switched off.
$Browsers = [ordered]@{
  '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' = 'Stable'
  '{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}' = 'Beta'
  '{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}' = 'Dev'
  '{65C35B14-6C1D-4122-AC46-7148CC9D6497}' = 'Canary'
}
$WebView2 = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

$Values = @()
foreach ($id in $Browsers.Keys) {
  $Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Install$id"; Value = 0; Note = "Edge $($Browsers[$id]): no install" }
  $Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Update$id";  Value = 0; Note = "Edge $($Browsers[$id]): no update" }
}
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Install$WebView2"; Value = 1; Note = 'WebView2: install allowed' }
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = "Update$WebView2";  Value = 1; Note = 'WebView2: update allowed' }
$Values += [pscustomobject]@{ Key = $PolicyKey; Name = 'CreateDesktopShortcutDefault'; Value = 0; Note = 'No desktop shortcut' }
$Values += [pscustomobject]@{ Key = $UpdateKey; Name = 'DoNotUpdateToEdgeWithChromium'; Value = 1; Note = 'Windows Update: do not deliver Edge' }

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

# 1. Save the old state once. A second run never overwrites the first backup.
if (-not (Test-Path $Backup)) {
  $state = [ordered]@{
    created  = (Get-Date).ToString('s')
    keys     = @(@($PolicyKey, $UpdateKey) | ForEach-Object { [ordered]@{ key = $_; existed = [bool](Test-Path $_) } })
    values   = @($Values | ForEach-Object {
      $old = Get-Current $_.Key $_.Name
      [ordered]@{ key = $_.Key; name = $_.Name; existed = ($null -ne $old); old = $old }
    })
    service  = $null
  }
  $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
  if ($svc -and -not $KeepService) { $state.service = [ordered]@{ name = $Service; startType = "$($svc.StartType)" } }
  if ($PSCmdlet.ShouldProcess($Backup, 'Save current values (backup for edge-unblock.ps1)')) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $Backup -Encoding UTF8
  }
} else {
  Write-Output "Backup already exists, keeping it: $Backup"
}

# 2. Policy values.
foreach ($v in $Values) {
  $old = Get-Current $v.Key $v.Name
  $was = if ($null -eq $old) { 'not set' } else { "$old" }
  if ($PSCmdlet.ShouldProcess("$($v.Key)\$($v.Name)", "Set to $($v.Value) (now: $was) - $($v.Note)")) {
    if (-not (Test-Path $v.Key)) { New-Item -Path $v.Key -Force | Out-Null }
    New-ItemProperty -Path $v.Key -Name $v.Name -Value $v.Value -PropertyType DWord -Force | Out-Null
  }
}

# 3. The Edge helper service is not needed without Edge.
if (-not $KeepService) {
  $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
  if ($svc) {
    if ($PSCmdlet.ShouldProcess($Service, "Set startup type to Disabled (now: $($svc.StartType))")) {
      Set-Service -Name $Service -StartupType Disabled
    }
  } else {
    Write-Output "Service $Service not found, skipped."
  }
}

if (-not $dry) {
  Write-Output ''
  Write-Output 'Done. Current values:'
  foreach ($v in $Values) { Write-Output ("  {0,-48} = {1}" -f $v.Name, (Get-Current $v.Key $v.Name)) }
  $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
  if ($svc) { Write-Output ("  {0,-48} = {1}" -f $Service, $svc.StartType) }
  Write-Output ''
  Write-Output "Backup of the old values: $Backup"
  Write-Output 'To undo: run edge-unblock.ps1 as administrator.'
}
